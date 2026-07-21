import CoFleetCore
import SwiftUI

#if !os(watchOS)
public struct CoFleetPetLibraryView: View {
    @Bindable private var workspaceStore: WorkspaceStore
    private let project: CoFleetProject
    private let onProjectUpdated: (CoFleetProject) -> Void
    private let onDone: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var manualPath = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    public init(
        workspaceStore: WorkspaceStore,
        project: CoFleetProject,
        onProjectUpdated: @escaping (CoFleetProject) -> Void,
        onDone: (() -> Void)? = nil
    ) {
        self.workspaceStore = workspaceStore
        self.project = project
        self.onProjectUpdated = onProjectUpdated
        self.onDone = onDone
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    if workspaceStore.pets.isEmpty {
                        ContentUnavailableView(
                            "No Imported Pets",
                            systemImage: "shippingbox",
                            description: Text("Discover Codex pets on this host or import a compatible package path.")
                        )
                    } else {
                        ForEach(workspaceStore.pets) { pet in
                            importedRow(pet)
                        }
                    }
                } header: {
                    Text("Imported on this host")
                } footer: {
                    Text("Only the selected pet atlas is downloaded to this device.")
                }

                Section("Found in ~/.codex/pets") {
                    if workspaceStore.discoveredPets.isEmpty {
                        Text("No unimported compatible packages found.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(workspaceStore.discoveredPets) { pet in
                            HStack(spacing: 10) {
                                Image(systemName: "sparkles.rectangle.stack")
                                    .foregroundStyle(CoFleetTheme.cyan)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pet.displayName).font(.headline)
                                    Text("Codex pet v\(pet.spriteVersionNumber)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Import") { run { try await importPet(path: pet.sourcePath) } }
                                    .buttonStyle(.bordered)
                                    .disabled(isWorking)
                            }
                        }
                    }
                }

                Section("Import another host path") {
                    TextField("/absolute/path/to/pet or pet.json", text: $manualPath)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { importManualPath() }
                    Button {
                        importManualPath()
                    } label: {
                        Label("Import Package", systemImage: "square.and.arrow.down")
                    }
                    .disabled(
                        isWorking || manualPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .navigationTitle("Project Pet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onDone?()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        run { try await workspaceStore.discoverPets() }
                    } label: {
                        Label("Discover", systemImage: "arrow.clockwise")
                    }
                    .disabled(isWorking)
                }
            }
        }
        .frame(minWidth: sheetMinimumWidth, minHeight: sheetMinimumHeight)
        .task {
            do {
                try await workspaceStore.refreshPets()
                try await workspaceStore.discoverPets()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("Pet Library", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The request could not be completed.")
        }
    }

    private func importedRow(_ pet: CoFleetPetManifest) -> some View {
        let selected = workspaceStore.selectedPetID == pet.id
        return Button {
            run {
                if let updated = try await workspaceStore.selectPet(id: pet.id) {
                    onProjectUpdated(updated)
                }
            }
        } label: {
            HStack(spacing: 12) {
                if selected {
                    CoFleetPetSpriteView(
                        name: project.displayName,
                        manifest: pet,
                        asset: workspaceStore.selectedPetAsset,
                        action: project.state.actionIndicator,
                        size: 48
                    )
                } else {
                    Image(systemName: "shippingbox.fill")
                        .font(.title2)
                        .frame(width: 48, height: 48)
                        .background(CoFleetTheme.violet.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(pet.displayName).font(.headline)
                    Text("Codex pet v\(pet.spriteVersionNumber) · \(pet.pixelWidth)×\(pet.pixelHeight)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !pet.description.isEmpty {
                        Text(pet.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? CoFleetTheme.green : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var sheetMinimumWidth: CGFloat? {
        #if os(macOS)
        520
        #else
        nil
        #endif
    }

    private var sheetMinimumHeight: CGFloat? {
        #if os(macOS)
        520
        #else
        nil
        #endif
    }

    private func importManualPath() {
        let path = manualPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        run {
            try await importPet(path: path)
            manualPath = ""
        }
    }

    private func importPet(path: String) async throws {
        guard let pet = try await workspaceStore.importPet(sourcePath: path) else { return }
        if let updated = try await workspaceStore.selectPet(id: pet.id) {
            onProjectUpdated(updated)
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
#endif
