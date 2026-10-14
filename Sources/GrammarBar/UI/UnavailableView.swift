import SwiftUI
import GrammarBarCore

/// The whole panel body when the app cannot correct anything.
///
/// In v1 there is one usable engine, so this is not a degraded mode - it is the
/// complete state when Apple Intelligence is off. `reason` comes from
/// `EngineStatus`, so the user sees the specific cause (turned off, still
/// downloading, unsupported device) rather than a generic failure.
struct UnavailableView: View {
    let reason: String
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Semantic font, not a fixed point size: `.system(size:)` ignores the user's
            // text-size setting entirely.
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text("GrammarBar needs Apple Intelligence")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("GrammarBar corrects text entirely on this Mac using Apple's "
               + "built-in model. This version has no fallback engine.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open System Settings", action: onOpenSettings)
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
