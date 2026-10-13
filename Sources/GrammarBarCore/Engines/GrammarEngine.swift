import Foundation

public enum EngineKind: String, CaseIterable, Codable, Sendable {
    case apple
    case local

    public var displayName: String {
        switch self {
        case .apple: return "Apple on-device model"
        case .local: return "Offline model"
        }
    }
}

/// Normal pass, or the tightened retry used when the first pass over-edited.
public enum CorrectionMode: Sendable, Equatable {
    case normal
    case minimalEdit
}

public enum EngineStatus: Sendable, Equatable {
    /// The engine can serve a correction right now.
    case ready
    /// The engine exists but needs the user to install something.
    case needsSetup(String)
    /// The engine cannot be used on this machine or in this configuration.
    case unavailable(String)

    public var isReady: Bool { if case .ready = self { return true }; return false }

    public var message: String? {
        switch self {
        case .ready: return nil
        case .needsSetup(let m), .unavailable(let m): return m
        }
    }
}

/// Both engines drive `FoundationModels.LanguageModelSession`.
///
/// v1 of the plan assumed two different streaming semantics (Apple yields
/// cumulative snapshots, MLX yields deltas) and required `LocalGrammarEngine`
/// to accumulate to match. The macOS 27 SDK ships `MLXFoundationModels`, which
/// adapts an MLX model to `FoundationModels.LanguageModel`, so that divergence
/// no longer exists and this protocol is now a thin facade rather than a shim.
public protocol GrammarEngine: Sendable {
    var kind: EngineKind { get }
    var status: EngineStatus { get }
    func prewarm() async
    /// Yields CUMULATIVE text (the full output so far), for every engine.
    func correct(_ text: String,
                 mode: CorrectionMode,
                 delimiter: TextDelimiter) -> AsyncThrowingStream<String, Error>
    func unload() async
}

public extension GrammarEngine {
    func correct(_ text: String) -> AsyncThrowingStream<String, Error> {
        correct(text, mode: .normal, delimiter: .angleTags)
    }
}

public enum EngineError: Error, LocalizedError, Equatable {
    case notReady(String)
    case notImplemented(String)
    case modelDeclined(String)

    public var errorDescription: String? {
        switch self {
        case .notReady(let m): return m
        case .notImplemented(let m): return m
        case .modelDeclined(let m): return m
        }
    }
}
