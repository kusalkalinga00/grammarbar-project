import Foundation
import CryptoKit

public enum ModelStoreError: Error, LocalizedError, Equatable {
    case missingFiles([String])
    case sizeGateExceeded(Int64)
    case destinationExists(String)
    case hashMismatch([String])

    public var errorDescription: String? {
        switch self {
        case .missingFiles(let f):
            return "The download is incomplete — missing: \(f.joined(separator: ", "))."
        case .sizeGateExceeded(let b):
            return "The model is \(b / 1_000_000) MB, over the 500 MB limit."
        case .destinationExists(let p):
            return "A model is already installed at \(p)."
        case .hashMismatch(let f):
            return "These files failed verification: \(f.joined(separator: ", "))."
        }
    }
}

public enum Hashing {
    public static func sha256(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Owns `<Application Support>/GrammarBar/Models/`. The XPC downloader drops
/// files in a temp folder and hands over a URL; everything after that — the
/// required-file check, the size gate, hashing, the atomic move, the manifest —
/// happens here, so an "Import from file…" takes the identical path (plan v2 §5.3).
public struct ModelStore: Sendable {

    /// Our own promise to the user, enforced in code.
    public static let sizeGateBytes: Int64 = 500 * 1024 * 1024

    public static let requiredFileNames: Set<String> = ["config.json", "tokenizer.json"]

    public let root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.root = base.appendingPathComponent("GrammarBar/Models", isDirectory: true)
        }
    }

    public func directory(forID id: String, revision: String) -> URL {
        root.appendingPathComponent("\(id)-\(revision)", isDirectory: true)
    }

    public func installedManifest() -> ModelManifest? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for entry in entries {
            let manifestURL = entry.appendingPathComponent("manifest.json")
            // Must mirror the encoder in `install`, or decoding fails silently
            // and an installed model looks absent.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(ModelManifest.self, from: data)
            else { continue }
            return manifest
        }
        return nil
    }

    /// Files that must be present for a model to be loadable.
    public func missingRequiredFiles(in directory: URL) -> [String] {
        let present = Set((try? FileManager.default
            .contentsOfDirectory(atPath: directory.path)) ?? [])
        var missing = ModelStore.requiredFileNames.subtracting(present).sorted()
        if !present.contains(where: { $0.hasSuffix(".safetensors") }) {
            missing.append("*.safetensors")
        }
        return missing
    }

    /// Verifies, then moves into place. Throws before touching `root` if
    /// anything is wrong, so a bad download can never become "installed".
    @discardableResult
    public func install(fromTemporaryDirectory temp: URL,
                        catalog: CatalogModel,
                        licenseText: String? = nil)
    throws -> ModelManifest {

        let missing = missingRequiredFiles(in: temp)
        if !missing.isEmpty { throw ModelStoreError.missingFiles(missing) }

        let measured = Self.measuredSize(ofDirectory: temp)
        guard measured <= ModelStore.sizeGateBytes else {
            throw ModelStoreError.sizeGateExceeded(measured)
        }

        let destination = directory(forID: catalog.id, revision: catalog.revision)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw ModelStoreError.destinationExists(destination.path)
        }

        // Hash only what the catalog pinned with a real digest; empty pins are
        // recorded as-is rather than faked.
        var records: [ModelManifest.FileRecord] = []
        var mismatched: [String] = []
        for file in catalog.files {
            let onDisk = temp.appendingPathComponent(file.name)
            guard FileManager.default.fileExists(atPath: onDisk.path) else { continue }
            let digest = (try? Hashing.sha256(ofFileAt: onDisk)) ?? ""
            if !file.sha256.isEmpty, digest != file.sha256 { mismatched.append(file.name) }
            records.append(.init(name: file.name,
                                 sha256: digest,
                                 size: Self.fileSize(at: onDisk)))
        }
        guard mismatched.isEmpty else { throw ModelStoreError.hashMismatch(mismatched) }

        let manifest = ModelManifest(
            id: catalog.id,
            displayName: catalog.displayName,
            revision: catalog.revision,
            license: catalog.license,
            licenseText: licenseText,
            sourceHost: catalog.sourceHost,
            totalBytes: measured,
            files: records)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temp, to: destination)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest)
            .write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)

        return manifest
    }

    public func remove(id: String, revision: String) throws {
        let dir = directory(forID: id, revision: revision)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Helpers

    public static func measuredSize(ofDirectory url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            total += fileSize(at: item)
        }
        return total
    }

    public static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
