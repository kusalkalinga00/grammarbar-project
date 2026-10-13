import Foundation
import Observation

/// Owns which engine is active and applies the availability decision from
/// plan v2 §4.8. Deliberately not @MainActor-annotated so the SwiftUI `@State`
/// default-value path stays clean; all mutation happens from view code.
@Observable
public final class EngineRegistry {

    public struct Suggestion: Equatable {
        public enum Kind: Equatable { case switchToLocal, offerDownload }
        public let kind: Kind
        public let reason: String
    }

    public private(set) var selected: EngineKind
    public let apple: AppleGrammarEngine
    public let local: LocalGrammarEngine
    public let store: ModelStore

    private let defaults: UserDefaults
    private static let selectedKey = "GrammarBar.selectedEngine"

    public init(defaults: UserDefaults = .standard, store: ModelStore = ModelStore()) {
        self.defaults = defaults
        self.store = store
        self.apple = AppleGrammarEngine()
        self.local = LocalGrammarEngine(store: store)
        let raw = defaults.string(forKey: Self.selectedKey) ?? EngineKind.apple.rawValue
        self.selected = EngineKind(rawValue: raw) ?? .apple
    }

    public var current: any GrammarEngine {
        selected == .apple ? apple : local
    }

    public var currentStatus: EngineStatus { current.status }

    /// nil means "show the normal UI".
    public var suggestion: Suggestion? {
        if current.status.isReady { return nil }

        let appleReason = apple.status.message ?? "Apple Intelligence is unavailable."
        switch selected {
        case .apple:
            if store.installedManifest() != nil {
                return Suggestion(kind: .switchToLocal, reason: appleReason)
            }
            return Suggestion(kind: .offerDownload, reason: appleReason)
        case .local:
            return Suggestion(kind: .offerDownload,
                              reason: local.status.message ?? "No offline model is installed.")
        }
    }

    /// Switching engines must cancel cleanly and unload the outgoing model
    /// (plan v2 NFR3, and the §8 "switching mid-request" behaviour test).
    public func select(_ kind: EngineKind) async {
        guard kind != selected else { return }
        await current.unload()
        selected = kind
        defaults.set(kind.rawValue, forKey: Self.selectedKey)
    }

    public func prewarmCurrent() async {
        guard current.status.isReady else { return }
        await current.prewarm()
    }
}
