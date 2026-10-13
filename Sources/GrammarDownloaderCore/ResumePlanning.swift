import Foundation

// MARK: - Resume decision

public enum ResumePlan: Sendable, Equatable {
    /// Nothing on disk, start at byte 0.
    case startFresh
    /// Append from `fromByte`; the partial file is already exactly that long.
    case append(fromByte: Int64)
    /// The partial file is already the expected size — hash it, do not re-fetch.
    case verifyExisting(byteCount: Int64)
    /// The partial file is longer than the catalog says the file can be: untrustworthy.
    case discardCorrupt(byteCount: Int64)

    public var resumableByteCount: Int64 {
        switch self {
        case .startFresh: return 0
        case .append(let from): return from
        case .verifyExisting(let count): return count
        case .discardCorrupt: return 0
        }
    }
}

/// Pure resume bookkeeping: given what is on disk and what the catalog promised,
/// decide whether to restart, continue, or verify.
public enum ResumePlanner {

    public static func plan(partialByteCount: Int64, expectedTotal: Int64) -> ResumePlan {
        let onDisk = max(0, partialByteCount)
        if onDisk == 0 { return .startFresh }
        // An unknown or nonsensical expected size cannot justify appending to
        // whatever happens to be on disk.
        guard expectedTotal > 0 else { return .discardCorrupt(byteCount: onDisk) }
        if onDisk > expectedTotal { return .discardCorrupt(byteCount: onDisk) }
        if onDisk == expectedTotal { return .verifyExisting(byteCount: onDisk) }
        return .append(fromByte: onDisk)
    }

    /// What the server's response means for the file we are writing.
    public enum RangeReconciliation: Sendable, Equatable {
        /// 206 while we asked for a range: the server honoured it, keep appending.
        case appendConfirmed
        /// 200 while we asked for a range: the server ignored `Range` and is
        /// sending the whole body — the partial file must be truncated.
        case serverIgnoredRange
        /// 416: our offset is past the end; restart from zero.
        case rangeNotSatisfiable
        /// 206 without a range request: nonsensical; restart from zero.
        case unexpectedPartialContent
        /// A plain 200 for a fresh request.
        case fresh
        case httpError(Int)
    }

    /// PURE. `requestedFromByte` is the offset we put in the `Range` header
    /// (`0` when we sent none).
    public static func reconcile(statusCode: Int, requestedFromByte: Int64) -> RangeReconciliation {
        let askedForRange = requestedFromByte > 0
        switch statusCode {
        case 200: return askedForRange ? .serverIgnoredRange : .fresh
        case 206: return askedForRange ? .appendConfirmed : .unexpectedPartialContent
        case 416: return .rangeNotSatisfiable
        default: return .httpError(statusCode)
        }
    }
}

// MARK: - Files on disk

/// Everything that touches the working directory. Nothing here writes outside it.
public enum PartialFiles {

    public static let partialSuffix = ".partial"

    public static func partialURL(for item: DownloadItem, in directory: URL) -> URL {
        directory.appendingPathComponent(item.partialFileName, isDirectory: false)
    }

    public static func finalURL(for item: DownloadItem, in directory: URL) -> URL {
        directory.appendingPathComponent(item.name, isDirectory: false)
    }

    /// Deliberately not `URL.resourceValues(forKeys: [.fileSizeKey])`: Foundation
    /// caches resource values on the `URL` instance, so a second read on the same
    /// URL value returns the *stale* size — which silently breaks resume offsets
    /// (measured: a resumed append of 300 bytes still reported 200 on disk).
    public static func byteCount(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    public static func exists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public static func remove(at url: URL) throws {
        guard exists(at: url) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Makes `url` exactly `byteCount` bytes long, creating it if needed and
    /// truncating when a stale partial is longer than the resume offset.
    @discardableResult
    public static func prepareForAppend(at url: URL, byteCount: Int64) throws -> URL {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !exists(at: url) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        if byteCount <= 0 { return url }
        try handle.truncate(atOffset: UInt64(byteCount))
        return url
    }

    /// Used on cancel and on failure: drops every partial file for the plan.
    /// Already-verified final files are left alone.
    public static func removePartials(for items: [DownloadItem], in directory: URL) {
        for item in items {
            try? remove(at: partialURL(for: item, in: directory))
        }
    }

    public static func remainingPartialNames(for items: [DownloadItem], in directory: URL) -> [String] {
        items.map(\.partialFileName).filter { exists(at: directory.appendingPathComponent($0)) }.sorted()
    }
}

// MARK: - Cleanup safety

/// Guard rails so a bug in a higher layer cannot turn `removeItem` into an
/// uninstaller. The downloader only ever deletes its own working directory.
public enum CleanupSafety {

    /// Never removable, regardless of who asks.
    public static let protectedPaths: Set<String> = [
        "/", "/Users", "/System", "/Library", "/Applications", "/private", "/tmp", "/var", "/Volumes",
    ]

    public static func isRemovable(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path.isEmpty || protectedPaths.contains(path) { return false }
        // Require some depth: /Users/someone/… is fine, /Users/someone is not.
        guard url.standardizedFileURL.pathComponents.count >= 4 else { return false }
        if path == URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path { return false }
        return true
    }

    /// Removes the working directory if, and only if, it looks disposable.
    /// Returns whether anything was removed.
    @discardableResult
    public static func removeWorkingDirectory(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard isRemovable(url) else { throw DownloadError.workingDirectoryNotRemovable(url.path) }
        try FileManager.default.removeItem(at: url)
        return true
    }
}
