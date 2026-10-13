import Foundation

/// The only place in this target that owns a socket.
///
/// Two things make it safe:
///  * the URL is passed through `NetworkPolicy.evaluate` before a request exists;
///  * every redirect is answered from `NetworkPolicy.evaluateRedirect` inside
///    `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`,
///    where `completionHandler(nil)` means "do not follow" — an active refusal,
///    not a passive `URLResponse.url` check made after the fact.
///
/// This file cannot be unit-tested offline; all the decisions it delegates to
/// can be, and are.
public final class URLSessionFileTransport: NSObject, DownloadTransport, @unchecked Sendable {

    public struct Limits: Sendable {
        /// Time to first byte / per-request timeout.
        public var requestTimeout: TimeInterval
        /// Whole-transfer ceiling; a 335 MB file on a slow link needs headroom.
        public var resourceTimeout: TimeInterval
        public var allowsExpensiveNetworkAccess: Bool

        public static let `default` = Limits(requestTimeout: 60,
                                             resourceTimeout: 3_600,
                                             allowsExpensiveNetworkAccess: true)

        public init(requestTimeout: TimeInterval, resourceTimeout: TimeInterval, allowsExpensiveNetworkAccess: Bool) {
            self.requestTimeout = requestTimeout
            self.resourceTimeout = resourceTimeout
            self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        }
    }

    private let limits: Limits

    public init(limits: Limits = .default) {
        self.limits = limits
        super.init()
    }

    public func transfer(_ request: TransportRequest,
                         onBytes: @Sendable @escaping (Int64) -> Void) async throws -> TransportOutcome {

        try Task.checkCancellation()

        // 1. Pre-flight, with the same pure function the unit tests exercise.
        let decision = request.allowlist.decision(for: request.item.url)
        guard case .allow = decision else {
            throw TransportError.hostNotAllowed(origin: decision.rejection?.description
                                                ?? request.item.url.host() ?? "unknown")
        }

        let delegate = TransferDelegate(request: request, onBytes: onBytes)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        configuration.allowsExpensiveNetworkAccess = limits.allowsExpensiveNetworkAccess
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil

        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegate.queue)
        defer { session.invalidateAndCancel() }

        var urlRequest = URLRequest(url: request.item.url)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = limits.requestTimeout
        urlRequest.setValue("GrammarbarModelDownloader/1.0", forHTTPHeaderField: "User-Agent")
        if request.resumeFromByte > 0 {
            // Range header is only ever sent for an offset that already exists on disk.
            urlRequest.setValue("bytes=\(request.resumeFromByte)-", forHTTPHeaderField: "Range")
        }

        let task = session.dataTask(with: urlRequest)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.attach(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

// MARK: - Delegate

private final class TransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private let resumeFrom: Int64
    private let destination: URL
    private let allowlist: HostAllowlist
    private let originalURL: URL
    private let onBytes: @Sendable (Int64) -> Void

    /// Serial: every delegate callback and every mutable field below is confined to it.
    let queue: OperationQueue

    private var continuation: CheckedContinuation<TransportOutcome, Error>?
    private var handle: FileHandle?
    private var bytesWritten: Int64 = 0
    private var restartedFromZero = false
    private var redirectTarget: URL?
    private var redirectRejection: URLRejection?

    private static let retryableURLErrorCodes: Set<URLError.Code> = [
        .networkConnectionLost, .timedOut, .notConnectedToInternet,
    ]

    init(request: TransportRequest, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.resumeFrom = request.resumeFromByte
        self.destination = request.destination
        self.allowlist = request.allowlist
        self.originalURL = request.item.url
        self.onBytes = onBytes
        self.queue = OperationQueue()
        super.init()
        queue.name = "com.grammarbar.downloader.transfer"
        queue.maxConcurrentOperationCount = 1
    }

    func attach(_ continuation: CheckedContinuation<TransportOutcome, Error>) {
        self.continuation = continuation
    }

    // MARK: Redirects — the security-critical hook

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {

        let from = task.currentRequest?.url ?? task.originalRequest?.url ?? originalURL
        guard let target = request.url else {
            completionHandler(nil)
            return
        }

        switch NetworkPolicy.evaluateRedirect(from: from, to: target, allowlist: allowlist) {
        case .allow:
            // Still on the one allowlisted origin — follow it.
            completionHandler(request)
        case .reject(let reason):
            redirectTarget = target
            redirectRejection = reason
            // nil == never follow. The task then completes with the 3xx response.
            completionHandler(nil)
        }
    }

    // MARK: Response

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {

        guard let http = response as? HTTPURLResponse else {
            finish(.failure(.notHTTPResponse))
            completionHandler(.cancel)
            return
        }

        if (300..<400).contains(http.statusCode) {
            let to = (redirectTarget ?? http.url ?? originalURL).absoluteString
            let reason = redirectRejection?.description ?? "redirect refused"
            finish(.failure(.redirectRejected(from: originalURL.absoluteString, to: to, reason: reason)))
            completionHandler(.cancel)
            return
        }

        // Belt and braces behind the delegate hook: whatever URL the response
        // actually came from must pass the same allowlist.
        if let url = http.url, !allowlist.decision(for: url).isAllowed {
            finish(.failure(.hostNotAllowed(origin: url.host() ?? url.absoluteString)))
            completionHandler(.cancel)
            return
        }

        let truncateTo: Int64?
        switch ResumePlanner.reconcile(statusCode: http.statusCode, requestedFromByte: resumeFrom) {
        case .httpError(let status):
            finish(.failure(.httpStatus(status)))
            completionHandler(.cancel)
            return
        case .appendConfirmed:
            truncateTo = nil
        case .serverIgnoredRange, .rangeNotSatisfiable, .unexpectedPartialContent, .fresh:
            // The server is sending the whole body: anything already on disk is stale.
            restartedFromZero = resumeFrom > 0
            truncateTo = 0
        }

        do {
            try openHandle(truncateTo: truncateTo)
        } catch {
            finish(.failure(.writeFailed(String(describing: error))))
            completionHandler(.cancel)
            return
        }

        completionHandler(.allow)
    }

    // MARK: Body

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            finish(.failure(.writeFailed(String(describing: error))))
            dataTask.cancel()
            return
        }
        bytesWritten += Int64(data.count)
        onBytes(bytesWritten)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if let urlError = error as? URLError {
                if urlError.code == .cancelled { finish(.failure(.cancelled)); return }
                if Self.retryableURLErrorCodes.contains(urlError.code) {
                    // The partial file is intact, so the caller may resume with a Range.
                    finish(.failure(.interrupted))
                    return
                }
            }
            finish(.failure(.underlying(error.localizedDescription)))
            return
        }

        // Some URLSession versions complete a refused redirect without a body.
        if handle == nil, bytesWritten == 0, let rejection = redirectRejection {
            let to = (redirectTarget ?? originalURL).absoluteString
            finish(.failure(.redirectRejected(from: originalURL.absoluteString, to: to,
                                              reason: rejection.description)))
            return
        }

        finish(.success(TransportOutcome(bytesWrittenInSession: bytesWritten,
                                         restartedFromZero: restartedFromZero)))
    }

    // MARK: File handling

    private func openHandle(truncateTo offset: Int64?) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        if let offset {
            try handle.truncate(atOffset: UInt64(max(0, offset)))
        }
        try handle.seekToEnd()
        self.handle = handle
    }

    private func finish(_ result: Result<TransportOutcome, TransportError>) {
        guard let continuation else { return }
        self.continuation = nil
        try? handle?.close()
        handle = nil
        switch result {
        case .success(let outcome): continuation.resume(returning: outcome)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
