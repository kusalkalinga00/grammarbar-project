import SwiftUI
import GrammarBarCore

/// Shown when the selected engine cannot serve a correction (plan v2 §4.8).
struct SuggestionCard: View {
    let suggestion: EngineRegistry.Suggestion
    let action: () -> Void

    private var title: String {
        switch suggestion.kind {
        case .switchToLocal: return "Switch to the offline model"
        case .offerDownload: return "Set up a correction engine"
        }
    }

    private var buttonTitle: String {
        switch suggestion.kind {
        case .switchToLocal: return "Use offline model"
        case .offerDownload: return "Open Settings"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.circle")
                .font(.subheadline.weight(.semibold))

            Text(suggestion.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(buttonTitle, action: action)
            }
        }
        .padding(12)
        .background(.yellow.opacity(0.10))
    }
}
