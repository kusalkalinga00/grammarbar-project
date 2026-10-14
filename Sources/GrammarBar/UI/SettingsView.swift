import SwiftUI
import GrammarBarCore

struct SettingsView: View {
    @Environment(EngineRegistry.self) private var registry
    @Environment(\.dismiss) private var dismiss

    // Sized from its contents, not by eye: header ~46, engine section ~90,
    // privacy section ~76, two dividers and 24pt of padding - about 240. 380 leaves
    // room for a wrapped status line without the dead space the old 520 produced
    // once the model-management section was removed. The body is a ScrollView, so a
    // longer status message scrolls rather than clipping.
    private static let settingsHeight: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("GrammarBar Settings")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    engineSection
                    Divider()
                    privacySection
                }
                .padding(12)
            }
        }
        .frame(width: 460, height: Self.settingsHeight)
    }

    /// Read-only on purpose. v1 has one usable engine, and the offline engine
    /// cannot be installed yet, so a selector here would offer a dead end. What
    /// remains is the diagnostic: which engine is active, and whether it is
    /// working - the first thing to check when corrections stop.
    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Engine").font(.subheadline.weight(.semibold))

            LabeledContent("In use") {
                Text(registry.selected.displayName)
            }
            .font(.caption)

            LabeledContent("Status") {
                Text(statusText)
                    .foregroundStyle(registry.currentStatus.isReady ? .green : .orange)
            }
            .font(.caption)

            if let reason = registry.unavailableReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusText: String {
        switch registry.currentStatus {
        case .ready: return "Ready"
        case .needsSetup(let m), .unavailable(let m): return m
        }
    }

    /// v1 makes a stronger claim than the plan did, so the wording changed with it.
    ///
    /// The plan described an optional model download handled by a separate helper.
    /// That helper is not in this build and the app does not link it, so the
    /// accurate statement is that there is no network path at all - verified by
    /// inspection: no networking API appears in this target or in GrammarBarCore,
    /// and the only library that contains one is not linked here.
    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Privacy").font(.subheadline.weight(.semibold))

            Text("Your text is processed on this Mac and never leaves it.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            Text("This version has no networking code at all - no account, no "
               + "analytics, no crash reporting, no update check. Corrections work "
               + "with Wi-Fi turned off.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
