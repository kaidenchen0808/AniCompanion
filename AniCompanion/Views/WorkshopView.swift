import SwiftUI
import UniformTypeIdentifiers

// MARK: - WorkshopView
//
// The Pet Workshop — a standalone window for managing VRM character models. Instant-apply
// (no Save button): tapping a model switches her immediately via the live-reload chain
// (`AppState.selectModel` → `loadModel` → the three-vrm scene swaps, no page reload).

struct WorkshopView: View {
    @EnvironmentObject private var appState: AppState

    @State private var models: [VRMModelInfo] = []
    @State private var selected: String = ""
    @State private var importErrorText: String?
    @State private var deleteErrorText: String?
    @State private var pendingDelete: VRMModelInfo?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            List {
                ForEach(models) { model in
                    row(model)
                }
            }
            .listStyle(.inset)

            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 380)
        .onAppear { refresh() }
        .alert(
            Text("Couldn't import the model"),
            isPresented: Binding(
                get: { importErrorText != nil },
                set: { if !$0 { importErrorText = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: importErrorText ?? "")
        }
        .alert(
            Text("Couldn't delete the model"),
            isPresented: Binding(
                get: { deleteErrorText != nil },
                set: { if !$0 { deleteErrorText = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: deleteErrorText ?? "")
        }
        .confirmationDialog(
            Text("Delete “\(pendingDelete?.displayName ?? "")”?"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Text("Pet Workshop")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func row(_ model: VRMModelInfo) -> some View {
        let isSelected = model.filename == selected
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "person.crop.square")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                Text(verbatim: model.filename)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.isBuiltIn
                 ? String(localized: "Built-in", comment: "Workshop: shipped model tag")
                 : String(localized: "Imported", comment: "Workshop: user-imported model tag"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
            if !model.isBuiltIn {
                Button {
                    pendingDelete = model
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Delete this model", comment: "Workshop: delete button tooltip"))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { select(model) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    importModel()
                } label: {
                    Label("Import VRM…", systemImage: "plus")
                }
                Spacer()
            }
            .controlSize(.small)
            Text("Imported models are stored in Application Support. Alicia Solid (© DWANGO) is for your own use only.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func refresh() {
        models = VRMModelStore.shared.availableModels()
        selected = appState.vrmModelFilename
    }

    private func select(_ model: VRMModelInfo) {
        guard model.filename != selected else { return }
        selected = model.filename
        appState.selectModel(filename: model.filename)
    }

    private func importModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "vrm") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let filename = try VRMModelStore.shared.importModel(from: url)
            refresh()
            if let imported = models.first(where: { $0.filename == filename }) {
                select(imported)   // auto-select the newcomer — she tries it on immediately
            }
        } catch {
            importErrorText = error.localizedDescription
        }
    }

    private func confirmDelete() {
        guard let model = pendingDelete else { return }
        pendingDelete = nil
        do {
            // If she's wearing the model being deleted, switch her back to the default FIRST
            // (live reload), then remove the file — never a deleted-file load.
            if model.filename == selected {
                selected = VRMModelStore.defaultModelFilename
                appState.selectModel(filename: VRMModelStore.defaultModelFilename)
            }
            try VRMModelStore.shared.deleteModel(filename: model.filename)
            refresh()
        } catch {
            deleteErrorText = error.localizedDescription
            refresh()
        }
    }
}
