import Foundation
import FoundationModels

/// Apple's on-device system model. Zero bytes shipped; the OS owns the weights.
///
/// Recon baseline on macOS 27.0.1 / M5: 10/12 errors fixed, 6/6 already-correct
/// sentences returned byte-identical, 362 ms mean TTFT (971 ms cold).
public final class AppleGrammarEngine: GrammarEngine {

    public let kind: EngineKind = .apple
    private let model = SystemLanguageModel.default

    public init() {}

    public var status: EngineStatus {
        switch model.availability {
        case .available:
            return .ready
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Apple Intelligence is turned off.")
        case .unavailable(.modelNotReady):
            return .unavailable("The system model is still downloading.")
        case .unavailable(.deviceNotEligible):
            return .unavailable("This Mac doesn't support Apple Intelligence.")
        @unknown default:
            return .unavailable("The Apple model isn't available.")
        }
    }

    /// Live context window. Never hardcode this (plan v2 §4.6).
    public var contextSize: Int { model.contextSize }

    public var supportsCurrentLocale: Bool { model.supportsLocale() }

    /// `tokenCount(for:)` is `@available(macOS 26.4, *)` — gate it.
    public func tokenCount(for text: String) async throws -> Int? {
        if #available(macOS 26.4, *) {
            return try await model.tokenCount(for: text)
        }
        return nil
    }

    public func prewarm() async {
        // Cold first call measured 971 ms vs ~330 ms warm; this pays that cost
        // when the panel opens instead of after the user presses Submit.
        let session = LanguageModelSession(model: model, instructions: Prompts.base)
        session.prewarm()
    }

    public func correct(_ text: String,
                        mode: CorrectionMode,
                        delimiter: TextDelimiter) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let instructions = mode == .minimalEdit
                        ? Prompts.minimalEdit
                        : Prompts.instructions(for: .apple)
                    // Fresh session per chunk: the task is stateless.
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    // `GenerationOptions(sampling:)` is deprecated in the macOS 27
                    // SDK; `samplingMode` is available from macOS 26.0, so no gate.
                    let options = GenerationOptions(samplingMode: .greedy)
                    let stream = session.streamResponse(to: delimiter.wrap(text), options: options)
                    for try await snapshot in stream {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func unload() async {
        // The system model is owned by the OS; nothing for us to release.
    }
}
