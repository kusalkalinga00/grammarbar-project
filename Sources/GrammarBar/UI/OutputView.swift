import SwiftUI
import AppKit
import GrammarBarCore

struct OutputView: View {
    @Environment(CorrectionViewModel.self) private var model
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Corrected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.state.isRunning {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                Button(copied ? "Copied" : "Copy") { copy() }
                    .disabled(model.output.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            statusLine

            ScrollView {
                Text(model.output.isEmpty ? " " : model.output)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        } else if case .done(.unchanged) = model.state {
            Label("No changes needed", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .padding(.horizontal, 12)
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
