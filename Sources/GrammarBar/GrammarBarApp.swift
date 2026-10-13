import SwiftUI
import GrammarBarCore

/// LSUIElement app: no Dock icon, menu bar only (plan v2 §4.1).
/// The `LSUIElement` key itself belongs to the .app bundle and is set in
/// `project.yml`; SwiftPM cannot express it.
@main
struct GrammarBarApp: App {

    @State private var registry = EngineRegistry()
    @State private var model = CorrectionViewModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(registry)
                .environment(model)
        } label: {
            Image(systemName: "checkmark.bubble")
        }
        .menuBarExtraStyle(.window)
    }
}
