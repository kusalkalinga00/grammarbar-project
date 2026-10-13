import SwiftUI
import GrammarBarCore

struct InputView: View {
    @Environment(EngineRegistry.self) private var registry
    @Environment(CorrectionViewModel.self) private var model

    private var canSubmit: Bool {
        !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: Binding(get: { model.input }, set: { model.input = $0 }))
                .font(.body)
                .scrollContentBackground(.hidden)
                // Trimmed from 96/140 to buy back height for the panel without
                // starving the editor — still ~3 lines at rest.
                .frame(minHeight: 72, maxHeight: 110)
                .padding(6)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 10) {
                Text("⌘↩ to submit")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let ttft = model.firstTokenMilliseconds, model.state.isRunning {
                    Text("first token \(Int(ttft)) ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.state.isRunning {
                    Button("Cancel", role: .destructive) { model.cancel() }
                        .keyboardShortcut(.escape, modifiers: [])
                } else {
                    Button("Submit") { model.submit(engine: registry.current) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canSubmit)
                }
            }
        }
        .padding(12)
    }
}
