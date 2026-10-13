import Foundation

#if GRAMMAR_XPC_SERVICE

// ============================================================================
//  GrammarDownloader.xpc — service entry point
// ============================================================================
//
//  BUILD NOTE (unverifiable in this SwiftPM package)
//  ------------------------------------------------
//  This file is guarded by `GRAMMAR_XPC_SERVICE`. The SwiftPM library target
//  cannot see `Sources/Shared/GrammarDownloading.swift` (it is not a declared
//  target and Package.swift is owned by another workstream), so building the
//  XPC half unconditionally would break `swift build`.
//
//  The `.xcodeproj` workstream (project.yml) must add, for the
//  GrammarDownloader.xpc bundle target only:
//
//      SWIFT_ACTIVE_COMPILATION_CONDITIONS = GRAMMAR_XPC_SERVICE
//
//  and compile it from `Sources/Shared` + `Sources/GrammarDownloaderCore`
//  together. Nothing else changes: the core it calls is the same code the
//  test suite exercises, and no GrammarBarCore dependency is pulled in.
//
//  An alternative to the `@main` below is a top-level `main.swift` containing
//  the three lines from `GrammarDownloaderServiceMain.main()` — use one or the
//  other, never both.
// ============================================================================

import os

/// Implements `GrammarDownloading` on top of `ModelDownloadEngine`.
///
/// The service is a thin adapter and nothing more: it converts XPC payloads into
/// `DownloadPlan` / `Configuration`, forwards progress, forwards cancellation and
/// converts the report back. It has no opinion about models, and — by
/// construction — no access to user text.
public final class GrammarDownloaderService: NSObject, GrammarDownloading {

    private static let log = Logger(subsystem: "com.grammarbar.GrammarDownloader", category: "download")

    private let lock = NSLock()
    private var running: [String: Task<Void, Never>] = [:]
    /// Injectable for tests of the mapping layer; defaults to the real transport.
    private let makeTransport: @Sendable () -> any DownloadTransport

    public init(makeTransport: @escaping @Sendable () -> any DownloadTransport = { URLSessionFileTransport() }) {
        self.makeTransport = makeTransport
        super.init()
    }

    // MARK: GrammarDownloading

    public func ping(reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    public func download(_ request: GDDownloadRequest,
                         progress: GrammarDownloadProgressReporting?,
                         reply: @escaping (GDDownloadReply) -> Void) {

        let plan: DownloadPlan
        do {
            plan = try Self.makePlan(from: request)
        } catch {
            reply(Self.failureReply(for: request, error: error))
            return
        }

        let requestID = request.requestID
        let transport = request.verifyOnly ? VerifyingTransport() : makeTransport()
        let engine = ModelDownloadEngine(configuration: ModelDownloadEngine.Configuration(
            workingDirectory: request.workingDirectoryURL,
            transport: transport))

        // Never log file contents — there are none here — and keep identifiers out
        // of the default (public) log scope where they could identify a user.
        Self.log.info("download started for \(plan.files.count, privacy: .public) files")

        let task = Task { [weak self] in
            defer { self?.forget(requestID) }
            do {
                let report = try await engine.download(plan) { update in
                    progress?.didUpdate(progress: Self.payload(from: update, requestID: requestID))
                }
                Self.log.info("download finished, \(report.files.count, privacy: .public) files on disk")
                reply(Self.reply(from: report, request: request))
            } catch {
                reply(Self.failureReply(for: request, error: error))
            }
        }
        remember(task, for: requestID)
    }

    public func cancel(requestID: String) {
        lock.lock()
        let task = running.removeValue(forKey: requestID)
        lock.unlock()
        // The engine's catch path removes partial files and the working directory.
        task?.cancel()
        Self.log.info("cancel requested")
    }

    // MARK: Task bookkeeping

    private func remember(_ task: Task<Void, Never>, for requestID: String) {
        lock.lock()
        let previous = running.updateValue(task, forKey: requestID)
        lock.unlock()
        previous?.cancel()
    }

    private func forget(_ requestID: String) {
        lock.lock()
        running.removeValue(forKey: requestID)
        lock.unlock()
    }

    // MARK: Mapping

    /// XPC payload -> validated plan. A catalog that spans two hosts, or names a
    /// file `../something`, is refused here rather than on the wire.
    public static func makePlan(from request: GDDownloadRequest) throws -> DownloadPlan {
        let items = request.files.compactMap { file -> DownloadItem? in
            guard let url = URL(string: file.urlString) else { return nil }
            return DownloadItem(name: file.name, url: url, size: file.size, sha256: file.sha256)
        }
        return try DownloadPlan(modelID: request.modelID, revision: request.revision, files: items)
    }

    static func payload(from progress: DownloadProgress, requestID: String) -> GDDownloadProgress {
        GDDownloadProgress(requestID: requestID,
                           fileName: progress.fileName,
                           fileIndex: progress.fileIndex,
                           fileCount: progress.fileCount,
                           bytesReceivedForFile: progress.bytesReceivedForFile,
                           bytesTotalForFile: progress.bytesTotalForFile,
                           bytesReceivedOverall: progress.bytesReceivedOverall,
                           bytesTotalOverall: progress.bytesTotalOverall)
    }

    static func reply(from report: DownloadReport, request: GDDownloadRequest) -> GDDownloadReply {
        let files = report.files.map {
            GDDownloadedFile(name: $0.name,
                             sha256: $0.sha256,
                             size: $0.size,
                             wasVerified: $0.verification.isVerified,
                             wasPinnedButWrong: $0.verification.isPinnedButWrong)
        }
        return GDDownloadReply(requestID: request.requestID,
                               succeeded: true,
                               cancelled: false,
                               workingDirectoryPath: report.workingDirectory.path,
                               sourceHost: report.sourceHost,
                               files: files,
                               unpinnedFileNames: report.unpinnedFileNames,
                               sizeAnomalyFileNames: report.sizeAnomalyFileNames,
                               resumedFileNames: report.resumedFileNames,
                               bytesOnDisk: report.totalBytesOnDisk,
                               failureMessage: nil)
    }

    static func failureReply(for request: GDDownloadRequest, error: Error) -> GDDownloadReply {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        let cancelled = (error as? DownloadError)?.isCancellation ?? false
        return GDDownloadReply(requestID: request.requestID,
                               succeeded: false,
                               cancelled: cancelled,
                               workingDirectoryPath: nil,
                               sourceHost: "unknown",
                               files: [],
                               failureMessage: message)
    }
}

/// Used for `verifyOnly` requests: the engine only consults the transport for
/// files that are *not* already the promised size, so a complete directory is
/// re-hashed with no network at all, and an incomplete one fails loudly.
private struct VerifyingTransport: DownloadTransport {
    func transfer(_ request: TransportRequest,
                  onBytes: @Sendable (Int64) -> Void) async throws -> TransportOutcome {
        throw TransportError.underlying("verify-only: '\(request.item.name)' is incomplete on disk")
    }
}

// MARK: - Listener

final class GrammarDownloaderServiceDelegate: NSObject, NSXPCListenerDelegate {

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = GrammarDownloadingInterfaceFactory.serviceInterface()
        newConnection.exportedObject = GrammarDownloaderService()
        newConnection.resume()
        return true
    }
}

#endif

#if GRAMMAR_XPC_SERVICE && !GRAMMAR_XPC_NO_ENTRY

/// The bundle target just sets `GRAMMAR_XPC_SERVICE`. `GRAMMAR_XPC_NO_ENTRY` is for
/// hosts that supply their own entry point — a `main.swift`, or the verification
/// harness used to check the mapping layer outside the .xcodeproj.
@main
public struct GrammarDownloaderServiceMain {

    /// `NSXPCListener.service()` must be created on the main thread, and the
    /// delegate is held weakly by the listener — hence the globals.
    private static let delegate = GrammarDownloaderServiceDelegate()
    private static let listener: NSXPCListener = {
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        return listener
    }()

    public static func main() {
        listener.resume()
    }
}

#endif
