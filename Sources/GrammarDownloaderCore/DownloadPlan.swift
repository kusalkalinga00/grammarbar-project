import Foundation

/// One file to fetch. Deliberately **not** `ModelCatalog.CatalogFile`: the download
/// core has no dependency on `GrammarBarCore` (Package.swift declares it standalone),
/// and the XPC boundary cannot carry Swift structs anyway — the service maps its
/// `GDDownloadFile` payload into this.
public struct DownloadItem: Sendable, Equatable {

    public let name: String
    public let url: URL
    public let size: Int64
    public let sha256: String

    public init(name: String, url: URL, size: Int64, sha256: String) {
        self.name = name
        self.url = url
        self.size = size
        self.sha256 = sha256
    }

    /// An empty catalog digest means "not pinned yet", not "trust everything".
    public var hasPinnedDigest: Bool { !sha256.isEmpty }

    public var partialFileName: String { name + PartialFiles.partialSuffix }
}

/// Catalog-supplied file names become path components, so they are validated as
/// such rather than trusted. A catalog entry named `../../Library/evil` must never
/// be able to make the downloader write outside its working directory.
public enum FileNamePolicy {

    public static func isSafe(_ name: String) -> Bool {
        rejectionReason(for: name) == nil
    }

    public static func rejectionReason(for name: String) -> String? {
        if name.isEmpty { return "empty file name" }
        if name == "." || name == ".." { return "relative path component" }
        if name.contains("/") || name.contains("\\") { return "path separator in file name" }
        if name.contains("\0") { return "NUL byte in file name" }
        if name.hasPrefix(".") { return "hidden file" }
        if name.hasSuffix(PartialFiles.partialSuffix) { return "reserved '.partial' suffix" }
        return nil
    }

    /// The last-resort containment check: a resolved child must still sit under
    /// the working directory we handed out.
    public static func isContained(_ child: URL, in parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        if parentPath == "/" { return childPath.hasPrefix("/") }
        return childPath.hasPrefix(parentPath + "/")
    }
}

/// A validated, self-consistent set of files to download as one unit.
///
/// Construction is where "EXACTLY ONE allowlisted HTTPS host" is enforced
/// (plan v2 §5.2/§5.3): every file must be HTTPS, and every file must share a
/// single origin. Anything else throws before a socket is opened.
public struct DownloadPlan: Sendable, Equatable {

    public let modelID: String
    public let revision: String
    public let files: [DownloadItem]
    public let allowlist: HostAllowlist

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public var pinnedFileCount: Int { files.filter(\.hasPinnedDigest).count }

    public var allowlistedHost: String? { allowlist.hostList.first }

    public enum ValidationError: Error, Equatable, LocalizedError {
        case emptyPlan
        case unsafeFileName(String)
        case invalidURL(name: String, reason: URLRejection)
        case multipleHosts([String])

        public var errorDescription: String? {
            switch self {
            case .emptyPlan:
                return "The download plan contains no files."
            case .unsafeFileName(let name):
                return "Unsafe file name '\(name)' in the catalog."
            case .invalidURL(let name, let reason):
                return "'\(name)' has an unusable URL: \(reason.description)."
            case .multipleHosts(let hosts):
                return "The catalog spans \(hosts.count) hosts (\(hosts.joined(separator: ", "))); exactly one is allowed."
            }
        }
    }

    public init(modelID: String, revision: String, files: [DownloadItem]) throws {
        guard !files.isEmpty else { throw ValidationError.emptyPlan }

        var origins: Set<AllowlistedOrigin> = []
        for file in files {
            if let reason = FileNamePolicy.rejectionReason(for: file.name) {
                throw ValidationError.unsafeFileName("\(file.name) (\(reason))")
            }
            guard file.url.scheme?.lowercased() == "https" else {
                throw ValidationError.invalidURL(name: file.name, reason: .schemeNotHTTPS(scheme: file.url.scheme))
            }
            let hasCredentials = file.url.user?.isEmpty == false || file.url.password?.isEmpty == false
            guard !hasCredentials else {
                throw ValidationError.invalidURL(name: file.name, reason: .credentialsInURL)
            }
            guard let origin = AllowlistedOrigin(url: file.url) else {
                throw ValidationError.invalidURL(name: file.name, reason: .missingHost)
            }
            origins.insert(origin)
        }

        guard origins.count == 1 else {
            throw ValidationError.multipleHosts(origins.map(\.description).sorted())
        }

        self.modelID = modelID
        self.revision = revision
        self.files = files
        self.allowlist = HostAllowlist(origins: origins)
    }
}
