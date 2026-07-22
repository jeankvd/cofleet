import CoFleetCore
import SwiftUI

#if !os(watchOS)
public struct CoFleetPetLibraryView: View {
    @Bindable private var workspaceStore: WorkspaceStore
    private let project: CoFleetProject
    private let onProjectUpdated: (CoFleetProject) -> Void
    private let onDone: (() -> Void)?
    private let onHatchWithCodex: (@MainActor () async throws -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var manualPath = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var selectedSourceID = "installed"
    @State private var catalogSearch = ""
    @State private var installingCatalogPetID: String?

    public init(
        workspaceStore: WorkspaceStore,
        project: CoFleetProject,
        onProjectUpdated: @escaping (CoFleetProject) -> Void,
        onDone: (() -> Void)? = nil,
        onHatchWithCodex: (@MainActor () async throws -> Void)? = nil
    ) {
        self.workspaceStore = workspaceStore
        self.project = project
        self.onProjectUpdated = onProjectUpdated
        self.onDone = onDone
        self.onHatchWithCodex = onHatchWithCodex
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sourcePicker
                Divider().opacity(0.3)
                if selectedSourceID == "installed" {
                    installedLibrary
                } else {
                    communityCatalog
                }
            }
            .navigationTitle("Project Pet")
            .searchable(
                text: $catalogSearch,
                isPresented: .constant(selectedSourceID != "installed"),
                prompt: "Search this catalog"
            )
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
                try await workspaceStore.refreshPetCatalogs()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .task(id: "\(selectedSourceID)|\(catalogSearch)") {
            guard selectedSourceID != "installed" else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                try await workspaceStore.loadPetCatalog(
                    id: selectedSourceID,
                    query: catalogSearch.trimmingCharacters(in: .whitespacesAndNewlines),
                    reset: true
                )
            } catch is CancellationError {
                return
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

    private var sourcePicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                sourceButton(id: "installed", title: "Installed", symbol: "internaldrive")
                ForEach(workspaceStore.petCatalogs) { catalog in
                    sourceButton(id: catalog.id, title: catalog.displayName, symbol: catalogSymbol(catalog.id))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .background(.ultraThinMaterial)
    }

    private func sourceButton(id: String, title: String, symbol: String) -> some View {
        let selected = selectedSourceID == id
        return Button {
            selectedSourceID = id
            catalogSearch = ""
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? CoFleetTheme.violet : Color.white.opacity(0.07), in: Capsule())
                .overlay { Capsule().stroke(Color.white.opacity(selected ? 0.12 : 0.08)) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cofleet.pet.catalog.\(id)")
    }

    private var installedLibrary: some View {
        List {
            if let onHatchWithCodex {
                Section {
                    Button {
                        run {
                            try await onHatchWithCodex()
                            onDone?()
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "wand.and.stars")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(CoFleetTheme.cyan)
                                .frame(width: 42, height: 42)
                                .background(CoFleetTheme.cyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Hatch a Pet with Codex").font(.headline)
                                Text("Describe it in a new Codex task, then import it automatically.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isWorking || !workspaceStore.isHostOnline)
                    .accessibilityIdentifier("cofleet.pet.hatch-with-codex")
                } header: {
                    Text("Create")
                } footer: {
                    Text(
                        workspaceStore.isHostOnline
                            ? "Codex uses the host’s $hatch-pet skill and normal approval settings. Only a fully validated package is imported."
                            : "Reconnect this project’s host to hatch a pet."
                    )
                }
            }

            Section {
                if workspaceStore.pets.isEmpty {
                    ContentUnavailableView(
                        "No Imported Pets",
                        systemImage: "pawprint",
                        description: Text("Discover Codex pets on this host or choose a community catalog.")
                    )
                } else {
                    ForEach(workspaceStore.pets) { pet in importedRow(pet) }
                }
            } header: {
                Text("Imported on this host")
            } footer: {
                Text("Only the selected pet atlas is downloaded to this device.")
            }

            Section("Found in ~/.codex/pets") {
                if workspaceStore.discoveredPets.isEmpty {
                    Text("No unimported compatible packages found.").foregroundStyle(.secondary)
                } else {
                    ForEach(workspaceStore.discoveredPets) { pet in
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles.rectangle.stack").foregroundStyle(CoFleetTheme.cyan)
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
                Button { importManualPath() } label: {
                    Label("Import Package", systemImage: "square.and.arrow.down")
                }
                .disabled(isWorking || manualPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var communityCatalog: some View {
        let items = workspaceStore.catalogPetsByCatalogID[selectedSourceID] ?? []
        let loading = workspaceStore.loadingPetCatalogIDs.contains(selectedSourceID)
        if loading, items.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading catalog…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            ContentUnavailableView.search(text: catalogSearch)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: catalogColumns, spacing: 12) {
                    ForEach(items) { item in catalogCard(item) }
                }
                .padding(14)

                if workspaceStore.catalogNextCursorByCatalogID[selectedSourceID] != nil {
                    Button {
                        run {
                            try await workspaceStore.loadPetCatalog(
                                id: selectedSourceID,
                                query: catalogSearch.trimmingCharacters(in: .whitespacesAndNewlines),
                                reset: false
                            )
                        }
                    } label: {
                        if loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Load more", systemImage: "arrow.down.circle")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(loading || isWorking)
                    .padding(.bottom, 12)
                }

                catalogFooter
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
            }
        }
    }

    private var catalogColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 154, maximum: 210), spacing: 12)]
    }

    private func catalogCard(_ item: CoFleetPetCatalogItem) -> some View {
        let installing = installingCatalogPetID == item.id
        return Button {
            chooseCatalogPet(item)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(CoFleetTheme.violet.opacity(0.13))
                    CoFleetPetCatalogPreview(item: item)
                        .padding(7)
                    if installing {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(.black.opacity(0.55))
                        ProgressView().tint(.white)
                    }
                }
                .frame(height: 104)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(item.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(item.license)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isWorking || !workspaceStore.isHostOnline)
        .accessibilityLabel("Install \(item.displayName) from \(selectedCatalog?.displayName ?? "community catalog")")
    }

    @ViewBuilder
    private var catalogFooter: some View {
        if let catalog = selectedCatalog {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(catalog.licenseSummary)
                }
                if let url = URL(string: catalog.repositoryURL) {
                    Link("Open \(catalog.displayName) repository", destination: url)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectedCatalog: CoFleetPetCatalog? {
        workspaceStore.petCatalogs.first { $0.id == selectedSourceID }
    }

    private func catalogSymbol(_ id: String) -> String {
        switch id {
        case "codex-pokepets": "sparkles"
        case "petdex": "square.grid.2x2"
        case "awesome-codex-pet": "star.fill"
        case "codex-anime-pets": "paintpalette.fill"
        default: "pawprint.fill"
        }
    }

    private func chooseCatalogPet(_ item: CoFleetPetCatalogItem) {
        guard !isWorking else { return }
        isWorking = true
        installingCatalogPetID = item.id
        Task { @MainActor in
            defer {
                isWorking = false
                installingCatalogPetID = nil
            }
            do {
                guard let pet = try await workspaceStore.installCatalogPet(
                    catalogID: item.catalogID,
                    petID: item.id
                ) else { return }
                if let updated = try await workspaceStore.selectPet(id: pet.id) {
                    onProjectUpdated(updated)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
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
                        action: .idle,
                        size: 48
                    )
                } else {
                    Image(systemName: "pawprint.fill")
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

private struct CoFleetPetCatalogPreview: View {
    let item: CoFleetPetCatalogItem

    var body: some View {
        if let url = URL(string: item.previewURL), url.scheme == "https" {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    if item.previewKind == .atlas {
                        GeometryReader { geometry in
                            image
                                .resizable()
                                .interpolation(.none)
                                .frame(
                                    width: geometry.size.width * 8,
                                    height: geometry.size.height * CGFloat(item.spriteVersionNumber == 2 ? 11 : 9),
                                    alignment: .topLeading
                                )
                        }
                        .clipped()
                    } else {
                        image
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                    }
                } else if phase.error != nil {
                    Image(systemName: "pawprint.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        } else {
            Image(systemName: "pawprint.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
