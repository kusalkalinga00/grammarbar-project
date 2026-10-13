import Foundation
import XCTest
@testable import GrammarDownloaderCore

// MARK: - Scratch directories

/// A fresh directory under `NSTemporaryDirectory()` per test.
/// Its path is deep enough that `CleanupSafety.isRemovable` accepts it, which is
/// exactly the production shape: the downloader only ever deletes a directory it
/// created for itself.
final class TempDirectory {

    let url: URL

    init() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        url = base.appendingPathComponent("GrammarDownloaderTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func makeChild(_ name: String) -> URL {
        let child = url.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        return child
    }

    func contents() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path)
    }

    func write(_ data: Data, to name: String) throws {
        try data.write(to: url.appendingPathComponent(name))
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Deterministic payloads

enum Payload {
    /// Deterministic, non-repeating bytes so a slice at offset N is not confused
    /// with a slice at offset 0.
    static func bytes(_ count: Int, seed: UInt8 = 0) -> Data {
        Data((0..<count).map { UInt8((($0 &* 31) &+ Int(seed)) & 0xFF) })
    }

    static func text(_ string: String) -> Data { Data(string.utf8) }
}

enum DigestPin {
    case pinned
    case unpinned
    case custom(String)

    func value(for data: Data) -> String {
        switch self {
        case .pinned: return FileHashing.sha256(of: data)
        case .unpinned: return ""
        case .custom(let value): return value
        }
    }
}

// MARK: - Catalog-ish builders

enum TestCatalog {

    static let host = "huggingface.co"

    static func item(name: String,
                     data: Data,
                     host: String = TestCatalog.host,
                     pin: DigestPin = .pinned,
                     declaredSize: Int64? = nil,
                     revision: String = "73e3e38d9813") -> DownloadItem {
        let url = URL(string: "https://\(host)/mlx-community/Qwen3-0.6B-4bit/resolve/\(revision)/\(name)")!
        return DownloadItem(name: name,
                            url: url,
                            size: declaredSize ?? Int64(data.count),
                            sha256: pin.value(for: data))
    }

    /// The shape of the real `ModelCatalog.qwen3_0_6b_4bit` entry, scaled down.
    static func plan(files: [(name: String, data: Data)]) throws -> DownloadPlan {
        try DownloadPlan(modelID: "qwen3-0.6b-4bit",
                         revision: "73e3e38d9813",
                         files: files.map { item(name: $0.name, data: $0.data) })
    }
}

// MARK: - Scripted transport

/// A `DownloadTransport` that behaves like a server we can hold a script to.
/// Everything the engine does — resume, retry, truncation detection, cancellation
/// and cleanup — is driven through this, so the suite needs no network at all.
final class ScriptedTransport: DownloadTransport, @unchecked Sendable {

    private let lock = NSLock()
    private var recordedCalls: [TransportRequest] = []
    private var failuresRemaining: Int

    let payload: [String: Data]
    let interruptionError: TransportError
    /// Bytes appended before an injected failure fires (0 = fail immediately).
    let partialWriteOnFailure: Int64
    /// Emulates a server that ignores `Range`: sends the whole body and the
    /// transport truncates, exactly as `URLSessionFileTransport` does.
    let ignoreResume: Bool
    /// Never returns until cancelled.
    let hang: Bool

    init(payload: [String: Data],
         failuresRemaining: Int = 0,
         interruptionError: TransportError = .interrupted,
         partialWriteOnFailure: Int64 = 0,
         ignoreResume: Bool = false,
         hang: Bool = false) {
        self.payload = payload
        self.failuresRemaining = failuresRemaining
        self.interruptionError = interruptionError
        self.partialWriteOnFailure = partialWriteOnFailure
        self.ignoreResume = ignoreResume
        self.hang = hang
    }

    var calls: [TransportRequest] {
        lock.withLock { recordedCalls }
    }

    var callCount: Int { calls.count }

    func transfer(_ request: TransportRequest,
                  onBytes: @escaping @Sendable (Int64) -> Void) async throws -> TransportOutcome {

        let shouldFail: Bool = lock.withLock {
            recordedCalls.append(request)
            guard failuresRemaining > 0 else { return false }
            failuresRemaining -= 1
            return true
        }

        if hang {
            // Cancellable by design: `Task.sleep` throws `CancellationError`.
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }

        let body = payload[request.item.name] ?? Data()
        var restartedFromZero = false
        var offset = Int(min(max(0, request.resumeFromByte), Int64(body.count)))
        if ignoreResume, request.resumeFromByte > 0 {
            // Whole body, previous bytes discarded.
            try? FileManager.default.removeItem(at: request.destination)
            offset = 0
            restartedFromZero = true
        }

        let slice = body.subdata(in: offset..<body.count)
        let toWrite = shouldFail ? Int(min(partialWriteOnFailure, Int64(slice.count))) : slice.count
        let portion = Data(slice.prefix(toWrite))

        if !portion.isEmpty {
            try Self.append(portion, to: request.destination)
            onBytes(Int64(portion.count))
        }

        if shouldFail { throw interruptionError }

        return TransportOutcome(bytesWrittenInSession: Int64(portion.count),
                                restartedFromZero: restartedFromZero)
    }

    static func append(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

// MARK: - Engine factory

extension ModelDownloadEngine.Configuration {

    /// A configuration with the disk check and the hasher wired to test-friendly
    /// values. `capacity` defaults to "plenty".
    static func testing(workingDirectory: URL,
                        transport: any DownloadTransport,
                        capacity: @escaping @Sendable (URL) -> Int64? = { _ in Int64.max },
                        maxRetriesPerFile: Int = 2,
                        cleanupPolicy: ModelDownloadEngine.CleanupPolicy = .removePartialsAndWorkingDirectory) -> Self {
        ModelDownloadEngine.Configuration(
            workingDirectory: workingDirectory,
            transport: transport,
            maxRetriesPerFile: maxRetriesPerFile,
            cleanupPolicy: cleanupPolicy,
            availableCapacity: capacity,
            hash: { try FileHashing.sha256(ofFileAt: $0) })
    }
}

// MARK: - Error assertions

func XCTAssertThrowsDownloadError<T>(_ expression: @autoclosure () async throws -> T,
                                     file: StaticString = #filePath,
                                     line: UInt = #line,
                                     _ check: (DownloadError) -> Bool) async {
    do {
        _ = try await expression()
        XCTFail("expected a DownloadError, but the call succeeded", file: file, line: line)
    } catch let error as DownloadError {
        XCTAssertTrue(check(error), "unexpected DownloadError: \(error)", file: file, line: line)
    } catch {
        XCTFail("expected DownloadError, got \(type(of: error)): \(error)", file: file, line: line)
    }
}
