import SwiftUI
import AppKit
import GrammarBarCore

struct PanelView: View {
    @Environment(EngineRegistry.self) private var registry
    @Environment(CorrectionViewModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var showSettings = false

    // Panel sizing.
    //
    // Fixed (non-scrolling) space is roughly:
    //   header                       ~38   (picker + vertical padding)
    //   output header + paddings     ~38
    //   input block                  ~128  (padding 24 + editor 72 + row 32)
    //   two dividers                 ~2
    //                                ----
    //                                ~206
    //
    // At the old 560 that left ~350pt of mostly-empty output area, which read as
    // dead space. 420 leaves ~215pt — enough for a paragraph without looking
    // hollow, and the empty state now says what will appear there.
    private static let panelWidth: CGFloat = 420
    private static let panelHeight: CGFloat = 420

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
        .frame(width: Self.panelWidth, height: Self.panelHeight)
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

            // Clears both fields. Enabled whenever there is anything to remove,
            // including mid-run — the run is cancelled and the fields emptied.
            Button {
                model.clear()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!model.hasContent)
            .keyboardShortcut("k", modifiers: .command)
            .help("Clear input and output (⌘K)")

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")

            // A Dock-less app with no menu bar menus has no other quit path —
            // without this the only ways out are pkill or Activity Monitor.
            // ⌘Q matches the platform convention.
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit GrammarBar (⌘Q)")
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
