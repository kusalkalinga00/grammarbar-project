import Foundation
import ServiceManagement
import Observation

/// Launch-at-login, backed by `SMAppService.mainApp` (plan v2 FR6).
///
/// `SMAppService` is documented for apps the system knows properly, and this app is **ad-hoc
/// signed** - it carries no Developer ID. Whether the registration succeeds in that
/// configuration was an open question for most of the project, so the state is read *back*
/// from the system after every change and surfaced. A failure is therefore visible instead of
/// silently doing nothing.
///
/// Note the third state: `requiresApproval` means the item was registered but macOS wants the
/// user to allow it in System Settings, which is a different situation from not registered.
@Observable
@MainActor
public final class LaunchAtLogin {

    public enum State: Equatable {
        case on
        case off
        /// Registered, but waiting for the user to allow it in System Settings.
        case needsApproval
        case unavailable(String)

        public var isOn: Bool { self == .on }
    }

    public private(set) var state: State = .off
    /// Set when the last attempt failed, so the UI can say why rather than just not change.
    public private(set) var lastError: String?

    public init() { refresh() }

    public func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled: state = .on
        case .notRegistered: state = .off
        case .requiresApproval: state = .needsApproval
        case .notFound: state = .unavailable("This app has no login item the system can find.")
        @unknown default: state = .unavailable("Unrecognised login-item status.")
        }
    }

    /// - Returns: nil on success, otherwise a user-facing reason.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> String? {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
            refresh()
            return error.localizedDescription
        }
        refresh()
        // Registering can land in `requiresApproval` rather than `enabled`; that is not a
        // failure, but the user has to finish it in System Settings.
        return nil
    }

    /// A short line explaining the current state, or nil when it is simply on or off.
    public var note: String? {
        switch state {
        case .on, .off: return lastError
        case .needsApproval:
            return "Allow GrammarBar in System Settings > General > Login Items."
        case .unavailable(let why): return why
        }
    }
}
