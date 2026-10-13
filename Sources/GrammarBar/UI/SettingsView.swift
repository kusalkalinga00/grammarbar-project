import SwiftUI
import GrammarBarCore

struct SettingsView: View {
    @Environment(EngineRegistry.self) private var registry
    @Environment(\.dismiss) private var dismiss

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
                    ModelManagerView()
                    Divider()
                    privacySection
                }
                .padding(12)
            }
        }
        .frame(width: 460, height: 520)
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Engine").font(.subheadline.weight(.semibold))

            Picker("Engine", selection: Binding(
                get: { registry.selected },
                set: { value in Task { await registry.select(value) } }
            )) {
                ForEach(EngineKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)

            LabeledContent("Status") {
                Text(statusText)
                    .foregroundStyle(registry.currentStatus.isReady ? .green : .orange)
            }
            .font(.caption)
        }
    }

    private var statusText: String {
        switch registry.currentStatus {
        case .ready: return "Ready"
        case .needsSetup(let m), .unavailable(let m): return m
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Privacy").font(.subheadline.weight(.semibold))
            Text("Your text is processed on this Mac and never leaves it. "
               + "This app has no network access. The only network use is an optional "
               + "model download that you start, handled by a separate helper that never "
               + "sees your text.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
