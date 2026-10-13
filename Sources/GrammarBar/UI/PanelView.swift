import SwiftUI
import AppKit
import GrammarBarCore

struct PanelView: View {
    @Environment(EngineRegistry.self) private var registry
    @Environment(CorrectionViewModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let suggestion = registry.suggestion {
                SuggestionCard(suggestion: suggestion) { handle(suggestion) }
                Divider()
            }

            OutputView()
            Divider()
            InputView()
        }
        .frame(width: 420, height: 560)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(registry)
        }
        .onAppear {
            // Dock-less apps lose keyboard focus without this, which breaks
            // ⌘V/⌘C in the text fields. Verified necessary in plan v2 §4.1.
            NSApp.activate()
        }
        .task { await registry.prewarmCurrent() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("Engine", selection: Binding(
                get: { registry.selected },
                set: { value in Task { await registry.select(value) } }
            )) {
                ForEach(EngineKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 230)

            Spacer()

            if let ms = model.totalMilliseconds, !model.state.isRunning {
                Text("\(Int(ms)) ms")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func handle(_ suggestion: EngineRegistry.Suggestion) {
        switch suggestion.kind {
        case .switchToLocal:
            Task { await registry.select(.local) }
        case .offerDownload:
            // Week 4 replaces this with the XPC downloader. Until then the
            // honest action is sending the user to the relevant System Settings
            // pane rather than pretending a download exists.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIntelligence") {
                openURL(url)
            } else if let url = URL(string: "x-apple.systempreferences:") {
                openURL(url)
            }
        }
    }
}
