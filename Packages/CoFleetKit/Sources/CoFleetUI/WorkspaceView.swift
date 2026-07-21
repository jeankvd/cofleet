import CoFleetCore
import SwiftUI

#if !os(watchOS)

/// The project-owned workspace that feeds Battle's objectives. Notes remain
/// portable Markdown while todos are structured, host-authoritative records.
public struct CoFleetWorkspaceView: View {
    @Bindable private var workspaceStore: WorkspaceStore
    private let projectName: String

    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .todos
    @State private var isSaving = false
    @State private var errorMessage: String?

    public init(workspaceStore: WorkspaceStore, projectName: String) {
        self.workspaceStore = workspaceStore
        self.projectName = projectName
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Workspace section", selection: $section) {
                    ForEach(Section.allCases) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                switch section {
                case .notes:
                    notes
                case .todos:
                    todos
                }
            }
            .padding(.top, 8)
            .navigationTitle(projectName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Couldn’t update workspace", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 560, idealWidth: 680, minHeight: 520, idealHeight: 680)
        #endif
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Project notes")
                        .font(.headline)
                    Text(workspaceStore.isHostOnline
                         ? "Saved to this project’s CoFleet host as portable Markdown."
                         : "Offline edits stay as a draft on this device until the host reconnects.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button {
                    perform { try await workspaceStore.saveNote() }
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isSaving
                    || !workspaceStore.isHostOnline
                    || workspaceStore.note == nil
                    || !workspaceStore.hasUnsavedNoteDraft
                    || workspaceStore.noteConflict != nil
                )
                .accessibilityIdentifier("cofleet-note-save")
            }

            if workspaceStore.noteConflict != nil {
                noteConflictBanner
            }

            CoFleetRichNoteEditor(markdown: $workspaceStore.noteDraft)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal)
        .padding(.bottom)
    }

    private var noteConflictBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This note changed on the host.", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Keep your draft and save it over the newer revision after reviewing, or use the host version.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Keep my draft") {
                    workspaceStore.resolveNoteConflictKeepingDraft()
                }
                Button("Use host version", role: .destructive) {
                    workspaceStore.resolveNoteConflictUsingHost()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private var todos: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("Add an objective…", text: $workspaceStore.todoDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTodo)
                    .accessibilityIdentifier("cofleet-todo-field")
                Button(action: addTodo) {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !workspaceStore.canMutateTodos
                    || workspaceStore.todoDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || isSaving
                )
                .accessibilityIdentifier("cofleet-todo-add")
            }
            .padding(.horizontal)

            if workspaceStore.todos.isEmpty {
                ContentUnavailableView(
                    "No objectives yet",
                    systemImage: "checklist",
                    description: Text("Add a todo here. It becomes an objective in Battle, and completing it there triggers an attack.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(workspaceStore.todos) { todo in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Button {
                                perform { try await workspaceStore.toggleTodo(id: todo.id) }
                            } label: {
                                Image(systemName: todo.isCompleted ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(todo.isCompleted ? Color.green : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(!workspaceStore.canMutateTodos || isSaving)
                            .accessibilityLabel(todo.isCompleted ? "Mark incomplete" : "Mark complete")

                            Text(todo.title)
                                .strikethrough(todo.isCompleted)
                                .foregroundStyle(todo.isCompleted ? .secondary : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button(role: .destructive) {
                                perform { try await workspaceStore.deleteTodo(id: todo.id) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!workspaceStore.canMutateTodos || isSaving)
                            .accessibilityLabel("Delete \(todo.title)")
                        }
                        .accessibilityIdentifier("cofleet-todo-\(todo.id)")
                    }
                }
                .listStyle(.plain)
            }

            Text("These same objectives appear in Battle and on Apple Watch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
    }

    private func addTodo() {
        perform { _ = try await workspaceStore.addTodo() }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private enum Section: String, CaseIterable, Identifiable {
        case todos
        case notes

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String { self == .todos ? "checklist" : "note.text" }
    }
}

#endif
