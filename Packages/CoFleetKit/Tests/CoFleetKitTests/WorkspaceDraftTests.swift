import CoFleetCore
import Foundation
import XCTest

final class WorkspaceDraftTests: XCTestCase {
    private let hostID = CoFleetHostID(rawValue: "host-example")

    @MainActor
    func testOfflineOpenRestoresDraftWithoutCallingHostAndKeepsTodosReadOnly() async throws {
        let key = CoFleetNoteDraftKey(hostID: hostID, projectID: "project-one", sessionID: "thread-one")
        let storage = MemoryNoteDraftStorage()
        _ = storage.save(CoFleetNoteDraftRecord(
            key: key,
            markdown: "# Recovered draft",
            baseRevision: 3,
            baseETag: "\"note-example-3\""
        ))
        let repository = WorkspaceRepositoryFake(note: note(revision: 3))
        let store = WorkspaceStore(repository: repository, noteDraftStorage: storage)

        await store.open(
            hostID: hostID,
            projectID: "project-one",
            sessionID: "thread-one",
            isHostOnline: false
        )

        XCTAssertEqual(store.noteDraft, "# Recovered draft")
        XCTAssertTrue(store.hasUnsavedNoteDraft)
        XCTAssertFalse(store.canMutateTodos)
        let noteFetchCount = await repository.fetchNoteCount()
        XCTAssertEqual(noteFetchCount, 0)

        do {
            _ = try await store.addTodo()
            XCTFail("Offline todo mutation should fail")
        } catch let error as CoFleetClientError {
            guard case .unavailable = error else {
                return XCTFail("Expected an unavailable error, got \(error)")
            }
        }
        let todoMutationCount = await repository.todoMutationCount()
        XCTAssertEqual(todoMutationCount, 0)
    }

    @MainActor
    func testBattleTodosLoadPerProjectAndToggleTheHostRecord() async {
        let todo = CoFleetTodoItem(
            id: "todo-battle",
            hostID: hostID,
            projectID: "project-one",
            title: "Restore the battle objective panel",
            sortIndex: 0,
            revision: 2
        )
        let repository = WorkspaceRepositoryFake(note: note(revision: 0), todos: [todo])
        let store = WorkspaceStore(repository: repository, noteDraftStorage: MemoryNoteDraftStorage())
        let project = CoFleetProject(
            id: "project-one",
            hostID: hostID,
            displayName: "Example Project",
            canonicalPath: "/Users/example/ExampleProject"
        )

        await store.loadBattleTodos(for: [project])
        XCTAssertEqual(store.battleTodosByProjectID[project.id], [todo])

        await store.toggleBattleTodo(projectID: project.id, todoID: todo.id)

        let saved = store.battleTodosByProjectID[project.id]?.first
        XCTAssertEqual(saved?.isCompleted, true)
        XCTAssertEqual(saved?.revision, 3)
        let todoMutationCount = await repository.todoMutationCount()
        XCTAssertEqual(todoMutationCount, 1)
    }

    @MainActor
    func testDraftWithMatchingBaseCanSaveAndIsCleared() async throws {
        let hostNote = note(revision: 3, markdown: "Host text")
        let key = CoFleetNoteDraftKey(hostID: hostID, projectID: "project-one", sessionID: nil)
        let storage = MemoryNoteDraftStorage()
        _ = storage.save(CoFleetNoteDraftRecord(
            key: key,
            markdown: "Local edit",
            baseRevision: hostNote.revision,
            baseETag: hostNote.eTag
        ))
        let repository = WorkspaceRepositoryFake(note: hostNote)
        let store = WorkspaceStore(repository: repository, noteDraftStorage: storage)

        await store.open(hostID: hostID, projectID: "project-one")

        XCTAssertEqual(store.noteDraft, "Local edit")
        XCTAssertNil(store.noteConflict)
        try await store.saveNote()
        XCTAssertEqual(store.note?.markdown, "Local edit")
        let savedETags = await repository.savedETags()
        XCTAssertEqual(savedETags, [hostNote.eTag])
        XCTAssertNil(storage.draft(for: key))
        XCTAssertFalse(store.hasUnsavedNoteDraft)
    }

    @MainActor
    func testEditingPersistsImmediatelyWithTheCurrentHostBase() async {
        let hostNote = note(revision: 7, markdown: "Host text")
        let key = CoFleetNoteDraftKey(hostID: hostID, projectID: "project-one", sessionID: "thread-one")
        let storage = MemoryNoteDraftStorage()
        let store = WorkspaceStore(
            repository: WorkspaceRepositoryFake(note: hostNote),
            noteDraftStorage: storage
        )

        await store.open(hostID: hostID, projectID: "project-one", sessionID: "thread-one")
        store.noteDraft = "A durable local edit"

        XCTAssertEqual(storage.draft(for: key)?.markdown, "A durable local edit")
        XCTAssertEqual(storage.draft(for: key)?.baseRevision, hostNote.revision)
        XCTAssertEqual(storage.draft(for: key)?.baseETag, hostNote.eTag)
    }

    @MainActor
    func testAdvancedHostRevisionRequiresExplicitKeepLocalBeforeOverwrite() async throws {
        let oldNote = note(revision: 4, markdown: "Earlier host text")
        let currentHostNote = note(revision: 5, markdown: "New host text")
        let key = CoFleetNoteDraftKey(hostID: hostID, projectID: "project-one", sessionID: "thread-one")
        let storage = MemoryNoteDraftStorage()
        _ = storage.save(CoFleetNoteDraftRecord(
            key: key,
            markdown: "Offline local edit",
            baseRevision: oldNote.revision,
            baseETag: oldNote.eTag
        ))
        let repository = WorkspaceRepositoryFake(note: currentHostNote)
        let store = WorkspaceStore(repository: repository, noteDraftStorage: storage)

        await store.open(hostID: hostID, projectID: "project-one", sessionID: "thread-one")

        guard case let .conflict(server, localMarkdown) = store.noteConflict else {
            return XCTFail("A newer host revision must require reconciliation")
        }
        XCTAssertEqual(server.revision, currentHostNote.revision)
        XCTAssertEqual(server.markdown, currentHostNote.markdown)
        XCTAssertEqual(localMarkdown, "Offline local edit")
        XCTAssertEqual(store.noteDraft, "Offline local edit")

        do {
            try await store.saveNote()
            XCTFail("Saving before reconciliation should fail")
        } catch let error as CoFleetClientError {
            guard case .conflict = error else {
                return XCTFail("Expected a conflict error, got \(error)")
            }
        }
        let savedBeforeResolution = await repository.savedETags()
        XCTAssertEqual(savedBeforeResolution, [])

        store.resolveNoteConflictKeepingDraft()
        XCTAssertNil(store.noteConflict)
        XCTAssertEqual(storage.draft(for: key)?.baseRevision, currentHostNote.revision)
        XCTAssertEqual(storage.draft(for: key)?.baseETag, currentHostNote.eTag)

        try await store.saveNote()
        let savedAfterResolution = await repository.savedETags()
        XCTAssertEqual(savedAfterResolution, [currentHostNote.eTag])
        XCTAssertNil(storage.draft(for: key))
    }

    @MainActor
    func testUsingHostVersionClearsRecoveredDraft() async {
        let oldNote = note(revision: 1, markdown: "Old")
        let currentHostNote = note(revision: 2, markdown: "Current host")
        let key = CoFleetNoteDraftKey(hostID: hostID, projectID: "project-one", sessionID: nil)
        let storage = MemoryNoteDraftStorage()
        _ = storage.save(CoFleetNoteDraftRecord(
            key: key,
            markdown: "Local",
            baseRevision: oldNote.revision,
            baseETag: oldNote.eTag
        ))
        let store = WorkspaceStore(
            repository: WorkspaceRepositoryFake(note: currentHostNote),
            noteDraftStorage: storage
        )

        await store.open(hostID: hostID, projectID: "project-one")
        XCTAssertNotNil(store.noteConflict)
        store.resolveNoteConflictUsingHost()

        XCTAssertNil(store.noteConflict)
        XCTAssertEqual(store.noteDraft, "Current host")
        XCTAssertNil(storage.draft(for: key))
        XCTAssertFalse(store.hasUnsavedNoteDraft)
    }

    @MainActor
    func testDraftIdentityIncludesHostProjectAndSession() {
        let storage = MemoryNoteDraftStorage()
        let projectKey = CoFleetNoteDraftKey(hostID: hostID, projectID: "project-one", sessionID: nil)
        let sessionKey = CoFleetNoteDraftKey(hostID: hostID, projectID: "project-one", sessionID: "thread-one")
        let otherHostKey = CoFleetNoteDraftKey(
            hostID: CoFleetHostID(rawValue: "other-host"),
            projectID: "project-one",
            sessionID: "thread-one"
        )
        _ = storage.save(.init(key: projectKey, markdown: "Project", baseRevision: 1, baseETag: "one"))
        _ = storage.save(.init(key: sessionKey, markdown: "Session", baseRevision: 2, baseETag: "two"))
        _ = storage.save(.init(key: otherHostKey, markdown: "Other", baseRevision: 3, baseETag: "three"))

        XCTAssertEqual(storage.draft(for: projectKey)?.markdown, "Project")
        XCTAssertEqual(storage.draft(for: sessionKey)?.markdown, "Session")
        XCTAssertEqual(storage.draft(for: otherHostKey)?.markdown, "Other")
    }

    @MainActor
    func testUserDefaultsStorageIsBoundedAndRejectsOversizedDrafts() {
        let suiteName = "org.cofleet.tests.note-drafts.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = CoFleetUserDefaultsNoteDraftStorage(
            defaults: defaults,
            namespace: "test.note-drafts",
            maximumEntries: 2,
            maximumDraftBytes: 8,
            maximumTotalDraftBytes: 12
        )
        let oldest = CoFleetNoteDraftKey(hostID: hostID, projectID: "oldest", sessionID: nil)
        let middle = CoFleetNoteDraftKey(hostID: hostID, projectID: "middle", sessionID: nil)
        let newest = CoFleetNoteDraftKey(hostID: hostID, projectID: "newest", sessionID: nil)
        XCTAssertTrue(storage.save(.init(
            key: oldest,
            markdown: "1111",
            baseRevision: 1,
            baseETag: "one",
            updatedAt: Date(timeIntervalSince1970: 1)
        )))
        XCTAssertTrue(storage.save(.init(
            key: middle,
            markdown: "2222",
            baseRevision: 1,
            baseETag: "two",
            updatedAt: Date(timeIntervalSince1970: 2)
        )))
        XCTAssertTrue(storage.save(.init(
            key: newest,
            markdown: "3333",
            baseRevision: 1,
            baseETag: "three",
            updatedAt: Date(timeIntervalSince1970: 3)
        )))

        XCTAssertNil(storage.draft(for: oldest))
        XCTAssertEqual(storage.draft(for: middle)?.markdown, "2222")
        XCTAssertEqual(storage.draft(for: newest)?.markdown, "3333")
        XCTAssertFalse(storage.save(.init(
            key: newest,
            markdown: "123456789",
            baseRevision: 1,
            baseETag: "three"
        )))
        let oversizedEnvelopeKey = CoFleetNoteDraftKey(
            hostID: hostID,
            projectID: String(repeating: "p", count: 10_000),
            sessionID: nil
        )
        XCTAssertFalse(storage.save(.init(
            key: oversizedEnvelopeKey,
            markdown: "tiny",
            baseRevision: 1,
            baseETag: "four"
        )))
        XCTAssertEqual(storage.draft(for: newest)?.markdown, "3333")
    }

    private func note(revision: Int, markdown: String = "Host text") -> CoFleetNote {
        CoFleetNote(
            id: "note-example",
            hostID: hostID,
            projectID: "project-one",
            sessionID: nil,
            markdown: markdown,
            revision: revision,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(revision))
        )
    }
}

@MainActor
private final class MemoryNoteDraftStorage: CoFleetNoteDraftStorage {
    private var values: [CoFleetNoteDraftKey: CoFleetNoteDraftRecord] = [:]

    func draft(for key: CoFleetNoteDraftKey) -> CoFleetNoteDraftRecord? { values[key] }

    @discardableResult
    func save(_ draft: CoFleetNoteDraftRecord) -> Bool {
        values[draft.key] = draft
        return true
    }

    func removeDraft(for key: CoFleetNoteDraftKey) {
        values.removeValue(forKey: key)
    }
}

private actor WorkspaceRepositoryFake: CoFleetWorkspaceRepository {
    private var hostNote: CoFleetNote
    private var hostTodos: [CoFleetTodoItem]
    private var noteFetches = 0
    private var noteSaveETags: [String] = []
    private var todoMutations = 0

    init(note: CoFleetNote, todos: [CoFleetTodoItem] = []) {
        hostNote = note
        hostTodos = todos
    }

    func fetchNote(hostID: CoFleetHostID, projectID: String, sessionID: String?) async throws -> CoFleetNote {
        noteFetches += 1
        var result = hostNote
        result.hostID = hostID
        result.projectID = projectID
        result.sessionID = sessionID
        return result
    }

    func saveNote(_ note: CoFleetNote, expectedETag: String) async throws -> CoFleetNoteSaveResult {
        noteSaveETags.append(expectedETag)
        var saved = note
        saved.revision += 1
        saved.updatedAt = .now
        hostNote = saved
        return .saved(saved)
    }

    func fetchTodos(hostID: CoFleetHostID, projectID: String) async throws -> [CoFleetTodoItem] {
        hostTodos.filter { $0.hostID == hostID && $0.projectID == projectID }
    }

    func saveTodo(_ todo: CoFleetTodoItem, expectedETag: String?) async throws -> CoFleetTodoItem {
        todoMutations += 1
        var saved = todo
        saved.revision += 1
        saved.updatedAt = .now
        if let index = hostTodos.firstIndex(where: { $0.id == saved.id }) {
            hostTodos[index] = saved
        } else {
            hostTodos.append(saved)
        }
        return saved
    }

    func deleteTodo(hostID: CoFleetHostID, id: String, expectedETag: String) async throws {
        todoMutations += 1
    }

    func fetchPets(hostID: CoFleetHostID) async throws -> [CoFleetPetManifest] { [] }
    func discoverPets(hostID: CoFleetHostID) async throws -> [CoFleetDiscoveredPet] { [] }

    func importPet(hostID: CoFleetHostID, sourcePath: String) async throws -> CoFleetPetManifest {
        throw CoFleetClientError.unavailable("Not used in this test.")
    }

    func selectPet(hostID: CoFleetHostID, projectID: String, petID: String) async throws -> CoFleetProject {
        throw CoFleetClientError.unavailable("Not used in this test.")
    }

    func fetchPetAsset(
        hostID: CoFleetHostID,
        petID: String,
        assetName: String
    ) async throws -> CoFleetPetAsset {
        throw CoFleetClientError.unavailable("Not used in this test.")
    }

    func fetchNoteCount() -> Int { noteFetches }
    func savedETags() -> [String] { noteSaveETags }
    func todoMutationCount() -> Int { todoMutations }
}
