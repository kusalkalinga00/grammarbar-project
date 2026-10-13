import SwiftUI
import GrammarBarCore

/// Full-panel state for when there is nothing the app can do at all.
struct UnavailableView: View {
    let reason: String
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("No correction engine available").font(.headline)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings", action: onOpenSettings)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
