import Foundation

// MARK: - Progress

/// One progress tick. Both the per-file figures and the overall figures are
/// carried, because the UI shows "file 2 of 4" as well as a single bar.
public struct DownloadProgress: Sendable, Equatable {

    public let modelID: String
    public let fileIndex: Int
    public let fileCount: Int
    public let fileName: String
    public let bytesReceivedForFile: Int64
    public let bytesTotalForFile: Int64
    public let bytesReceivedOverall: Int64
    public let bytesTotalOverall: Int64

    public init(modelID: String,
                fileIndex: Int,
                fileCount: Int,
                fileName: String,
                bytesReceivedForFile: Int64,
                bytesTotalForFile: Int64,
                bytesReceivedOverall: Int64,
                bytesTotalOverall: Int64) {
        self.modelID = modelID
        self.fileIndex = fileIndex
        self.fileCount = fileCount
        self.fileName = fileName
        self.bytesReceivedForFile = bytesReceivedForFile
        self.bytesTotalForFile = bytesTotalForFile
        self.bytesReceivedOverall = bytesReceivedOverall
        self.bytesTotalOverall = bytesTotalOverall
    }

    public var fileFraction: Double {
        guard bytesTotalForFile > 0 else { return bytesReceivedForFile > 0 ? 1 : 0 }
        return min(1, max(0, Double(bytesReceivedForFile) / Double(bytesTotalForFile)))
    }

    public var overallFraction: Double {
        guard bytesTotalOverall > 0 else { return 0 }
        return min(1, max(0, Double(bytesReceivedOverall) / Double(bytesTotalOverall)))
    }
}

// MARK: - Errors

public enum TransportError: Error, Equatable, LocalizedError {
    /// The transfer died mid-flight; the partial file is intact and resumable.
    case interrupted
    case cancelled
    case hostNotAllowed(origin: String)
    case redirectRejected(from: String, to: String, reason: String)
    case httpStatus(Int)
    case notHTTPResponse
    case writeFailed(String)
    case underlying(String)

    /// Only an interruption is worth retrying with a `Range` header.
    public var isRetryable: Bool {
        if case .interrupted = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .interrupted: return "The transfer was interrupted."
        case .cancelled: return "The transfer was cancelled."
        case .hostNotAllowed(let origin): return "Refused to contact '\(origin)' — not allowlisted."
        case .redirectRejected(let from, let to, let reason):
            return "Refused the redirect \(from) → \(to): \(reason)."
        case .httpStatus(let status): return "The server returned HTTP \(status)."
        case .notHTTPResponse: return "The server returned a non-HTTP response."
        case .writeFailed(let detail): return "Could not write the download: \(detail)."
        case .underlying(let detail): return detail
        }
    }
}

public enum DownloadError: Error, Equatable, LocalizedError {
    case emptyPlan
    case rejectedURL(URLRejection)
    case redirectRejected(from: String, to: String)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case httpStatus(fileName: String, status: Int)
    case truncatedFile(fileName: String, expected: Int64, received: Int64)
    case hashMismatch(fileName: String, expected: String, actual: String)
    case escapedWorkingDirectory(fileName: String)
    case workingDirectoryNotRemovable(String)
    case cancelled
    case transport(TransportError)

    public var isCancellation: Bool {
        switch self {
        case .cancelled: return true
        case .transport(let transport): return transport == .cancelled
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .emptyPlan:
            return "There is nothing to download."
        case .rejectedURL(let reason):
            return "Refused the download URL: \(reason.description)."
        case .redirectRejected(let from, let to):
            return "Refused a redirect from \(from) to \(to) — downloads stay on one host."
        case .insufficientDiskSpace(let required, let available):
            return "Not enough disk space: \(Self.megabytes(required)) MB needed, \(Self.megabytes(available)) MB free."
        case .httpStatus(let fileName, let status):
            return "Fetching \(fileName): the server returned HTTP \(status)."
        case .truncatedFile(let fileName, let expected, let received):
            return "\(fileName) is incomplete: \(received) of \(expected) bytes arrived."
        case .hashMismatch(let fileName, _, _):
            return "\(fileName) failed SHA-256 verification — the download was discarded."
        case .escapedWorkingDirectory(let fileName):
            return "Refused to write '\(fileName)' outside the download working directory."
        case .workingDirectoryNotRemovable(let path):
            return "Refused to delete \(path) — it is not a download working directory."
        case .cancelled:
            return "The download was cancelled."
        case .transport(let error):
            return error.errorDescription
        }
    }

    private static func megabytes(_ bytes: Int64) -> Int64 { bytes / 1_000_000 }
}

// MARK: - Report

public struct VerifiedFile: Sendable, Equatable {
    public let name: String
    public let sha256: String
    public let size: Int64
    public let verification: FileVerification

    public init(name: String, sha256: String, size: Int64, verification: FileVerification) {
        self.name = name
        self.sha256 = sha256
        self.size = size
        self.verification = verification
    }

    public var isVerified: Bool { verification.isVerified }
}

/// What the service hands back. The app turns this into a `ModelManifest` via
/// `ModelStore.install(fromTemporaryDirectory:catalog:licenseText:)`, which
/// re-derives everything from the bytes on disk — so this report is advisory,
/// never the source of truth.
public struct DownloadReport: Sendable, Equatable {

    public let modelID: String
    public let revision: String
    /// The folder to hand to `ModelStore.install`. Contains only final, verified files.
    public let workingDirectory: URL
    public let sourceHost: String
    public let files: [VerifiedFile]
    public let totalBytesOnDisk: Int64
    public let diskCheck: DiskSpaceDecision
    public let resumedFileNames: [String]
    /// Files whose on-disk size exceeded the catalog size. The catalog sizes are
    /// measured approximations, so this is flagged, not treated as fatal.
    public let sizeAnomalyFileNames: [String]

    public init(modelID: String,
                revision: String,
                workingDirectory: URL,
                sourceHost: String,
                files: [VerifiedFile],
                totalBytesOnDisk: Int64,
                diskCheck: DiskSpaceDecision,
                resumedFileNames: [String] = [],
                sizeAnomalyFileNames: [String] = []) {
        self.modelID = modelID
        self.revision = revision
        self.workingDirectory = workingDirectory
        self.sourceHost = sourceHost
        self.files = files
        self.totalBytesOnDisk = totalBytesOnDisk
        self.diskCheck = diskCheck
        self.resumedFileNames = resumedFileNames
        self.sizeAnomalyFileNames = sizeAnomalyFileNames
    }

    /// Files the catalog has not pinned with a real digest. Empty today for the
    /// Qwen3 entry (see `ModelCatalog`), so the app can say "digest recorded,
    /// not yet pinned" instead of claiming verification.
    public var unpinnedFileNames: [String] {
        files.filter { if case .recordedUnpinned = $0.verification { return true }; return false }
            .map(\.name).sorted()
    }

    public var isFullyPinned: Bool { unpinnedFileNames.isEmpty }

    public var verifiedFileCount: Int { files.filter(\.isVerified).count }

    public var fileNames: [String] { files.map(\.name) }
}
