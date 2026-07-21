import CoFleetCore
import SwiftUI

#if !os(watchOS)

public struct CoFleetSessionPicker: View {
    @Bindable private var store: ThreadStore
    @Environment(\.dismiss) private var dismiss
    @State private var renameSession: CoFleetSessionSummary?
    @State private var renameTitle = ""
    @State private var showsRename = false
    @State private var archiveSession: CoFleetSessionSummary?
    @State private var showsArchiveConfirmation = false
    @State private var actionError: String?

    public init(store: ThreadStore) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    catalogStatus

                    if store.isLoading && store.sessions.isEmpty {
                        ProgressView("Loading sessions…")
                            .frame(maxWidth: .infinity)
                            .padding(24)
                    }

                    if let error = store.errorMessage {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(CoFleetTheme.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Retry") { Task { await reload() } }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        .padding(12)
                        .background(CoFleetTheme.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }

                    if store.sessions.isEmpty && !store.isLoading && store.errorMessage == nil {
                        ContentUnavailableView(
                            store.showsArchived ? "No archived tasks" : "No sessions yet",
                            systemImage: "clock.arrow.circlepath",
                            description: Text(
                                store.showsArchived
                                    ? "Archived Codex tasks for this project will appear here."
                                    : "Start a chat and Codex will create its canonical task."
                            )
                        )
                        .padding(.vertical, 28)
                    }

                    ForEach(store.sessions) { session in
                        sessionRow(session)
                    }

                    if store.canLoadMore {
                        Button {
                            Task { await store.loadMore() }
                        } label: {
                            Label("Load 5 more", systemImage: "arrow.down.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.isLoading)
                        .accessibilityIdentifier("cofleet.sessions.load-more")
                    }
                }
                .padding(14)
            }
            .background(CoFleetTheme.background)
            .navigationTitle("Codex Sessions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await createSession() }
                    } label: {
                        Label("New session", systemImage: "plus")
                    }
                    .disabled(store.isLoading)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Toggle(
                        "Archived",
                        isOn: Binding(
                            get: { store.showsArchived },
                            set: { value in Task { await store.setShowsArchived(value) } }
                        )
                    )
                }
            }
        }
        .frame(minWidth: 360, minHeight: 380)
        .preferredColorScheme(.dark)
        .task { await reload() }
        .alert("Rename session", isPresented: $showsRename) {
            TextField("Session name", text: $renameTitle)
            Button("Cancel", role: .cancel) { renameSession = nil }
            Button("Rename") { renameSelectedSession() }
                .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("This updates the canonical Codex task name.")
        }
        .confirmationDialog(
            "Archive this session?",
            isPresented: $showsArchiveConfirmation,
            titleVisibility: .visible
        ) {
            if let archiveSession {
                Button("Archive", role: .destructive) {
                    Task { await archive(archiveSession) }
                }
            }
            Button("Cancel", role: .cancel) { archiveSession = nil }
        } message: {
            if let archiveSession {
                Text("\(archiveSession.title) will move to Archived and can be restored later.")
            }
        }
        .alert("Couldn’t Update Task", isPresented: actionErrorIsPresented) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "The task could not be updated.")
        }
    }

    private var catalogStatus: some View {
        HStack(spacing: 8) {
            Label(
                store.showsArchived ? "Archived Codex history" : "Live Codex history",
                systemImage: store.showsArchived ? "archivebox" : "checkmark.icloud"
            )
            .foregroundStyle(.secondary)
            Spacer()
            if store.isLoading && !store.sessions.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionRow(_ session: CoFleetSessionSummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                select(session)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: session.state == .archived
                        ? "archivebox"
                        : (session.id == store.selectedSessionID
                            ? "checkmark.circle.fill"
                            : "bubble.left.and.text.bubble.right"))
                        .font(.title3)
                        .foregroundStyle(isLatest(session) ? CoFleetTheme.cyan : Color.secondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Text(session.title)
                                .font(.headline)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            if isLatest(session) && !store.showsArchived {
                                Text("LATEST")
                                    .font(.caption2.monospaced().bold())
                                    .foregroundStyle(CoFleetTheme.cyan)
                            }
                        }

                        Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let preview = session.preview, !preview.isEmpty {
                            Text(preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        HStack(spacing: 10) {
                            Label("Codex", systemImage: "link")
                            if let modelID = session.modelID, !modelID.isEmpty {
                                Label(modelID, systemImage: "cpu")
                            }
                            if let effort = session.reasoningEffort, !effort.isEmpty {
                                Label(runtimeValue(effort), systemImage: "brain")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            sessionActions(session)
        }
        .padding(13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17))
        .overlay {
            RoundedRectangle(cornerRadius: 17)
                .stroke(
                    session.id == store.selectedSessionID
                        ? CoFleetTheme.cyan.opacity(0.65)
                        : Color.white.opacity(0.08)
                )
        }
        .accessibilityLabel("\(isLatest(session) ? "Latest session" : "Past session"), \(session.title)")
        .accessibilityValue(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
        .accessibilityIdentifier("cofleet.session.\(session.id)")
    }

    private func sessionActions(_ session: CoFleetSessionSummary) -> some View {
        Menu {
            if store.showsArchived || session.state == .archived {
                Button("Restore", systemImage: "arrow.uturn.backward") {
                    Task { await restore(session) }
                }
            } else {
                Button("Fork", systemImage: "arrow.triangle.branch") {
                    Task { await fork(session) }
                }
                Button("Rename", systemImage: "pencil") {
                    store.selectedSessionID = session.id
                    renameSession = session
                    renameTitle = session.title
                    showsRename = true
                }
                Divider()
                Button("Archive", systemImage: "archivebox", role: .destructive) {
                    store.selectedSessionID = session.id
                    archiveSession = session
                    showsArchiveConfirmation = true
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Session actions for \(session.title)")
    }

    private func isLatest(_ session: CoFleetSessionSummary) -> Bool {
        session.id == store.sessions.max(by: { $0.updatedAt < $1.updatedAt })?.id
    }

    private func runtimeValue(_ rawValue: String) -> String {
        rawValue.lowercased() == "xhigh"
            ? "XHigh"
            : rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func select(_ session: CoFleetSessionSummary) {
        store.selectedSessionID = session.id
        dismiss()
    }

    private func createSession() async {
        do {
            _ = try await store.createSession()
            dismiss()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func renameSelectedSession() {
        guard let renameSession else { return }
        let title = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        store.selectedSessionID = renameSession.id
        self.renameSession = nil
        Task {
            do {
                try await store.renameSelected(title)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func fork(_ session: CoFleetSessionSummary) async {
        store.selectedSessionID = session.id
        do {
            _ = try await store.forkSelected(settings: session.settings)
            dismiss()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func archive(_ session: CoFleetSessionSummary) async {
        archiveSession = nil
        store.selectedSessionID = session.id
        do {
            try await store.archiveSelected()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func restore(_ session: CoFleetSessionSummary) async {
        store.selectedSessionID = session.id
        do {
            try await store.unarchiveSelected()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private var actionErrorIsPresented: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { presented in
                if !presented { actionError = nil }
            }
        )
    }

    private func reload() async {
        guard let hostID = store.loadedHostID,
              let projectID = store.loadedProjectID else { return }
        await store.loadInitial(hostID: hostID, projectID: projectID)
    }
}
#endif
