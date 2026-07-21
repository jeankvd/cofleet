import CoFleetCore
import SwiftUI

#if !os(watchOS)

public struct CoFleetSessionPicker: View {
    @Bindable private var store: ThreadStore
    @Environment(\.dismiss) private var dismiss
    @State private var renameTitle = ""
    @State private var showsRename = false

    public init(store: ThreadStore) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(store.sessions) { session in
                    Button {
                        store.selectedSessionID = session.id
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(session.title).font(.headline)
                                Spacer()
                                if session.id == store.selectedSessionID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(CoFleetTheme.cyan)
                                }
                            }
                            if let preview = session.preview, !preview.isEmpty {
                                Text(preview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Text(session.updatedAt, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            store.selectedSessionID = session.id
                            renameTitle = session.title
                            showsRename = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        if !store.showsArchived {
                            Button {
                                store.selectedSessionID = session.id
                                Task { _ = try? await store.forkSelected(settings: session.settings) }
                            } label: {
                                Label("Fork", systemImage: "arrow.triangle.branch")
                            }
                            Button(role: .destructive) {
                                store.selectedSessionID = session.id
                                Task { try? await store.archiveSelected() }
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                        } else {
                            Button {
                                store.selectedSessionID = session.id
                                Task { try? await store.unarchiveSelected() }
                            } label: {
                                Label("Unarchive", systemImage: "arrow.uturn.backward")
                            }
                        }
                    }
                }

                if store.canLoadMore {
                    Button("Load 5 more") {
                        Task { await store.loadMore() }
                    }
                    .disabled(store.isLoading)
                    .frame(maxWidth: .infinity)
                }
            }
            .overlay {
                if store.isLoading && store.sessions.isEmpty { ProgressView() }
            }
            .navigationTitle("Session History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            _ = try? await store.createSession()
                            dismiss()
                        }
                    } label: {
                        Label("New session", systemImage: "plus")
                    }
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
        .alert("Rename Session", isPresented: $showsRename) {
            TextField("Session title", text: $renameTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let title = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                Task { try? await store.renameSelected(title) }
            }
        }
    }
}
#endif
