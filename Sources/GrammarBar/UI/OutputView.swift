import SwiftUI
import AppKit
import GrammarBarCore

struct OutputView: View {
    @Environment(CorrectionViewModel.self) private var model
    @State private var copied = false

    private var placeholder: String {
        if model.state.isRunning { return "Correcting…" }
        if !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Press ⌘↩ to correct."
        }
        return "Corrected text appears here."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Corrected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.state.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Correcting")
                }

                Spacer()

                Button(copied ? "Copied" : "Copy") { copy() }
                    .disabled(model.output.isEmpty)
                    .accessibilityLabel(copied ? "Copied to clipboard"
                                               : "Copy corrected text to clipboard")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            statusLine

            ScrollView {
                Group {
                    if model.output.isEmpty {
                        // An empty box reads as a rendering bug. Saying what will
                        // appear here makes the same space look intentional.
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(model.output)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let warning = model.warning {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .accessibilityLabel("Warning. \(warning)")
        } else if case .done(.unchanged) = model.state {
            Label("No changes needed", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .padding(.horizontal, 12)
                .accessibilityLabel("No changes were needed.")
        } else if case .failed(let message) = model.state {
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.output, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}
