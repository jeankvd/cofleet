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
    }

    public func refreshPets() async throws {
        guard let hostID else { return }
        pets = try await repository.fetchPets(hostID: hostID)
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
        await loadSelectedPetAsset()
        return updated
    }

    public func loadSelectedPetAsset() async {
        guard let hostID, let selectedPetID,
              let manifest = pets.first(where: { $0.id == selectedPetID }) else {
            selectedPetAsset = nil
            return
        }
        if selectedPetAsset?.petID == selectedPetID,
           selectedPetAsset?.hostID == hostID { return }
        isLoadingPetAsset = true
        defer { isLoadingPetAsset = false }
        do {
            selectedPetAsset = try await repository.fetchPetAsset(
                hostID: hostID,
                petID: selectedPetID,
                assetName: manifest.spritesheetPath
            )
        } catch {
            selectedPetAsset = nil
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
