import Foundation
import Observation

/// Owns which engine is active, and reports whether it can serve a correction.
///
/// v1 ships the Apple engine only. `LocalGrammarEngine`, `ModelStore` and
/// `ModelCatalog` stay compiled and correct behind the same protocol, but nothing
/// can install weights yet - the in-app downloader is the deferred v2 work - so the
/// app offers no way to choose them. That is a deliberate v1 shape, not an
/// unfinished feature: a control whose only other option can never work is a bug
/// with a nicer coat on.
@Observable
public final class EngineRegistry {

    /// Always `.apple` in v1.
    ///
    /// This deliberately does NOT read a stored preference from earlier builds. A
    /// value of `.local` written back when the engine picker existed would otherwise
    /// survive into a build with no picker, stranding the app on an engine that can
    /// never become ready and offering no way back out. There is nothing to persist
    /// while there is only one choice.
    public private(set) var selected: EngineKind = .apple

    public let apple: AppleGrammarEngine
    public let local: LocalGrammarEngine
    public let store: ModelStore

    public init(store: ModelStore = ModelStore()) {
        self.store = store
        self.apple = AppleGrammarEngine()
        self.local = LocalGrammarEngine(store: store)
    }

    public var current: any GrammarEngine {
        selected == .apple ? apple : local
    }

    public var currentStatus: EngineStatus { current.status }

    /// `nil` means the app can correct text. Non-nil is the reason it cannot,
    /// phrased for the user.
    ///
    /// v1 has exactly one such reason - Apple Intelligence unavailable - and no
    /// alternative to offer, because there is nothing installable to offer.
    public var unavailableReason: String? { currentStatus.message }

    /// Engine switching, kept for the offline engine. Nothing in the v1 UI calls
    /// this, since there is only one engine to offer; the cancel-then-unload
    /// ordering is the part v2 must not lose (NFR3, and the "switching mid-request"
    /// behaviour test in the plan).
    public func select(_ kind: EngineKind) async {
        guard kind != selected else { return }
        await current.unload()
        selected = kind
    }

    public func prewarmCurrent() async {
        guard current.status.isReady else { return }
        await current.prewarm()
    }
}
