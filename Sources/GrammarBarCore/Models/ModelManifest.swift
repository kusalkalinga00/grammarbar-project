import Foundation

/// Written into the model directory at install time and re-read at load time,
/// so the hashes on disk are checked against what we verified on download.
public struct ModelManifest: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var revision: String
    public var license: String
    public var licenseText: String?
    public var sourceHost: String
    public var totalBytes: Int64
    public var installedAt: Date
    public var files: [FileRecord]

    public struct FileRecord: Codable, Sendable, Equatable {
        public var name: String
        public var sha256: String
        public var size: Int64

        public init(name: String, sha256: String, size: Int64) {
            self.name = name
            self.sha256 = sha256
            self.size = size
        }
    }

    public init(id: String, displayName: String, revision: String, license: String,
                licenseText: String? = nil, sourceHost: String, totalBytes: Int64,
                installedAt: Date = Date(), files: [FileRecord]) {
        self.id = id
        self.displayName = displayName
        self.revision = revision
        self.license = license
        self.licenseText = licenseText
        self.sourceHost = sourceHost
        self.totalBytes = totalBytes
        self.installedAt = installedAt
        self.files = files
    }
}
