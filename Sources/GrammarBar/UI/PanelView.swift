import SwiftUI
import AppKit
import GrammarBarCore

struct PanelView: View {
    @Environment(EngineRegistry.self) private var registry
    @Environment(CorrectionViewModel.self) private var model
    @State private var showSettings = false

    // Panel sizing.
    //
    // Fixed (non-scrolling) space is roughly:
    //   header                       ~30   (wordmark + controls + vertical padding)
    //   output header + paddings     ~38
    //   input block                  ~128  (padding 24 + editor 72 + row 32)
    //   two dividers                 ~2
    //                                ----
    //                                ~198
    //
    // At the old 560 that left ~350pt of mostly-empty output area, which read as
    // dead space. 420 leaves ~222pt - enough for a paragraph without looking
    // hollow, and the empty state now names what will appear there. Dropping the
    // engine picker (v1 has a single engine) gave the header back ~8pt, which goes
    // to the output area.
    private static let panelWidth: CGFloat = 420
    private static let panelHeight: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let reason = registry.unavailableReason {
                // Nothing can be corrected, so there is nothing to type into. Live
                // editors here would invite the user to type a paragraph and then
                // watch Submit do nothing.
                UnavailableView(reason: reason) { openAppleIntelligenceSettings() }
            } else {
                OutputView()
                Divider()
                InputView()
            }
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
            // A wordmark, not a picker: v1 offers one engine, so a picker would
            // only be a way to select an engine that can never become ready.
            Text("GrammarBar")
                .font(.subheadline.weight(.semibold))

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

    /// Opens the Apple Intelligence pane in System Settings.
    ///
    /// Builds each URL and reports whether the open actually succeeded, rather than
    /// trusting `URL(string:)` to be non-nil - which it is for almost any input, so
    /// the old check could pass while the button silently did nothing.
    private func openAppleIntelligenceSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preferences.AppleIntelligence",
            "x-apple.systempreferences:",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
        // Last resort: System Settings itself, so the button is never inert.
        if let url = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(url)
        }
    }
}
