#!/usr/bin/env swift

import Foundation


// MARK: - Type declarations

enum AppError: Error {
    case invalidURL(URL)
    case fetchTimeout(URL)
    case networkingError(Error)
    case noData(URL)
    case notFound(URL)
    case packageDumpError(String)
    case packageDumpTimeout
    case rateLimitExceeded(URL, reportedLimit: Int)
    case syntaxError(String)

    var localizedDescription: String {
        switch self {
            case .invalidURL(let url):
                return "invalid url: \(url.absoluteString)"
            case .fetchTimeout(let url):
                return "timeout while fetching url: \(url.absoluteString)"
            case .networkingError(let error):
                return "networking error: \(error.localizedDescription)"
            case .noData(let url):
                return "no data returned from url: \(url.absoluteString)"
            case .notFound(let url):
                return "url not found (404): \(url.absoluteString)"
            case .packageDumpError(let msg):
                return "package dump failed: \(msg)"
            case .packageDumpTimeout:
                return "timeout while running `swift package dump-package`"
            case let .rateLimitExceeded(url, limit):
                return "rate limit of \(limit) exceeded while requesting url: \(url.absoluteString)"
            case .syntaxError(let msg):
                return msg
        }
    }
}

enum RunMode {
    case processURL(URL)
    case processPackageList
}


// MARK: - Generic helpers

extension Pipe {
    convenience init(readabilityHandler: ((FileHandle) -> Void)?) {
        self.init()
        self.fileHandleForReading.readabilityHandler = readabilityHandler
    }
}

// MARK: - Redirect handling

class RedirectFollower: NSObject, URLSessionDataDelegate {
    var lastURL: URL?
    init(initialURL: URL) {
        self.lastURL = initialURL
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lastURL = request.url ?? lastURL
        completionHandler(request)
    }
}

extension URL {
    func followingRedirects(timeout: TimeInterval = 30) -> URL? {
        let semaphore = DispatchSemaphore(value: 0)
        
        let follower = RedirectFollower(initialURL: self)
        let session = URLSession(configuration: .default, delegate: follower, delegateQueue: nil)
        
        let task = session.dataTask(with: self) { (_, response, error) in
            semaphore.signal()
        }
        
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout)
        
        return follower.lastURL
    }
}


// MARK: - Networking


func fetch(_ url: URL, bearerToken: String? = nil, timeout: Int = 10) throws -> Data {
    var request = URLRequest(url: url)
    
    if let token = bearerToken {
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    
    let semaphore = DispatchSemaphore(value: 0)
    
    var payload: Data?
    var taskError: AppError?
    
    let session = URLSession(configuration: .default)
    let task = session.dataTask(with: request) { (data, response, error) in
        let httpResponse = response as? HTTPURLResponse
        
        if let limit = httpResponse?.value(forHTTPHeaderField: "X-RateLimit-Limit").flatMap(Int.init),
           let remaining = httpResponse?.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init),
           remaining == 0 {
            taskError = .rateLimitExceeded(url, reportedLimit: limit)
        } else if httpResponse?.statusCode == 404 {
            taskError = .notFound(url)
        } else if let error = error {
            taskError = .networkingError(error)
        }
        
        payload = data
        semaphore.signal()
    }
    
    task.resume()
    
    switch semaphore.wait(timeout: .now() + .seconds(timeout)) {
    case .timedOut:
        throw AppError.fetchTimeout(url)
    case .success where taskError != nil:
        throw taskError!
    case .success:
        guard let payload = payload else { throw AppError.noData(url) }
        return payload
    }
}


// MARK: - Script logic

func parseArgs(_ args: [String]) throws -> RunMode {
    guard args.count > 1 else { return .processPackageList }
    let urlString = args[1]
    guard
        urlString.starts(with: "https://"),
        let url = URL(string: urlString)
        else { throw AppError.syntaxError("not a valid url: \(urlString)") }
    return .processURL(url)
}

func getDefaultBranch(owner: String, repository: String) throws -> String {
    let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)")!
    let json = try fetch(url)

    struct Repository: Decodable {
        let default_branch: String
    }

    return try JSONDecoder().decode(Repository.self, from: json).default_branch
}

func getManifestURL(_ url: URL) throws -> URL {
    let repository = url.deletingPathExtension().lastPathComponent
    let owner = url.deletingLastPathComponent().lastPathComponent    
    let defaultBranch = try getDefaultBranch(owner: owner, repository: repository)
    return URL(string: "https://raw.githubusercontent.com/\(owner)/\(repository)/\(defaultBranch)/Package.swift")!
}

func createTempDir() throws -> URL {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: false, attributes: nil)
    return tempDir
}

func createDumpPackageProcess(at path: URL, standardOutput: Pipe, standardError: Pipe) -> Process {
    let process = Process()
    process.launchPath = "/usr/bin/xcrun"
    process.arguments = ["swift", "package", "dump-package"]
    process.currentDirectoryURL = path
    process.standardOutput = standardOutput
    process.standardError = standardError
    return process
}

func runDumpPackage(at path: URL, timeout: TimeInterval = 20) throws -> Data {
    let queue = DispatchQueue(label: "process-pipe-read-queue")
    var stdout = Data()
    var stderr = Data()
    let stdoutPipe = Pipe { handler in
        queue.async { stdout.append(handler.availableData) }
    }
    let stderrPipe = Pipe { handler in
        queue.async { stderr.append(handler.availableData) }
    }

    let process = createDumpPackageProcess(at: path, standardOutput: stdoutPipe, standardError: stderrPipe)
    
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
        if process.isRunning { process.terminate() }
    }
    process.launch()
    process.waitUntilExit()
    
    switch process.terminationStatus {
        case 0:
            return stdout
        case 15:
            throw AppError.packageDumpTimeout
        default:
            let error = String(data: stderr, encoding: .utf8) ?? "(nil)"
            throw AppError.packageDumpError(error)
    }
}

func dumpPackage(url: URL) throws -> Data {
    let manifestURL = try getManifestURL(url)
    let manifest = try fetch(manifestURL)
    
    let tempDir = try createTempDir()
    let fileURL = tempDir.appendingPathComponent("Package.swift")
    try manifest.write(to: fileURL)

    // swift dump package
    return try runDumpPackage(at: tempDir)
}

func verifyURL(_ url: URL) throws {
    print("verify: \(url.absoluteString)")
    let data = try dumpPackage(url: url)
    print(String(data: data, encoding: .utf8)!)
    // decode data
    // check for product count
}

func processURL(_ url: URL) throws {
    guard let resolvedURL = url.followingRedirects() else { throw AppError.invalidURL(url) }
    try verifyURL(resolvedURL)
}

func processPackageList() {
    fatalError("not implemented")
}

func main(args: [String]) throws {
    switch try parseArgs(args) {
        case .processURL(let url):
            try processURL(url)
        case .processPackageList:
            processPackageList()
    }
    exit(EXIT_SUCCESS)
}


// MARK: - Script specific extensions

extension String {
    func removingGitExtension() -> String {
        let suffix = ".git"
        if lowercased().hasSuffix(suffix) {
            return String(dropLast(suffix.count))
        }
        return self
    }
}

extension URL {
    func removingGitExtension() -> URL {
        guard absoluteString.hasSuffix(".git") else { return self }
        return URL(string: absoluteString.removingGitExtension())!
    }
}


// MARK: - main

do {
    try main(args: CommandLine.arguments)
} catch {
    if let appError = error as? AppError {
        print("ERROR: \(appError.localizedDescription)")
    } else {
        print(error)
    }
    exit(EXIT_FAILURE)
}
RunLoop.main.run()
