import Foundation

/// Offline engine. Week 5 in the plan.
///
/// This type is deliberately a stub with the integration seam marked, so the
/// whole pipeline (chunking, sanitizing, TenseGuard, the no-op guard, the UI)
/// can be built and tested against the Apple engine before any MLX dependency
/// lands. Adding 350 MB of model download and a SwiftPM dependency on
/// `mlx-swift-lm` now would slow the build loop for no signal.
///
/// Week-5 wiring (verified against mlx-swift-lm 3.x, 2026-10-13):
///
///   .package(url: "https://github.com/ml-explore/mlx-swift-lm",
///            .upToNextMinor(from: "3.32.3"))
///   .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0")
///   .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0")
///
///   import MLXFoundationModels, MLXHuggingFace, MLXLLM
///   let model = #huggingFaceLanguageModel(configuration: ..., capabilities: [])
///   let session = LanguageModelSession(model: model,
///                                      instructions: Prompts.instructions(for: .local))
///
/// Then `correct(_:mode:delimiter:)` becomes identical to the Apple engine's
/// body, because both take a `LanguageModel`. That is the whole point of the
/// macOS 27 `MLXFoundationModels` bridge: one session code path, two models.
public final class LocalGrammarEngine: GrammarEngine {

    public let kind: EngineKind = .local
    private let store: ModelStore
    /// Swift 6 will require this be an actor or guarded by a lock. For a stub
    /// that only records intent, `nonisolated(unsafe)` states that plainly.
    nonisolated(unsafe) private var idleSince: Date?

    public init(store: ModelStore) {
        self.store = store
    }

    public var status: EngineStatus {
        guard let manifest = store.installedManifest() else {
            return .needsSetup("Download or import an offline model.")
        }
        if manifest.totalBytes > ModelStore.sizeGateBytes {
            return .unavailable("The installed model is larger than the 500 MB limit.")
        }
        return .ready
    }

    public var installedModel: ModelManifest? { store.installedManifest() }

    public func prewarm() async {}

    public func correct(_ text: String,
                        mode: CorrectionMode,
                        delimiter: TextDelimiter) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard status.isReady else {
                continuation.finish(throwing: EngineError.notReady(
                    status.message ?? "The offline model isn't ready."))
                return
            }
            continuation.finish(throwing: EngineError.notImplemented(
                "MLX generation lands in week 5 — see the integration seam in LocalGrammarEngine."))
        }
    }

    public func unload() async {
        idleSince = Date()
    }
}
