import Foundation
import Observation

@MainActor
@Observable
public final class WorkspaceStore {
    public private(set) var note: CoFleetNote?
    public private(set) var todos: [CoFleetTodoItem] = []
    public private(set) var pets: [CoFleetPetManifest] = []
    public private(set) var discoveredPets: [CoFleetDiscoveredPet] = []
    public private(set) var selectedPetID: String?
    public private(set) var selectedPetAsset: CoFleetPetAsset?
    public private(set) var battlePetManifestsByProjectID: [String: CoFleetPetManifest] = [:]
    public private(set) var battlePetAssetsByProjectID: [String: CoFleetPetAsset] = [:]
    public private(set) var battleTodosByProjectID: [String: [CoFleetTodoItem]] = [:]
    public private(set) var battleTodoLoadingProjectIDs: Set<String> = []
    public private(set) var isLoadingPetAsset = false
    public private(set) var noteConflict: CoFleetNoteSaveResult?
    public private(set) var isHostOnline = true
    public private(set) var errorMessage: String?
    public var noteDraft = "" {
        didSet { persistCurrentNoteDraft() }
    }
    public var todoDraft = ""

    @ObservationIgnored private let repository: any CoFleetWorkspaceRepository
    @ObservationIgnored private let noteDraftStorage: any CoFleetNoteDraftStorage
    @ObservationIgnored private var hostID: CoFleetHostID?
    @ObservationIgnored private var projectID: String?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var activeDraftRecord: CoFleetNoteDraftRecord?
    @ObservationIgnored private var isApplyingNoteDraft = false
    @ObservationIgnored private var openGeneration = UUID()
    @ObservationIgnored private var selectedPetAssetGeneration = UUID()
    @ObservationIgnored private var battlePetGeneration = UUID()
    @ObservationIgnored private var battleTodoGeneration = UUID()
    @ObservationIgnored private var petCatalogByHostID: [CoFleetHostID: [CoFleetPetManifest]] = [:]

    public init(
        repository: any CoFleetWorkspaceRepository,
        noteDraftStorage: any CoFleetNoteDraftStorage = CoFleetUserDefaultsNoteDraftStorage()
    ) {
        self.repository = repository
        self.noteDraftStorage = noteDraftStorage
    }

    public var hasUnsavedNoteDraft: Bool {
        if let note { return noteDraft != note.markdown }
        return activeDraftRecord != nil || !noteDraft.isEmpty
    }
    public var loadedHostID: CoFleetHostID? { hostID }
    public var loadedProjectID: String? { projectID }
    public var loadedSessionID: String? { sessionID }
    public var canMutateTodos: Bool { isHostOnline }

    public func open(
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String? = nil,
        isHostOnline: Bool = true,
        selectedPetID: String? = nil
    ) async {
        let generation = UUID()
        openGeneration = generation
        self.hostID = hostID
        self.projectID = projectID
        self.sessionID = sessionID
        self.isHostOnline = isHostOnline
        self.selectedPetID = selectedPetID
        selectedPetAssetGeneration = UUID()
        isLoadingPetAsset = false
        note = nil
        noteConflict = nil
        todos = []
        pets = []
        selectedPetAsset = nil
        discoveredPets = []
        todoDraft = ""

        let draftKey = CoFleetNoteDraftKey(
            hostID: hostID,
            projectID: projectID,
            sessionID: sessionID
        )
        let restoredDraft = noteDraftStorage.draft(for: draftKey)
        activeDraftRecord = restoredDraft
        applyNoteDraft(restoredDraft?.markdown ?? "")

        guard isHostOnline else {
            errorMessage = nil
            return
        }

        do {
            async let note = repository.fetchNote(hostID: hostID, projectID: projectID, sessionID: sessionID)
            async let todos = repository.fetchTodos(hostID: hostID, projectID: projectID)
            async let pets = repository.fetchPets(hostID: hostID)
            let loadedNote = try await note
            guard openGeneration == generation else { return }
            self.note = loadedNote
            reconcile(restoredDraft: restoredDraft, with: loadedNote)
            let loadedTodos = try await todos
            guard openGeneration == generation else { return }
            self.todos = loadedTodos.sorted { $0.sortIndex < $1.sortIndex }
            let loadedPets = try await pets
            guard openGeneration == generation else { return }
            self.pets = loadedPets
            petCatalogByHostID[hostID] = loadedPets
            errorMessage = nil
            await loadSelectedPetAsset()
        } catch {
            guard openGeneration == generation else { return }
            self.isHostOnline = false
            errorMessage = error.localizedDescription
        }
    }

    public func saveNote() async throws {
        guard isHostOnline else {
            throw CoFleetClientError.unavailable("The draft is kept on this device until the host reconnects.")
        }
        guard noteConflict == nil else {
            throw CoFleetClientError.conflict("Reconcile the local draft with the host note before saving.")
        }
        guard var note else {
            throw CoFleetClientError.unavailable("Reconnect to the host before saving this draft.")
        }
        if let activeDraftRecord,
           activeDraftRecord.baseETag != note.eTag || activeDraftRecord.baseRevision != note.revision {
            noteConflict = .conflict(server: note, localMarkdown: noteDraft)
            throw CoFleetClientError.conflict("The host note changed. Choose which version to keep before saving.")
        }
        note.markdown = noteDraft
        let result = try await repository.saveNote(note, expectedETag: note.eTag)
        switch result {
        case let .saved(saved):
            self.note = saved
            clearStoredDraft(applying: saved.markdown)
            noteConflict = nil
        case .conflict:
            noteConflict = result
        }
    }

    public func resolveNoteConflictKeepingDraft() {
        guard case let .conflict(server, localMarkdown) = noteConflict else { return }
        note = server
        noteConflict = nil
        let record = CoFleetNoteDraftRecord(
            key: currentDraftKey ?? CoFleetNoteDraftKey(
                hostID: server.hostID,
                projectID: server.projectID,
                sessionID: server.sessionID
            ),
            markdown: localMarkdown,
            baseRevision: server.revision,
            baseETag: server.eTag
        )
        activeDraftRecord = record
        applyNoteDraft(localMarkdown)
        if !noteDraftStorage.save(record) {
            errorMessage = "This note is too large to keep as a device-local draft."
        }
    }

    public func resolveNoteConflictUsingHost() {
        guard case let .conflict(server, _) = noteConflict else { return }
        note = server
        noteConflict = nil
        clearStoredDraft(applying: server.markdown)
    }

    public func toggleTodo(id: String) async throws {
        guard isHostOnline else {
            throw CoFleetClientError.unavailable("Todos are read-only while the host is offline.")
        }
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        var updated = todos[index]
        updated.isCompleted.toggle()
        todos[index] = try await repository.saveTodo(updated, expectedETag: updated.eTag)
        if let projectID, battleTodosByProjectID[projectID] != nil {
            battleTodosByProjectID[projectID] = todos
        }
    }

    @discardableResult
    public func addTodo() async throws -> CoFleetTodoItem? {
        guard isHostOnline else {
            throw CoFleetClientError.unavailable("Todos are read-only while the host is offline.")
        }
        guard let hostID, let projectID else { return nil }
        let title = todoDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let todo = CoFleetTodoItem(
            hostID: hostID,
            projectID: projectID,
            title: title,
            sortIndex: todos.count
        )
        let saved = try await repository.saveTodo(todo, expectedETag: nil)
        todos.append(saved)
        todos.sort { $0.sortIndex < $1.sortIndex }
        if battleTodosByProjectID[projectID] != nil {
            battleTodosByProjectID[projectID] = todos
        }
        todoDraft = ""
        return saved
    }

    public func deleteTodo(id: String) async throws {
        guard isHostOnline else {
            throw CoFleetClientError.unavailable("Todos are read-only while the host is offline.")
        }
        guard let todo = todos.first(where: { $0.id == id }) else { return }
        try await repository.deleteTodo(hostID: todo.hostID, id: todo.id, expectedETag: todo.eTag)
        todos.removeAll { $0.id == id }
        if let projectID, battleTodosByProjectID[projectID] != nil {
            battleTodosByProjectID[projectID] = todos
        }
    }

    public func refreshPets() async throws {
        guard let hostID else { return }
        pets = try await repository.fetchPets(hostID: hostID)
        petCatalogByHostID[hostID] = pets
        await loadSelectedPetAsset()
    }

    public func discoverPets() async throws {
        guard let hostID else { return }
        discoveredPets = try await repository.discoverPets(hostID: hostID)
    }

    @discardableResult
    public func importPet(sourcePath: String) async throws -> CoFleetPetManifest? {
        guard isHostOnline else {
            throw CoFleetClientError.unavailable("Pets can only be imported while the host is online.")
        }
        guard let hostID else { return nil }
        let path = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let imported = try await repository.importPet(hostID: hostID, sourcePath: path)
        if let index = pets.firstIndex(where: { $0.id == imported.id }) {
            pets[index] = imported
        } else {
            pets.append(imported)
            pets.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }
        petCatalogByHostID[hostID] = pets
        discoveredPets.removeAll { $0.digest == imported.digest }
        return imported
    }

    @discardableResult
    public func selectPet(id petID: String) async throws -> CoFleetProject? {
        guard isHostOnline else {
            throw CoFleetClientError.unavailable("Pet selection requires an online host.")
        }
        guard let hostID, let projectID,
              pets.contains(where: { $0.id == petID }) else { return nil }
        let updated = try await repository.selectPet(
            hostID: hostID,
            projectID: projectID,
            petID: petID
        )
        selectedPetID = petID
        selectedPetAsset = nil
        selectedPetAssetGeneration = UUID()
        await loadSelectedPetAsset()
        return updated
    }

    public func loadSelectedPetAsset() async {
        guard let hostID, let selectedPetID,
              let manifest = pets.first(where: { $0.id == selectedPetID }) else {
            selectedPetAssetGeneration = UUID()
            selectedPetAsset = nil
            return
        }
        if selectedPetAsset?.petID == selectedPetID,
           selectedPetAsset?.hostID == hostID { return }
        let generation = UUID()
        selectedPetAssetGeneration = generation
        isLoadingPetAsset = true
        do {
            let loadedAsset = try await repository.fetchPetAsset(
                hostID: hostID,
                petID: selectedPetID,
                assetName: manifest.spritesheetPath
            )
            guard selectedPetAssetGeneration == generation,
                  self.hostID == hostID,
                  self.selectedPetID == selectedPetID else { return }
            selectedPetAsset = loadedAsset
            isLoadingPetAsset = false
        } catch {
            guard selectedPetAssetGeneration == generation,
                  self.hostID == hostID,
                  self.selectedPetID == selectedPetID else { return }
            selectedPetAsset = nil
            errorMessage = error.localizedDescription
            isLoadingPetAsset = false
        }
    }

    /// Load only explicitly selected pet packages for visible project cards. Assets are
    /// retained by project identity, so routine session refreshes do not refetch them.
    public func loadBattlePets(for projects: [CoFleetProject]) async {
        let generation = UUID()
        battlePetGeneration = generation
        let visibleCandidates = Array(projects.filter { $0.selectedPetID != nil }.prefix(12))
        let candidates = visibleCandidates.filter { project in
            guard let petID = project.selectedPetID else { return false }
            return battlePetManifestsByProjectID[project.id]?.id != petID
                || battlePetAssetsByProjectID[project.id]?.petID != petID
        }
        let candidateIDs = Set(visibleCandidates.map(\.id))
        battlePetManifestsByProjectID = battlePetManifestsByProjectID.filter {
            candidateIDs.contains($0.key)
        }
        battlePetAssetsByProjectID = battlePetAssetsByProjectID.filter {
            candidateIDs.contains($0.key)
        }

        let repository = self.repository
        var catalogs = petCatalogByHostID
        let uncachedHostIDs = Set(candidates.map(\.hostID)).filter { catalogs[$0] == nil }
        await withTaskGroup(of: HostPetCatalogLoadResult.self) { group in
            for hostID in uncachedHostIDs {
                group.addTask {
                    do {
                        return .loaded(
                            hostID: hostID,
                            manifests: try await repository.fetchPets(hostID: hostID)
                        )
                    } catch {
                        return .failed(hostID: hostID)
                    }
                }
            }
            for await result in group {
                guard battlePetGeneration == generation else { return }
                switch result {
                case let .loaded(hostID, manifests):
                    catalogs[hostID] = manifests
                    petCatalogByHostID[hostID] = manifests
                case let .failed(hostID):
                    catalogs[hostID] = []
                }
            }
        }
        guard battlePetGeneration == generation else { return }
        var resolvedProjectPets: [(projectID: String, manifest: CoFleetPetManifest)] = []
        for project in candidates {
            guard let petID = project.selectedPetID,
                  let manifest = catalogs[project.hostID]?.first(where: { $0.id == petID }) else {
                battlePetManifestsByProjectID[project.id] = nil
                battlePetAssetsByProjectID[project.id] = nil
                continue
            }
            resolvedProjectPets.append((project.id, manifest))
        }

        let assetKeys = Set(resolvedProjectPets.map { PetAssetLoadKey(manifest: $0.manifest) })
        var assetsByKey: [PetAssetLoadKey: CoFleetPetAsset] = [:]
        await withTaskGroup(of: PetAssetLoadResult.self) { group in
            for key in assetKeys {
                group.addTask {
                    do {
                        return .loaded(
                            key: key,
                            asset: try await repository.fetchPetAsset(
                                hostID: key.hostID,
                                petID: key.petID,
                                assetName: key.assetName
                            )
                        )
                    } catch {
                        return .failed(key: key)
                    }
                }
            }

            for await result in group {
                guard battlePetGeneration == generation else { return }
                if case let .loaded(key, asset) = result {
                    assetsByKey[key] = asset
                }
            }
        }
        guard battlePetGeneration == generation else { return }
        for resolved in resolvedProjectPets {
            let key = PetAssetLoadKey(manifest: resolved.manifest)
            battlePetManifestsByProjectID[resolved.projectID] = resolved.manifest
            battlePetAssetsByProjectID[resolved.projectID] = assetsByKey[key]
        }
    }

    /// Refreshes Battle objectives only when the Battle destination is opened or its
    /// visible project set changes. Keeping this separate from the Progress refresh
    /// loop avoids turning workspace records into a polling workload.
    public func loadBattleTodos(for projects: [CoFleetProject]) async {
        let generation = UUID()
        battleTodoGeneration = generation
        let candidates = Array(projects.prefix(12))
        let candidateIDs = Set(candidates.map(\.id))
        battleTodosByProjectID = battleTodosByProjectID.filter { candidateIDs.contains($0.key) }
        battleTodoLoadingProjectIDs = candidateIDs

        let repository = self.repository
        await withTaskGroup(of: BattleTodoLoadResult.self) { group in
            for project in candidates {
                group.addTask {
                    do {
                        let todos = try await repository.fetchTodos(
                            hostID: project.hostID,
                            projectID: project.id
                        )
                        return .loaded(projectID: project.id, todos: todos)
                    } catch {
                        return .failed(projectID: project.id)
                    }
                }
            }

            for await result in group {
                guard battleTodoGeneration == generation else { return }
                switch result {
                case let .loaded(projectID, todos):
                    battleTodosByProjectID[projectID] = todos.sorted {
                        $0.sortIndex == $1.sortIndex
                            ? $0.updatedAt < $1.updatedAt
                            : $0.sortIndex < $1.sortIndex
                    }
                case let .failed(projectID):
                    // Preserve a previously loaded objective list through a transient
                    // reconnect instead of replacing it with demo data.
                    if battleTodosByProjectID[projectID] == nil {
                        battleTodosByProjectID[projectID] = []
                    }
                }
                battleTodoLoadingProjectIDs.remove(result.projectID)
            }
        }
        guard battleTodoGeneration == generation else { return }
        battleTodoLoadingProjectIDs.removeAll()
    }

    /// Resolves a Battle checklist action against the same host-authoritative todo
    /// record used by the workspace editor, then reconciles both in-memory views.
    public func toggleBattleTodo(projectID: String, todoID: String) async {
        guard var projectTodos = battleTodosByProjectID[projectID],
              let index = projectTodos.firstIndex(where: { $0.id == todoID }) else { return }
        var updated = projectTodos[index]
        updated.isCompleted.toggle()

        do {
            let saved = try await repository.saveTodo(updated, expectedETag: updated.eTag)
            projectTodos[index] = saved
            battleTodosByProjectID[projectID] = projectTodos
            if self.projectID == projectID,
               let workspaceIndex = todos.firstIndex(where: { $0.id == todoID }) {
                todos[workspaceIndex] = saved
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var currentDraftKey: CoFleetNoteDraftKey? {
        guard let hostID, let projectID else { return nil }
        return CoFleetNoteDraftKey(hostID: hostID, projectID: projectID, sessionID: sessionID)
    }

    private func reconcile(restoredDraft: CoFleetNoteDraftRecord?, with hostNote: CoFleetNote) {
        guard let restoredDraft else {
            activeDraftRecord = nil
            applyNoteDraft(hostNote.markdown)
            return
        }

        if restoredDraft.markdown == hostNote.markdown {
            clearStoredDraft(applying: hostNote.markdown)
        } else if restoredDraft.baseRevision == hostNote.revision,
                  restoredDraft.baseETag == hostNote.eTag {
            activeDraftRecord = restoredDraft
            applyNoteDraft(restoredDraft.markdown)
        } else {
            activeDraftRecord = restoredDraft
            applyNoteDraft(restoredDraft.markdown)
            noteConflict = .conflict(server: hostNote, localMarkdown: restoredDraft.markdown)
        }
    }

    private func persistCurrentNoteDraft() {
        guard !isApplyingNoteDraft, let key = currentDraftKey else { return }
        if noteDraft == note?.markdown, noteConflict == nil {
            noteDraftStorage.removeDraft(for: key)
            activeDraftRecord = nil
            return
        }

        let record = CoFleetNoteDraftRecord(
            key: key,
            markdown: noteDraft,
            baseRevision: activeDraftRecord?.key == key ? activeDraftRecord?.baseRevision : note?.revision,
            baseETag: activeDraftRecord?.key == key ? activeDraftRecord?.baseETag : note?.eTag
        )
        activeDraftRecord = record
        if !noteDraftStorage.save(record) {
            errorMessage = "This note is too large to keep as a device-local draft."
        }
    }

    private func applyNoteDraft(_ markdown: String) {
        isApplyingNoteDraft = true
        noteDraft = markdown
        isApplyingNoteDraft = false
    }

    private func clearStoredDraft(applying markdown: String) {
        if let key = currentDraftKey {
            noteDraftStorage.removeDraft(for: key)
        }
        activeDraftRecord = nil
        applyNoteDraft(markdown)
    }
}

private enum HostPetCatalogLoadResult: Sendable {
    case loaded(hostID: CoFleetHostID, manifests: [CoFleetPetManifest])
    case failed(hostID: CoFleetHostID)
}

private struct PetAssetLoadKey: Hashable, Sendable {
    var hostID: CoFleetHostID
    var petID: String
    var assetName: String
    var digest: String

    init(manifest: CoFleetPetManifest) {
        hostID = manifest.hostID
        petID = manifest.id
        assetName = manifest.spritesheetPath
        digest = manifest.digest
    }
}

private enum PetAssetLoadResult: Sendable {
    case loaded(key: PetAssetLoadKey, asset: CoFleetPetAsset)
    case failed(key: PetAssetLoadKey)
}

private enum BattleTodoLoadResult: Sendable {
    case loaded(projectID: String, todos: [CoFleetTodoItem])
    case failed(projectID: String)

    var projectID: String {
        switch self {
        case let .loaded(projectID, _), let .failed(projectID): projectID
        }
    }
}
