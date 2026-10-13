import Foundation
import CryptoKit

/// SHA-256 over files, computed in a stream so a 335 MB safetensors file never
/// lands in memory.
///
/// This intentionally duplicates `Hashing.sha256(ofFileAt:)` from `GrammarBarCore`:
/// `GrammarDownloaderCore` has no dependency on `GrammarBarCore` (see Package.swift),
/// and the two must agree byte-for-byte — both emit lower-case hex SHA-256.
/// `FileHashingTests` pins the digest against a known vector so drift is caught.
public enum FileHashing {

    public static let chunkSize = 1 << 20  // 1 MiB

    public static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hexString(hasher.finalize())
    }

    public static func sha256(of data: Data) -> String {
        hexString(SHA256.hash(data: data))
    }

    static func hexString<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum FileDigestFormat {
    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A pinned digest is 64 lower-case hex characters. Anything else is a
    /// catalog mistake, not a digest we should compare against.
    public static func isValid(_ raw: String) -> Bool {
        let value = normalize(raw)
        guard value.count == 64 else { return false }
        return value.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }
}

/// The outcome of hashing one downloaded file against the catalog pin.
///
/// The empty-pin case is a first-class outcome on purpose (download requirements):
/// a catalog entry with `sha256 == ""` has **not been pinned yet**, so the digest is
/// recorded but verification is explicitly *not* claimed — it is not treated as a
/// mismatch and it is not treated as a pass.
public enum FileVerification: Sendable, Equatable {
    case verified(digest: String)
    case recordedUnpinned(digest: String)
    case mismatch(expected: String, actual: String)

    public var digest: String {
        switch self {
        case .verified(let digest): return digest
        case .recordedUnpinned(let digest): return digest
        case .mismatch(_, let actual): return actual
        }
    }

    /// True only when the catalog pinned a digest and the bytes matched it.
    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    public var isPinnedButWrong: Bool {
        if case .mismatch = self { return true }
        return false
    }
}

public enum Verifier {

    /// PURE. `expectedPinnedDigest` is the catalog value verbatim (may be empty).
    public static func classify(expectedPinnedDigest: String, computed: String) -> FileVerification {
        let expected = FileDigestFormat.normalize(expectedPinnedDigest)
        let actual = FileDigestFormat.normalize(computed)
        if expected.isEmpty { return .recordedUnpinned(digest: actual) }
        if expected == actual { return .verified(digest: actual) }
        return .mismatch(expected: expected, actual: actual)
    }
}
