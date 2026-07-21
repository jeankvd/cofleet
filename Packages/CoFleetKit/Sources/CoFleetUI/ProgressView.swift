import CoFleetCodex
import CoFleetCore
import SwiftUI

#if !os(watchOS)

public struct CoFleetProgressView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable private var fleetStore: FleetStore
    @Bindable private var threadStore: ThreadStore
    @Bindable private var turnStore: TurnStore
    @Bindable private var workspaceStore: WorkspaceStore
    @Binding private var settings: CoFleetSessionSettings
    private let localHostID: CoFleetHostID?

    @AppStorage("cofleet.progress.codexCompanionMode")
    private var codexCompanionMode = false

    @State private var showsSessionPicker = false
    @State private var showsAgentVisibility = false
    @State private var showsAddProject = false
    @State private var showsPetLibrary = false
    @State private var projectPendingRename: CoFleetProject?
    @State private var renameDraft = ""
    @State private var projectPendingRemoval: CoFleetProject?
    @State private var projectOperationID: String?
    @State private var projectLifecycleError: String?
    @State private var companionPendingProjectID: String?
    @State private var companionError: String?

    public init(
        fleetStore: FleetStore,
        threadStore: ThreadStore,
        turnStore: TurnStore,
        workspaceStore: WorkspaceStore,
        settings: Binding<CoFleetSessionSettings>,
        localHostID: CoFleetHostID? = nil
    ) {
        self.fleetStore = fleetStore
        self.threadStore = threadStore
        self.turnStore = turnStore
        self.workspaceStore = workspaceStore
        _settings = settings
        self.localHostID = localHostID
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent Progress")
                        .font(.system(.title2, design: .rounded, weight: .heavy))
                    if horizontalSizeClass != .compact {
                        Text("\(fleetStore.visibleProjects.count) visible projects")
                            .font(.caption.monospaced().weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle(isOn: $codexCompanionMode) {
                    Label(
                        horizontalSizeClass == .compact ? "Codex" : "Codex Companion",
                        systemImage: codexCompanionMode ? "iphone.and.arrow.forward" : "iphone"
                    )
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            codexCompanionMode ? CoFleetTheme.cyan.opacity(0.2) : Color.white.opacity(0.07),
                            in: Capsule()
                        )
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .help("When enabled, tapping a project asks its Mac host to open the current task in Codex")
                .accessibilityIdentifier("cofleet.progress.codex-companion")
                Button {
                    showsAddProject = true
                } label: {
                    Label(horizontalSizeClass == .compact ? "" : "Add Project", systemImage: "folder.badge.plus")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    showsAgentVisibility.toggle()
                } label: {
                    Label(horizontalSizeClass == .compact ? "" : "Projects", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsAgentVisibility) {
                    projectVisibilityPopover
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)

            GeometryReader { proxy in
                ScrollView {
                    if fleetStore.visibleProjectGroups.isEmpty {
                        ContentUnavailableView(
                            "No Visible Projects",
                            systemImage: "rectangle.stack.badge.minus",
                            description: Text("Use Projects to show a registered project, or add a new one.")
                        )
                        .frame(maxWidth: .infinity, minHeight: max(260, proxy.size.height * 0.65))
                    } else {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(fleetStore.visibleProjectGroups) { group in
                                VStack(alignment: .leading, spacing: 10) {
                                    hostGroupHeader(group)
                                    if !fleetStore.isHostCollapsed(group.hostID) {
                                        LazyVGrid(columns: columns(for: proxy.size.width), spacing: 12) {
                                            ForEach(group.projects) { project in
                                                projectCard(project: project, width: cardWidth(proxy.size.width))
                                                    .draggable(project.id)
                                                    .dropDestination(for: String.self) { projectIDs, _ in
                                                        guard let projectID = projectIDs.first else { return false }
                                                        return fleetStore.moveProject(projectID, before: project.id)
                                                    }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(12)
                    }
                }
            }
        }
        .background(CoFleetTheme.background)
        .accessibilityIdentifier("cofleet.destination.progress")
        .sheet(isPresented: $showsSessionPicker) {
            CoFleetSessionPicker(store: threadStore)
        }
        .sheet(isPresented: $showsAddProject) {
            CoFleetProjectRegistrationView(fleetStore: fleetStore)
        }
        .sheet(isPresented: $showsPetLibrary) {
            if let project = fleetStore.selectedProject {
                CoFleetPetLibraryView(
                    workspaceStore: workspaceStore,
                    project: project,
                    onProjectUpdated: fleetStore.applyProjectUpdate
                )
            }
        }
        .alert(
            "Rename Project",
            isPresented: renameIsPresented,
            presenting: projectPendingRename
        ) { project in
            TextField("Project name", text: $renameDraft)
            Button("Cancel", role: .cancel) {
                projectPendingRename = nil
                renameDraft = ""
            }
            Button("Rename") {
                let requestedName = renameDraft
                projectPendingRename = nil
                renameDraft = ""
                Task { await renameProject(project, to: requestedName) }
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { project in
            Text("Rename \(project.displayName)'s CoFleet card. Its directory and files will not change.")
        }
        .confirmationDialog(
            "Remove Project?",
            isPresented: removalIsPresented,
            titleVisibility: .visible,
            presenting: projectPendingRemoval
        ) { project in
            Button("Remove \(project.displayName)", role: .destructive) {
                projectPendingRemoval = nil
                Task { await removeProject(project) }
            }
            Button("Cancel", role: .cancel) {
                projectPendingRemoval = nil
            }
        } message: { project in
            Text("This only unregisters \(project.displayName) from CoFleet. Its directory and files will stay on the host.")
        }
        .alert("Couldn't Update Project", isPresented: lifecycleErrorIsPresented) {
            Button("OK", role: .cancel) { projectLifecycleError = nil }
        } message: {
            Text(projectLifecycleError ?? "An unknown error occurred.")
        }
        .alert("Couldn’t Open Codex", isPresented: companionErrorIsPresented) {
            Button("OK", role: .cancel) { companionError = nil }
        } message: {
            Text(companionError ?? "The host could not open this task in Codex.")
        }
        .onChange(of: threadStore.sessions.map(\.id)) {
            openPendingCompanionTaskIfReady()
        }
        .onChange(of: threadStore.isLoading) { _, isLoading in
            if !isLoading { openPendingCompanionTaskIfReady() }
        }
        .onChange(of: codexCompanionMode) { _, isEnabled in
            if !isEnabled { companionPendingProjectID = nil }
        }
        .task {
            if !fleetStore.hosts.isEmpty && fleetStore.projects.isEmpty {
                showsAddProject = true
            }
        }
    }

    @ViewBuilder
    private func projectCard(project: CoFleetProject, width: CGFloat) -> some View {
        let host = fleetStore.hosts.first { $0.id == project.hostID }
        let selected = fleetStore.selectedProjectID == project.id
        CoFleetProjectCard(
            project: project,
            host: host,
            session: selected ? threadStore.selectedSession : nil,
            noteMarkdown: selected ? $workspaceStore.noteDraft : .constant(""),
            todos: selected ? workspaceStore.todos : [],
            todoDraft: selected ? $workspaceStore.todoDraft : .constant(""),
            draft: selected ? $turnStore.draft : .constant(""),
            selected: selected,
            canEditWorkspace: selected && workspaceStore.isHostOnline,
            noteHasChanges: selected && workspaceStore.hasUnsavedNoteDraft,
            hasNoteConflict: selected && workspaceStore.noteConflict != nil,
            petManifest: selected ? workspaceStore.pets.first {
                $0.id == workspaceStore.selectedPetID
            } : nil,
            petAsset: selected ? workspaceStore.selectedPetAsset : nil,
            availableWidth: width,
            localThreadURL: localURL(for: project),
            onSelect: { selectOrOpen(project) },
            onShowSessions: {
                fleetStore.selectedProjectID = project.id
                showsSessionPicker = true
            },
            onShowPets: {
                fleetStore.selectedProjectID = project.id
                showsPetLibrary = true
            },
            onSend: {
                guard selected else { fleetStore.selectedProjectID = project.id; return }
                Task { _ = try? await turnStore.send(settings: settings) }
            },
            onSaveNote: { Task { try? await workspaceStore.saveNote() } },
            onKeepNoteDraft: { workspaceStore.resolveNoteConflictKeepingDraft() },
            onUseHostNote: { workspaceStore.resolveNoteConflictUsingHost() },
            onAddTodo: { Task { _ = try? await workspaceStore.addTodo() } },
            onToggleTodo: { id in Task { try? await workspaceStore.toggleTodo(id: id) } },
            onDeleteTodo: { id in Task { try? await workspaceStore.deleteTodo(id: id) } },
            isManagingProject: projectOperationID == project.id,
            onRenameProject: { beginRenaming(project) },
            onRemoveProject: { beginRemoving(project) }
        )
    }

    private var renameIsPresented: Binding<Bool> {
        Binding(
            get: { projectPendingRename != nil },
            set: { presented in
                if !presented {
                    projectPendingRename = nil
                    renameDraft = ""
                }
            }
        )
    }

    private var removalIsPresented: Binding<Bool> {
        Binding(
            get: { projectPendingRemoval != nil },
            set: { presented in
                if !presented { projectPendingRemoval = nil }
            }
        )
    }

    private var lifecycleErrorIsPresented: Binding<Bool> {
        Binding(
            get: { projectLifecycleError != nil },
            set: { presented in
                if !presented { projectLifecycleError = nil }
            }
        )
    }

    private var companionErrorIsPresented: Binding<Bool> {
        Binding(
            get: { companionError != nil },
            set: { presented in
                if !presented { companionError = nil }
            }
        )
    }

    private func selectOrOpen(_ project: CoFleetProject) {
        guard codexCompanionMode else {
            fleetStore.selectedProjectID = project.id
            return
        }

        companionError = nil
        companionPendingProjectID = project.id
        if fleetStore.selectedProjectID != project.id {
            fleetStore.selectedProjectID = project.id
        } else {
            openPendingCompanionTaskIfReady()
        }
    }

    private func openPendingCompanionTaskIfReady() {
        guard let projectID = companionPendingProjectID,
              fleetStore.selectedProjectID == projectID,
              !threadStore.isLoading else { return }
        guard threadStore.loadedProjectID == projectID else { return }
        guard let project = fleetStore.selectedProject,
              let host = fleetStore.hosts.first(where: { $0.id == project.hostID }) else { return }
        guard host.reachability == .online else {
            companionPendingProjectID = nil
            companionError = "\(host.displayName) is offline, so it can’t open this task."
            return
        }
        guard host.capabilities.canNavigateCodexDesktop else {
            companionPendingProjectID = nil
            companionError = "Update cofleet-host on \(host.displayName), then refresh Progress to enable Codex Companion."
            return
        }
        guard threadStore.selectedSession != nil else {
            companionPendingProjectID = nil
            companionError = "This project does not have a Codex task to open yet."
            return
        }

        companionPendingProjectID = nil
        Task {
            do {
                try await threadStore.openSelectedInCodex()
            } catch {
                companionError = error.localizedDescription
            }
        }
    }

    private func beginRenaming(_ project: CoFleetProject) {
        guard projectOperationID == nil else { return }
        projectLifecycleError = nil
        renameDraft = project.displayName
        projectPendingRename = project
    }

    private func beginRemoving(_ project: CoFleetProject) {
        guard projectOperationID == nil else { return }
        projectLifecycleError = nil
        projectPendingRemoval = project
    }

    private func renameProject(_ project: CoFleetProject, to requestedName: String) async {
        guard projectOperationID == nil else { return }
        projectOperationID = project.id
        defer { projectOperationID = nil }
        do {
            try await fleetStore.renameProject(id: project.id, displayName: requestedName)
        } catch {
            projectLifecycleError = "\(project.displayName) couldn't be renamed. \(error.localizedDescription)"
        }
    }

    private func removeProject(_ project: CoFleetProject) async {
        guard projectOperationID == nil else { return }
        projectOperationID = project.id
        defer { projectOperationID = nil }
        do {
            try await fleetStore.removeProject(id: project.id)
        } catch {
            projectLifecycleError = "\(project.displayName) couldn't be removed from CoFleet. \(error.localizedDescription)"
        }
    }

    private func localURL(for project: CoFleetProject) -> URL? {
        guard let localHostID,
              let session = threadStore.selectedSession,
              session.projectID == project.id else { return nil }
        return CodexDeepLinkResolver.localThreadURL(session: session, localHostID: localHostID)
    }

    private func columns(for width: CGFloat) -> [GridItem] {
        let count = CoFleetResponsivePolicy.progressColumns(availableWidth: width).rawValue
        return Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: count)
    }

    private func cardWidth(_ width: CGFloat) -> CGFloat {
        CoFleetResponsivePolicy.progressColumns(availableWidth: width) == .two
            ? max(320, (width - 36) / 2)
            : max(280, width - 24)
    }

    private func hostGroupHeader(_ group: CoFleetProjectGroup) -> some View {
        let collapsed = fleetStore.isHostCollapsed(group.hostID)
        let name = group.host?.displayName ?? "Unknown host"
        let reachability = group.host?.reachability ?? .unknown
        return Button {
            fleetStore.toggleHostCollapsed(group.hostID)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Circle()
                    .fill(reachabilityColor(reachability))
                    .frame(width: 8, height: 8)
                Text(name)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                Text(reachability.rawValue.capitalized)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(group.projects.count) \(group.projects.count == 1 ? "project" : "projects")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(CoFleetTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(group.projects.count) projects")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(collapsed ? "Expands this host" : "Collapses this host")
    }

    private var projectVisibilityPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Project Organization").font(.headline)
                    Text("Choose visible cards and drag them into order within each host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(fleetStore.allProjectGroups) { group in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Button {
                                let showsAll = fleetStore.visibilityState(forHost: group.hostID) == .all
                                fleetStore.setVisibility(!showsAll, forHost: group.hostID)
                            } label: {
                                Image(systemName: hostVisibilitySymbol(group.hostID))
                                    .font(.body.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Toggle all projects on \(group.host?.displayName ?? "this host")")

                            Text(group.host?.displayName ?? "Unknown host")
                                .font(.subheadline.bold())
                            Spacer()
                            Text("\(group.projects.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        ForEach(group.projects) { project in
                            HStack(spacing: 9) {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                                Toggle(
                                    project.displayName,
                                    isOn: Binding(
                                        get: {
                                            fleetStore.projects.first(where: { $0.id == project.id })?.isVisible ?? false
                                        },
                                        set: { fleetStore.setVisibility($0, for: project.id) }
                                    )
                                )
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                            .draggable(project.id)
                            .dropDestination(for: String.self) { projectIDs, _ in
                                guard let projectID = projectIDs.first else { return false }
                                return fleetStore.moveProject(projectID, before: project.id)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 300, idealWidth: 340, maxWidth: 400, maxHeight: 520)
        .presentationCompactAdaptation(.sheet)
    }

    private func hostVisibilitySymbol(_ hostID: CoFleetHostID) -> String {
        switch fleetStore.visibilityState(forHost: hostID) {
        case .all: "checkmark.square.fill"
        case .some: "minus.square.fill"
        case .none: "square"
        }
    }

    private func reachabilityColor(_ reachability: CoFleetReachability) -> Color {
        switch reachability {
        case .online: CoFleetTheme.green
        case .degraded: CoFleetTheme.orange
        case .offline, .unknown: .gray
        }
    }
}

public struct CoFleetProjectCard: View {
    public var project: CoFleetProject
    public var host: CoFleetHostInfo?
    public var session: CoFleetSessionSummary?
    @Binding public var noteMarkdown: String
    public var todos: [CoFleetTodoItem]
    @Binding public var todoDraft: String
    @Binding public var draft: String
    public var selected: Bool
    public var canEditWorkspace: Bool
    public var noteHasChanges: Bool
    public var hasNoteConflict: Bool
    public var petManifest: CoFleetPetManifest?
    public var petAsset: CoFleetPetAsset?
    public var availableWidth: CGFloat
    public var localThreadURL: URL?
    public var onSelect: () -> Void
    public var onShowSessions: () -> Void
    public var onShowPets: () -> Void
    public var onSend: () -> Void
    public var onSaveNote: () -> Void
    public var onKeepNoteDraft: () -> Void
    public var onUseHostNote: () -> Void
    public var onAddTodo: () -> Void
    public var onToggleTodo: (String) -> Void
    public var onDeleteTodo: (String) -> Void
    public var isManagingProject: Bool
    public var onRenameProject: () -> Void
    public var onRemoveProject: () -> Void

    public init(
        project: CoFleetProject,
        host: CoFleetHostInfo?,
        session: CoFleetSessionSummary?,
        noteMarkdown: Binding<String>,
        todos: [CoFleetTodoItem],
        todoDraft: Binding<String>,
        draft: Binding<String>,
        selected: Bool,
        canEditWorkspace: Bool,
        noteHasChanges: Bool,
        hasNoteConflict: Bool,
        petManifest: CoFleetPetManifest?,
        petAsset: CoFleetPetAsset?,
        availableWidth: CGFloat,
        localThreadURL: URL?,
        onSelect: @escaping () -> Void,
        onShowSessions: @escaping () -> Void,
        onShowPets: @escaping () -> Void,
        onSend: @escaping () -> Void,
        onSaveNote: @escaping () -> Void,
        onKeepNoteDraft: @escaping () -> Void,
        onUseHostNote: @escaping () -> Void,
        onAddTodo: @escaping () -> Void,
        onToggleTodo: @escaping (String) -> Void,
        onDeleteTodo: @escaping (String) -> Void,
        isManagingProject: Bool = false,
        onRenameProject: @escaping () -> Void = {},
        onRemoveProject: @escaping () -> Void = {}
    ) {
        self.project = project
        self.host = host
        self.session = session
        _noteMarkdown = noteMarkdown
        self.todos = todos
        _todoDraft = todoDraft
        _draft = draft
        self.selected = selected
        self.canEditWorkspace = canEditWorkspace
        self.noteHasChanges = noteHasChanges
        self.hasNoteConflict = hasNoteConflict
        self.petManifest = petManifest
        self.petAsset = petAsset
        self.availableWidth = availableWidth
        self.localThreadURL = localThreadURL
        self.onSelect = onSelect
        self.onShowSessions = onShowSessions
        self.onShowPets = onShowPets
        self.onSend = onSend
        self.onSaveNote = onSaveNote
        self.onKeepNoteDraft = onKeepNoteDraft
        self.onUseHostNote = onUseHostNote
        self.onAddTodo = onAddTodo
        self.onToggleTodo = onToggleTodo
        self.onDeleteTodo = onDeleteTodo
        self.isManagingProject = isManagingProject
        self.onRenameProject = onRenameProject
        self.onRemoveProject = onRemoveProject
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if CoFleetResponsivePolicy.cardHeaderPlacesNotesBesideIdentity(availableWidth: availableWidth) {
                HStack(alignment: .top, spacing: 14) {
                    identity
                    notes.frame(maxWidth: .infinity, minHeight: 88)
                }
            } else {
                identity
                notes.frame(minHeight: 82)
            }

            if let session {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("LAST SESSION")
                            .tracking(0.7)
                        Text("·")
                        Text(session.updatedAt.formatted(.relative(presentation: .named)))
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    if let preview = session.preview {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.title)
                                .font(.caption2.monospaced().weight(.bold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Text(preview)
                                .font(.callout.weight(.medium))
                                .lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(CoFleetTheme.subtleFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(CoFleetTheme.hairline)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                TextField("Message \(project.displayName)…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(CoFleetTheme.hairline)
                    }
                    .disabled(!selected)
                    .onSubmit(onSend)
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.headline.bold())
                        .frame(width: 34, height: 34)
                        .background(CoFleetTheme.cyan, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!selected || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .background(
            selected ? CoFleetTheme.cyan.opacity(0.075) : CoFleetTheme.panelFill,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(selected ? CoFleetTheme.cyan.opacity(0.7) : CoFleetTheme.hairline, lineWidth: selected ? 1.5 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                CoFleetPetSpriteView(
                    name: project.displayName,
                    manifest: petManifest,
                    asset: petAsset,
                    action: project.state.actionIndicator
                )
                VStack(alignment: .leading, spacing: 5) {
                    Text(project.displayName)
                        .font(.system(.headline, design: .rounded, weight: .bold))
                    Text(host?.displayName ?? "Unknown host")
                        .font(.caption.monospaced().weight(.medium))
                        .foregroundStyle(.secondary)
                    CoFleetStatusIndicators(
                        reachability: host?.reachability ?? .unknown,
                        action: project.state.actionIndicator,
                        sourceControl: project.sourceControl
                    )
                }
            }
            HStack(spacing: 12) {
                Button(action: onShowSessions) {
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Session history")
                Button(action: onShowPets) {
                    Label("Pet", systemImage: "shippingbox")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Choose pet")
                if let localThreadURL {
                    Link(destination: localThreadURL) {
                        Label("Codex", systemImage: "arrow.up.forward.app")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Open in Codex")
                }
                Menu {
                    Button(action: onRenameProject) {
                        Label("Rename Project", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive, action: onRemoveProject) {
                        Label("Remove Project", systemImage: "minus.circle")
                    }
                } label: {
                    Label("Manage", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(isManagingProject)
                .accessibilityLabel("Manage \(project.displayName)")
            }
        }
        .frame(minWidth: 170, alignment: .leading)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Notes", systemImage: "note.text")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if !canEditWorkspace && selected {
                    Label("Offline draft", systemImage: "icloud.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button("Save", action: onSaveNote)
                    .buttonStyle(.borderless)
                    .disabled(!canEditWorkspace || !noteHasChanges || hasNoteConflict)
            }
            CoFleetRichNoteEditor(markdown: $noteMarkdown, isReadOnly: !selected)
                .frame(minHeight: 82)

            if hasNoteConflict {
                VStack(alignment: .leading, spacing: 5) {
                    Label("The host note changed. Reconcile before saving.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(CoFleetTheme.orange)
                    HStack {
                        Button("Keep my draft", action: onKeepNoteDraft)
                        Button("Use host note", action: onUseHostNote)
                    }
                    .buttonStyle(.borderless)
                }
            }

            Divider()
            Label("Todos", systemImage: "checklist")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(todos.prefix(5)) { todo in
                HStack(spacing: 7) {
                    Button { onToggleTodo(todo.id) } label: {
                        Image(systemName: todo.isCompleted ? "checkmark.square.fill" : "square")
                    }
                    .buttonStyle(.plain)
                    .disabled(!canEditWorkspace)
                    Text(todo.title)
                        .font(.caption)
                        .strikethrough(todo.isCompleted)
                        .lineLimit(2)
                    Spacer()
                    Button(role: .destructive) { onDeleteTodo(todo.id) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .disabled(!canEditWorkspace)
                }
            }
            HStack(spacing: 6) {
                TextField("Add todo…", text: $todoDraft)
                    .textFieldStyle(.plain)
                    .onSubmit(onAddTodo)
                Button(action: onAddTodo) { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.plain)
                    .disabled(!canEditWorkspace || todoDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(7)
            .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
            .disabled(!selected)
        }
        .padding(10)
        .background(CoFleetTheme.subtleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(CoFleetTheme.hairline)
        }
    }
}

struct CoFleetProjectRegistrationView: View {
    @Bindable var fleetStore: FleetStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let showsCloseButton: Bool
    private let dismissesOnRegistration: Bool
    private let onRegistered: (CoFleetProject) -> Void

    @State private var selectedHostID: CoFleetHostID?
    @State private var page: CoFleetDirectoryPage?
    @State private var recentRoots: [CoFleetDirectoryEntry] = []
    @State private var showHidden = false
    @State private var displayName = ""
    @State private var newFolderName = ""
    @State private var showsCreateFolder = false
    @State private var isLoading = false
    @State private var isRegistering = false
    @State private var errorMessage: String?

    init(
        fleetStore: FleetStore,
        showsCloseButton: Bool = true,
        dismissesOnRegistration: Bool = true,
        onRegistered: @escaping (CoFleetProject) -> Void = { _ in }
    ) {
        self.fleetStore = fleetStore
        self.showsCloseButton = showsCloseButton
        self.dismissesOnRegistration = dismissesOnRegistration
        self.onRegistered = onRegistered
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                if isLoading && page == nil {
                    ProgressView("Loading folders…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if fleetStore.hosts.isEmpty {
                    ContentUnavailableView(
                        "Pair a Host First",
                        systemImage: "network.slash",
                        description: Text("Close this sheet and pair a CoFleet host before adding a project.")
                    )
                } else {
                    directoryBrowser
                }
                Divider()
                registrationBar
            }
            .navigationTitle(showsCloseButton ? "Add Project" : "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(showsCloseButton ? .visible : .hidden, for: .navigationBar)
            #endif
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
            }
        }
        .frame(minWidth: sheetMinimumWidth, minHeight: sheetMinimumHeight)
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .task { await selectInitialHost() }
        .alert("Create Folder", isPresented: $showsCreateFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") { Task { await createFolder() } }
                .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The folder is created inside the directory currently shown.")
        }
        .alert("Couldn’t Add Project", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Host", selection: $selectedHostID) {
                Text("Choose a host").tag(Optional<CoFleetHostID>.none)
                ForEach(fleetStore.hosts) { host in
                    Text(host.reachability == .offline ? "\(host.displayName) — Offline" : host.displayName)
                        .tag(Optional(host.id))
                        .disabled(host.reachability == .offline || !host.capabilities.canBrowseDirectories)
                }
            }
            .onChange(of: selectedHostID) { _, _ in
                Task { await loadSelectedHost() }
            }

            if !recentRoots.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggested from recent Codex tasks")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(recentRoots) { root in
                                Button {
                                    Task { await loadDirectory(root.canonicalPath) }
                                } label: {
                                    Label(root.name, systemImage: "clock.arrow.circlepath")
                                        .lineLimit(1)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, horizontalSizeClass == .compact ? 12 : 16)
        .padding(.vertical, horizontalSizeClass == .compact ? 8 : 16)
    }

    private var directoryBrowser: some View {
        VStack(spacing: 0) {
            Group {
                if horizontalSizeClass == .compact {
                    compactDirectoryToolbar
                } else {
                    wideDirectoryToolbar
                }
            }
            .padding(.horizontal)
            .padding(.vertical, horizontalSizeClass == .compact ? 7 : 10)

            List {
                if let page {
                    Section("Directories") {
                        if page.entries.isEmpty {
                            Text("No subfolders")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(page.entries) { entry in
                            Button {
                                guard entry.isReadable else { return }
                                Task { await loadDirectory(entry.canonicalPath) }
                            } label: {
                                HStack {
                                    Image(systemName: entry.isSymbolicLink ? "folder.badge.gearshape" : "folder")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name)
                                        if entry.isSymbolicLink {
                                            Text(entry.canonicalPath)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if !entry.isReadable {
                                        Image(systemName: "lock.fill")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!entry.isReadable)
                        }
                        if page.nextCursor != nil {
                            Button("Load More") { Task { await loadMore() } }
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .onChange(of: showHidden) { _, _ in
            guard let path = page?.canonicalPath else { return }
            Task { await loadDirectory(path) }
        }
    }

    private var registrationBar: some View {
        Group {
            if horizontalSizeClass == .compact {
                HStack(spacing: 10) {
                    projectNameField
                    addProjectButton
                        .controlSize(.regular)
                }
            } else {
                HStack(spacing: 10) {
                    selectedRootLabel
                        .frame(maxWidth: .infinity, alignment: .leading)
                    projectNameField
                        .frame(minWidth: 180, maxWidth: 260)
                    addProjectButton
                }
            }
        }
        .padding(horizontalSizeClass == .compact ? 10 : 16)
    }

    private var wideDirectoryToolbar: some View {
        HStack(spacing: 8) {
            upButton
            homeButton
            rootButton
            directoryPathLabel
            Toggle("Hidden", isOn: $showHidden).toggleStyle(.switch)
            newFolderButton
        }
    }

    private var compactDirectoryToolbar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                upButton
                homeButton
                rootButton
                Spacer()
                Button {
                    showHidden.toggle()
                } label: {
                    Image(systemName: showHidden ? "eye.fill" : "eye.slash")
                }
                .accessibilityLabel(showHidden ? "Hide Hidden Folders" : "Show Hidden Folders")
                .buttonStyle(.bordered)
                newFolderButton
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("New Folder")
            }
            directoryPathLabel
        }
    }

    private var upButton: some View {
        Button {
            guard let parent = page?.parentPath else { return }
            Task { await loadDirectory(parent) }
        } label: {
            Label("Up", systemImage: "arrow.up")
        }
        .disabled(page?.parentPath == nil)
    }

    private var homeButton: some View {
        Button("Home") {
            guard let home = selectedHost?.canonicalHome else { return }
            Task { await loadDirectory(home) }
        }
    }

    private var rootButton: some View {
        Button("/") { Task { await loadDirectory("/") } }
    }

    private var directoryPathLabel: some View {
        Text(page?.canonicalPath ?? selectedHost?.canonicalHome ?? "")
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var newFolderButton: some View {
        Button {
            newFolderName = ""
            showsCreateFolder = true
        } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
        .disabled(page == nil || selectedHost?.capabilities.canCreateDirectories != true)
    }

    private var selectedRootLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Selected root")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(page?.canonicalPath ?? "Choose a readable folder")
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var projectNameField: some View {
        TextField("Project name", text: $displayName)
            .textFieldStyle(.roundedBorder)
    }

    private var addProjectButton: some View {
        Button {
            Task { await registerProject() }
        } label: {
            if isRegistering {
                ProgressView().controlSize(.small)
            } else {
                Text("Add Project")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(page == nil || selectedHostID == nil || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRegistering)
    }

    private var sheetMinimumWidth: CGFloat? {
        #if os(macOS)
        620
        #else
        nil
        #endif
    }

    private var sheetMinimumHeight: CGFloat? {
        #if os(macOS)
        560
        #else
        nil
        #endif
    }

    private var selectedHost: CoFleetHostInfo? {
        guard let selectedHostID else { return nil }
        return fleetStore.hosts.first { $0.id == selectedHostID }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    @MainActor
    private func selectInitialHost() async {
        guard selectedHostID == nil else { return }
        selectedHostID = fleetStore.hosts.first {
            $0.reachability != .offline && $0.capabilities.canBrowseDirectories
        }?.id
    }

    @MainActor
    private func loadSelectedHost() async {
        page = nil
        recentRoots = []
        displayName = ""
        guard let host = selectedHost,
              host.reachability != .offline,
              host.capabilities.canBrowseDirectories else { return }
        async let suggestionsResult = loadSuggestions(hostID: host.id)
        await loadDirectory(host.canonicalHome)
        _ = await suggestionsResult
    }

    @MainActor
    private func loadSuggestions(hostID: CoFleetHostID) async {
        do {
            recentRoots = try await fleetStore.discoverRecentRoots(hostID: hostID).entries
        } catch {
            // Directory browsing remains available when Codex has no recent roots.
            recentRoots = []
        }
    }

    @MainActor
    private func loadDirectory(_ path: String) async {
        guard let hostID = selectedHostID else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await fleetStore.browseDirectories(
                hostID: hostID,
                path: path,
                showHidden: showHidden
            )
            page = loaded
            displayName = suggestedName(for: loaded.canonicalPath)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadMore() async {
        guard let hostID = selectedHostID,
              let current = page,
              let cursor = current.nextCursor else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let next = try await fleetStore.browseDirectories(
                hostID: hostID,
                path: current.canonicalPath,
                cursor: cursor,
                showHidden: showHidden
            )
            page = CoFleetDirectoryPage(
                canonicalPath: next.canonicalPath,
                parentPath: next.parentPath,
                entries: current.entries + next.entries,
                nextCursor: next.nextCursor
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func createFolder() async {
        guard let hostID = selectedHostID, let parent = page?.canonicalPath else { return }
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let directory = try await fleetStore.createDirectory(hostID: hostID, parent: parent, name: name)
            newFolderName = ""
            await loadDirectory(directory.canonicalPath)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func registerProject() async {
        guard let hostID = selectedHostID, let root = page?.canonicalPath else { return }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isRegistering = true
        defer { isRegistering = false }
        do {
            let project = try await fleetStore.registerProject(
                hostID: hostID,
                canonicalPath: root,
                displayName: name
            )
            onRegistered(project)
            if dismissesOnRegistration {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func suggestedName(for path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? selectedHost?.displayName ?? "Project" : name
    }
}
#endif
