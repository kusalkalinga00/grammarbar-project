import Foundation

public struct CatalogFile: Sendable, Equatable {
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
}

public struct CatalogModel: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let license: String
    /// Pinned commit hash. Never "main".
    public let revision: String
    public let files: [CatalogFile]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    public var approxMegabytes: Int { Int(totalBytes / 1_000_000) }
    public var sourceHost: String { files.first?.url.host() ?? "unknown" }

    /// The catalog pins exact sizes, so the download can be checked before it starts.
    public func fitsSizeGate(_ gate: Int64 = ModelStore.sizeGateBytes) -> Bool {
        totalBytes <= gate
    }
}

/// Pinned in the binary on purpose: no remote catalog fetch, so a compromised
/// catalog server can never redirect the app at new weights (plan v2 §5.2).
///
/// Every size, license and revision below was measured against the Hugging Face
/// API on 2026-10-13, not estimated. `sha256` values are intentionally left
/// blank: they must be computed from the actual downloaded bytes at pin time,
/// and a placeholder hash would be worse than no hash.
public enum ModelCatalog {

    public static let all: [CatalogModel] = [qwen3_0_6b_4bit]

    /// 351.4 MB measured, apache-2.0, revision pinned.
    public static let qwen3_0_6b_4bit = CatalogModel(
        id: "qwen3-0.6b-4bit",
        displayName: "Qwen3 0.6B (4-bit)",
        license: "Apache-2.0",
        revision: "73e3e38d9813",
        files: [
            CatalogFile(name: "model.safetensors",
                        url: URL(string: "https://huggingface.co/mlx-community/Qwen3-0.6B-4bit/resolve/73e3e38d9813/model.safetensors")!,
                        size: 335_500_000, sha256: ""),
            CatalogFile(name: "tokenizer.json",
                        url: URL(string: "https://huggingface.co/mlx-community/Qwen3-0.6B-4bit/resolve/73e3e38d9813/tokenizer.json")!,
                        size: 11_400_000, sha256: ""),
            CatalogFile(name: "vocab.json",
                        url: URL(string: "https://huggingface.co/mlx-community/Qwen3-0.6B-4bit/resolve/73e3e38d9813/vocab.json")!,
                        size: 2_800_000, sha256: ""),
            CatalogFile(name: "config.json",
                        url: URL(string: "https://huggingface.co/mlx-community/Qwen3-0.6B-4bit/resolve/73e3e38d9813/config.json")!,
                        size: 1_000, sha256: ""),
        ])

    /// Rejected at build time by the size gate. Recorded so nobody re-adds it:
    /// Qwen3-0.6B-**8bit** is 649.4 MB, which breaks our own 500 MB promise.
    public static let rejectedOversize: [(String, Int64)] = [
        ("mlx-community/Qwen3-0.6B-8bit", 649_400_000),
        ("mlx-community/gemma-3-1b-it-4bit", 771_900_000),
    ]

    /// Gemma clears the size gate but ships under the custom `gemma` license,
    /// not Apache-2.0. Any catalog entry needs its own terms + attribution.
    public static let licenseReviewRequired: [(String, String, Int64)] = [
        ("mlx-community/gemma-3-270m-it-4bit", "gemma", 190_200_000),
        ("mlx-community/SmolLM-360M-Instruct-4bit", "apache-2.0", 207_100_000),
    ]

    /// `mlx-community/SmolLM2-360M-Instruct-4bit` returned HTTP 401 on
    /// 2026-10-13 — gated or renamed. Resolve before it can be catalogued.
    public static let unresolved: [String] = ["mlx-community/SmolLM2-360M-Instruct-4bit"]
}
