import Foundation

/// The orchestrator. It owns the working directory, resume bookkeeping, hashing,
/// the atomic rename and cleanup; the transport only moves bytes.
///
/// Everything network-adjacent goes through the injectable `DownloadTransport`,
/// so this whole class — resume, retry, truncation detection, cancellation and
/// cleanup — is exercised by the offline test suite.
public actor ModelDownloadEngine {

    public enum CleanupPolicy: Sendable, Equatable {
        /// Default, and what the requirements ask for: on cancel or failure the
        /// working directory is left with nothing in it.
        case removePartialsAndWorkingDirectory
        /// Opt-in alternative for callers that want to resume across process
        /// restarts. Partial files survive, so the next call continues with a
        /// `Range` request instead of starting over.
        case keepPartialsForResume
    }

    public struct Configuration: Sendable {
        /// All downloads land here and nowhere else. For the XPC service this is a
        /// stable container directory (not `NSTemporaryDirectory()`, which the OS
        /// may purge) so a quit mid-download can be resumed.
        public var workingDirectory: URL
        public var transport: any DownloadTransport
        public var diskMultiplier: Int64
        /// Extra attempts after the first, for retryable (`interrupted`) failures.
        public var maxRetriesPerFile: Int
        public var cleanupPolicy: CleanupPolicy
        /// Injectable so tests can force "low disk" without filling a volume.
        public var availableCapacity: @Sendable (URL) -> Int64?
        /// Injectable so tests can avoid hashing hundreds of megabytes.
        public var hash: @Sendable (URL) throws -> String

        public init(workingDirectory: URL,
                    transport: any DownloadTransport,
                    diskMultiplier: Int64 = DiskSpacePolicy.requiredMultiplier,
                    maxRetriesPerFile: Int = 2,
                    cleanupPolicy: CleanupPolicy = .removePartialsAndWorkingDirectory,
                    availableCapacity: @escaping @Sendable (URL) -> Int64? = { DiskSpacePolicy.availableBytes(at: $0) },
                    hash: @escaping @Sendable (URL) throws -> String = { try FileHashing.sha256(ofFileAt: $0) }) {
            self.workingDirectory = workingDirectory
            self.transport = transport
            self.diskMultiplier = diskMultiplier
            self.maxRetriesPerFile = maxRetriesPerFile
            self.cleanupPolicy = cleanupPolicy
            self.availableCapacity = availableCapacity
            self.hash = hash
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public var workingDirectory: URL { configuration.workingDirectory }

    /// Downloads every file in `plan`, verifies it, and returns the directory to
    /// hand to `ModelStore.install(fromTemporaryDirectory:catalog:licenseText:)`.
    ///
    /// Throws `DownloadError`; on any throw the working directory is cleaned up
    /// according to `configuration.cleanupPolicy`, so a failed attempt can never
    /// be mistaken for a completed one.
    @discardableResult
    public func download(_ plan: DownloadPlan,
                         onProgress: @escaping @Sendable (DownloadProgress) -> Void = { _ in })
    async throws -> DownloadReport {

        let workDirectory = configuration.workingDirectory
        guard CleanupSafety.isRemovable(workDirectory) else {
            throw DownloadError.workingDirectoryNotRemovable(workDirectory.path)
        }
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        } catch {
            throw DownloadError.transport(.writeFailed("cannot create \(workDirectory.path): \(error)"))
        }

        // Pre-flight: at least 2x the total download size, before a socket opens.
        // Done inside the do-block so a refusal cleans up the directory we just made.
        do {
            let diskCheck = DiskSpacePolicy.decision(availableBytes: configuration.availableCapacity(workDirectory),
                                                     totalDownloadBytes: plan.totalBytes,
                                                     multiplier: configuration.diskMultiplier)
            if case .insufficient(let required, let available, _) = diskCheck {
                throw DownloadError.insufficientDiskSpace(required: required, available: available)
            }
            return try await perform(plan, diskCheck: diskCheck, onProgress: onProgress)
        } catch let error as DownloadError {
            cleanupAfterFailure(plan)
            throw error
        } catch is CancellationError {
            cleanupAfterFailure(plan)
            throw DownloadError.cancelled
        } catch let error as DownloadPlan.ValidationError {
            cleanupAfterFailure(plan)
            throw DownloadError.transport(.underlying(error.localizedDescription))
        } catch {
            cleanupAfterFailure(plan)
            throw DownloadError.transport(.underlying(String(describing: error)))
        }
    }

    // MARK: - Internals

    private func perform(_ plan: DownloadPlan,
                         diskCheck: DiskSpaceDecision,
                         onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> DownloadReport {

        var results: [VerifiedFile] = []
        var resumedFileNames: [String] = []
        var sizeAnomalies: [String] = []
        var bytesFromFinishedFiles: Int64 = 0
        var bytesOnDisk: Int64 = 0

        for (index, item) in plan.files.enumerated() {
            try Task.checkCancellation()

            let partial = PartialFiles.partialURL(for: item, in: configuration.workingDirectory)
            let final = PartialFiles.finalURL(for: item, in: configuration.workingDirectory)
            guard FileNamePolicy.isContained(partial, in: configuration.workingDirectory),
                  FileNamePolicy.isContained(final, in: configuration.workingDirectory) else {
                throw DownloadError.escapedWorkingDirectory(fileName: item.name)
            }

            var attempts = 0
            while true {
                try Task.checkCancellation()

                // Re-read the disk every attempt: a retry resumes from whatever
                // actually landed, not from what we last believed.
                let existing = PartialFiles.byteCount(at: partial)
                let resume = ResumePlanner.plan(partialByteCount: existing, expectedTotal: item.size)
                switch resume {
                case .discardCorrupt:
                    try? PartialFiles.remove(at: partial)
                case .append(let from):
                    try PartialFiles.prepareForAppend(at: partial, byteCount: from)
                case .startFresh, .verifyExisting:
                    break
                }

                let from = resume.resumableByteCount
                if from > 0, !resumedFileNames.contains(item.name) {
                    resumedFileNames.append(item.name)
                }

                // Already the promised size on disk: hash it, touch no network.
                if item.size > 0 && from == item.size { break }

                let request = TransportRequest(item: item, destination: partial,
                                               resumeFromByte: from, allowlist: plan.allowlist)
                let finished = bytesFromFinishedFiles
                let offset = from
                do {
                    _ = try await configuration.transport.transfer(request) { delta in
                        let received = offset + delta
                        onProgress(DownloadProgress(
                            modelID: plan.modelID,
                            fileIndex: index,
                            fileCount: plan.files.count,
                            fileName: item.name,
                            bytesReceivedForFile: received,
                            bytesTotalForFile: item.size,
                            bytesReceivedOverall: finished + received,
                            bytesTotalOverall: plan.totalBytes))
                    }
                    break
                } catch let error as TransportError {
                    if error == .cancelled || Task.isCancelled { throw DownloadError.cancelled }
                    if error.isRetryable, attempts < configuration.maxRetriesPerFile {
                        attempts += 1
                        continue
                    }
                    throw DownloadError.transport(error)
                }
            }

            // Truncation is fatal; an oversized file is flagged, because the
            // catalog sizes are measured approximations rather than exact counts.
            let onDisk = PartialFiles.byteCount(at: partial)
            if item.size > 0 {
                if onDisk < item.size {
                    throw DownloadError.truncatedFile(fileName: item.name, expected: item.size, received: onDisk)
                }
                if onDisk > item.size { sizeAnomalies.append(item.name) }
            }

            let digest: String
            do {
                digest = try configuration.hash(partial)
            } catch {
                throw DownloadError.transport(.writeFailed("cannot hash \(item.name): \(error)"))
            }

            let verification = Verifier.classify(expectedPinnedDigest: item.sha256, computed: digest)
            if case .mismatch(let expected, let actual) = verification {
                throw DownloadError.hashMismatch(fileName: item.name, expected: expected, actual: actual)
            }

            _ = try? PartialFiles.remove(at: final)
            do {
                try FileManager.default.moveItem(at: partial, to: final)
            } catch {
                throw DownloadError.transport(.writeFailed("cannot finalise \(item.name): \(error)"))
            }

            results.append(VerifiedFile(name: item.name, sha256: verification.digest,
                                        size: onDisk, verification: verification))
            bytesFromFinishedFiles += onDisk
            bytesOnDisk += onDisk

            // A terminal tick for this file, so a UI that only shows changes
            // still sees 100% for a file that arrived in one burst.
            onProgress(DownloadProgress(
                modelID: plan.modelID,
                fileIndex: index,
                fileCount: plan.files.count,
                fileName: item.name,
                bytesReceivedForFile: onDisk,
                bytesTotalForFile: item.size,
                bytesReceivedOverall: bytesFromFinishedFiles,
                bytesTotalOverall: plan.totalBytes))
        }

        return DownloadReport(modelID: plan.modelID,
                              revision: plan.revision,
                              workingDirectory: configuration.workingDirectory,
                              sourceHost: plan.allowlistedHost ?? "unknown",
                              files: results,
                              totalBytesOnDisk: bytesOnDisk,
                              diskCheck: diskCheck,
                              resumedFileNames: resumedFileNames.sorted(),
                              sizeAnomalyFileNames: sizeAnomalies.sorted())
    }

    /// Cancel and failure both land here. Never touches anything outside the
    /// working directory, and refuses to run if the directory looks like a
    /// system path (see `CleanupSafety`).
    private func cleanupAfterFailure(_ plan: DownloadPlan) {
        switch configuration.cleanupPolicy {
        case .removePartialsAndWorkingDirectory:
            PartialFiles.removePartials(for: plan.files, in: configuration.workingDirectory)
            _ = try? CleanupSafety.removeWorkingDirectory(configuration.workingDirectory)
        case .keepPartialsForResume:
            // Keeping the partial files *is* the point of this policy: the next
            // run resumes from them with a Range request.
            break
        }
    }

    /// Exposed for the service's explicit "cancel and clean" path and for tests.
    public func cleanup(plan: DownloadPlan) {
        cleanupAfterFailure(plan)
    }
}
