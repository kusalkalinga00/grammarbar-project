import SwiftUI
import GrammarBarCore

struct ModelManagerView: View {
    @Environment(EngineRegistry.self) private var registry

    private var installed: ModelManifest? { registry.store.installedManifest() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Offline model").font(.subheadline.weight(.semibold))

            if let manifest = installed {
                VStack(alignment: .leading, spacing: 4) {
                    Text(manifest.displayName).font(.body)
                    Text("\(manifest.totalBytes / 1_000_000) MB · \(manifest.license) · rev \(manifest.revision)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Source: \(manifest.sourceHost)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Remove", role: .destructive) {
                        try? registry.store.remove(id: manifest.id, revision: manifest.revision)
                    }
                    Spacer()
                }
            } else {
                Text("No offline model installed. Download or import one to correct text "
                   + "without Apple Intelligence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Download offline model…") { /* week 4: XPC downloader */ }
                        .disabled(true)
                    Button("Import from file…") { /* week 3: NSOpenPanel + ModelStore */ }
                        .disabled(true)
                    Spacer()
                }
                .help("Wired up in weeks 3-4 (ModelStore + XPC downloader)")
            }

            if !ModelCatalog.all.isEmpty {
                Divider()
                Text("Available in the catalog (sizes measured, not estimated):")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(ModelCatalog.all, id: \.id) { model in
                    Text("• \(model.displayName) — \(model.approxMegabytes) MB · \(model.license)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
