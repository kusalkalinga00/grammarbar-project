import SwiftUI
import AppKit
import GrammarBarCore

struct PanelView: View {
    @Environment(EngineRegistry.self) private var registry
    @Environment(CorrectionViewModel.self) private var model
    @Environment(LaunchAtLogin.self) private var login

    // Panel sizing.
    //
    // Fixed (non-scrolling) space is roughly:
    //   header                       ~30   (status badge + controls + vertical padding)
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

    @Environment(\.dynamicTypeSize) private var typeSize

    /// The panel is a fixed-size popover, so a larger text-size setting has nowhere to grow.
    /// Growing the height is the only option that neither clips nor overlaps; the editors
    /// inside scroll, so extra height is absorbed there.
    private var heightForTypeSize: CGFloat {
        if typeSize.isAccessibilitySize { return Self.panelHeight + 150 }
        switch typeSize {
        case .xSmall, .small, .medium, .large: return Self.panelHeight
        case .xLarge: return Self.panelHeight + 40
        case .xxLarge: return Self.panelHeight + 80
        default: return Self.panelHeight + 115
        }
    }

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

            Divider()
            footer
        }
        .frame(width: Self.panelWidth, height: heightForTypeSize)
        .onAppear {
            // Dock-less apps lose keyboard focus without this, which breaks
            // ⌘V/⌘C in the text fields. Verified necessary in plan v2 §4.1.
            NSApp.activate()
        }
        .task { await registry.prewarmCurrent() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            engineBadge

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
            // Without this VoiceOver announces the SF Symbol name, "trash".
            .accessibilityLabel("Clear input and output")

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
            .accessibilityLabel("Quit GrammarBar")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Launch at login (FR6).
    ///
    /// It lives in the panel rather than a Settings window because it is the only remaining
    /// preference and a whole window for one checkbox was the reason the window went away.
    /// The reading of the state is authoritative - it comes back from `SMAppService` after
    /// every change - so an ad-hoc signed app that cannot register shows that plainly instead
    /// of a toggle that silently does nothing.
    private var footer: some View {
        HStack(spacing: 8) {
            Toggle("Launch at login", isOn: Binding(
                get: { login.state.isOn || login.state == .needsApproval },
                set: { _ = login.setEnabled($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            .disabled(isLoginItemUnavailable)
            .accessibilityLabel("Launch GrammarBar at login")

            if let note = login.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(note)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var isLoginItemUnavailable: Bool {
        if case .unavailable = login.state { return true }
        return false
    }

    // MARK: - Engine status

    /// The engine's state at a glance, replacing the Settings sheet.
    ///
    /// Carries a text label as well as the dot so it does not depend on colour
    /// alone (NFR6), and keeps the privacy statement as its tooltip: that claim
    /// used to live in Settings, and for this app it is the whole point, so it
    /// should not vanish from the UI entirely.
    private var engineBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isReady ? Color.green : Color.orange)
                .frame(width: 7, height: 7)

            Text(isReady ? "On-device" : "Unavailable")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help(engineDescription)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Engine status. \(engineDescription)")
    }

    private var isReady: Bool { registry.currentStatus.isReady }

    private var engineDescription: String {
        guard isReady else {
            return registry.unavailableReason ?? "The correction engine is not available."
        }
        return "Apple's on-device model. Your text is processed on this Mac and never "
             + "leaves it - there is no networking code, no analytics and no account."
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
