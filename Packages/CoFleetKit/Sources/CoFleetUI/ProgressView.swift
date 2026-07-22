import CoFleetCodex
import CoFleetCore
import SwiftUI

#if !os(watchOS)

struct CoFleetProgressHeaderMetrics: Equatable {
    var isCompact: Bool
    var spacing: CGFloat
    var identityWidth: CGFloat
    var detailWidth: CGFloat
    var portraitDiameter: CGFloat
    var spriteDiameter: CGFloat
}

enum CoFleetProgressHeaderLayout {
    /// Mirrors Manada's single-row identity + note layout, while reserving a
    /// little more room for CoFleet's Codex and session controls.
    static func metrics(availableWidth: CGFloat) -> CoFleetProgressHeaderMetrics {
        let width = max(0, availableWidth.isFinite ? availableWidth : 0)
        let isCompact = width < 420
        let spacing: CGFloat = isCompact ? 8 : 12
        let minimumDetailWidth: CGFloat = isCompact ? 124 : 160
        let desiredIdentityWidth = isCompact
            ? min(max(width * 0.52, 150), 188)
            : min(max(width * 0.48, 190), 240)
        let identityWidth = min(
            desiredIdentityWidth,
            max(0, width - spacing - minimumDetailWidth)
        )
        return CoFleetProgressHeaderMetrics(
            isCompact: isCompact,
            spacing: spacing,
            identityWidth: identityWidth,
            detailWidth: max(0, width - spacing - identityWidth),
            portraitDiameter: isCompact ? 48 : 62,
            spriteDiameter: isCompact ? 38 : 47
        )
    }
}

enum CoFleetProgressTodoProjection {
    static func preview(_ todos: [CoFleetTodoItem], limit: Int = 4) -> [CoFleetTodoItem] {
        let ordered = todos.sorted { lhs, rhs in
            if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.updatedAt < rhs.updatedAt
        }
        return Array(ordered.prefix(max(0, limit)))
    }
}

enum CoFleetProgressProviderBadgePolicy {
    static func activityLabel(
        activity: CoFleetProjectActivity?,
        projectState: CoFleetProjectState,
        reachability: CoFleetReachability
    ) -> String {
        switch reachability {
        case .offline, .degraded:
            return "Offline"
        case .unknown:
            return "Checking"
        case .online:
            break
        }

        if let activity {
            switch activity {
            case .idle: return "Idle"
            case .thinking: return "Thinking"
            case .reasoning: return "Reasoning"
            case .runningCommand: return "Command"
            case .approval: return "Approval"
            case .question: return "Question"
            case .replied: return "Replied"
            }
        }

        switch projectState {
        case .idle: return "Idle"
        case .working: return "Working"
        case .waitingForApproval: return "Approval"
        case .waitingForAnswer: return "Question"
        case .replied: return "Replied"
        case .unavailable: return "Offline"
        }
    }
}

public struct CoFleetProgressView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable private var fleetStore: FleetStore
    @Bindable private var threadStore: ThreadStore
    @Bindable private var turnStore: TurnStore
    @Bindable private var workspaceStore: WorkspaceStore
    @Binding private var settings: CoFleetSessionSettings
    private let localHostID: CoFleetHostID?
    private let onOpenProject: (String) -> Void
    private let onHatchPet: (@MainActor (CoFleetProject) async throws -> Void)?
    private let isVisible: Bool

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
    @State private var draftsByProjectID: [String: String] = [:]
    @State private var sendingProjectID: String?
    @State private var companionRequestID: UUID?
    @State private var companionError: String?
    @State private var sendError: String?
    @State private var dropTargetProjectID: String?

    public init(
        fleetStore: FleetStore,
        threadStore: ThreadStore,
        turnStore: TurnStore,
        workspaceStore: WorkspaceStore,
        settings: Binding<CoFleetSessionSettings>,
        localHostID: CoFleetHostID? = nil,
        isVisible: Bool = true,
        onOpenProject: @escaping (String) -> Void = { _ in },
        onHatchPet: (@MainActor (CoFleetProject) async throws -> Void)? = nil
    ) {
        self.fleetStore = fleetStore
        self.threadStore = threadStore
        self.turnStore = turnStore
        self.workspaceStore = workspaceStore
        _settings = settings
        self.localHostID = localHostID
        self.isVisible = isVisible
        self.onOpenProject = onOpenProject
        self.onHatchPet = onHatchPet
    }

    public var body: some View {
        ZStack {
            Color(red: 0.022, green: 0.036, blue: 0.050)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                progressHeader
                Divider().opacity(0.45)

                GeometryReader { proxy in
                    ScrollView {
                        Group {
                            if fleetStore.visibleProjects.isEmpty {
                                ContentUnavailableView(
                                    "No projects in this view",
                                    systemImage: "rectangle.stack.badge.plus",
                                    description: Text("Use the Agents menu to choose projects to monitor, or add a new one.")
                                )
                                .frame(maxWidth: .infinity, minHeight: max(260, proxy.size.height * 0.65))
                            } else if CoFleetProgressLayoutPolicy.columnCount(availableWidth: proxy.size.width) == 1 {
                                LazyVStack(spacing: 12) {
                                    ForEach(fleetStore.visibleProjects) { project in
                                        draggableProjectCard(project)
                                    }
                                }
                            } else {
                                let columns = CoFleetProgressLayoutPolicy.columns(from: fleetStore.visibleProjects)
                                HStack(alignment: .top, spacing: 12) {
                                    LazyVStack(spacing: 12) {
                                        ForEach(columns.left) { project in
                                            draggableProjectCard(project)
                                        }
                                    }
                                    LazyVStack(spacing: 12) {
                                        ForEach(columns.right) { project in
                                            draggableProjectCard(project)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
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
                    onProjectUpdated: fleetStore.applyProjectUpdate,
                    onHatchWithCodex: hatchAction(for: project)
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
        .alert("Couldn’t Send Message", isPresented: sendErrorIsPresented) {
            Button("OK", role: .cancel) { sendError = nil }
        } message: {
            Text(sendError ?? "The message could not be sent.")
        }
        .onChange(of: codexCompanionMode) { _, isEnabled in
            if !isEnabled { companionRequestID = nil }
        }
        .task(id: "\(visibleProjectsRefreshIdentity):\(isVisible)") {
            guard isVisible else { return }
            if !fleetStore.hosts.isEmpty && fleetStore.projects.isEmpty {
                showsAddProject = true
            }
            // Load the durable baseline once. Subsequent session/message changes
            // arrive through the host-wide replayable event stream instead of an
            // 8/60-second polling loop.
            async let previews: Void = threadStore.refreshLatestSessionPreviews(
                for: fleetStore.visibleProjects
            )
            async let pets: Void = workspaceStore.loadBattlePets(for: fleetStore.visibleProjects)
            async let todos: Void = workspaceStore.loadBattleTodos(for: fleetStore.visibleProjects)
            _ = await (previews, pets, todos)
        }
    }

    private var progressHeader: some View {
        HStack(spacing: horizontalSizeClass == .compact ? 8 : 14) {
            Text("Agent Progress")
                .font(.system(.title2, design: .rounded).weight(.heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Spacer()
            if horizontalSizeClass != .compact {
                Text("\(fleetStore.visibleProjects.count) visible")
                    .font(.caption.monospaced().weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: $codexCompanionMode) {
                Group {
                    if horizontalSizeClass == .compact {
                        Image(systemName: codexCompanionMode ? "iphone.and.arrow.forward" : "iphone")
                    } else {
                        Label(
                            "Codex Companion",
                            systemImage: codexCompanionMode ? "iphone.and.arrow.forward" : "iphone"
                        )
                    }
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, horizontalSizeClass == .compact ? 7 : 9)
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
                Group {
                    if horizontalSizeClass == .compact {
                        Image(systemName: "folder.badge.plus")
                    } else {
                        Label("Add Project", systemImage: "folder.badge.plus")
                    }
                }
                    .padding(.horizontal, horizontalSizeClass == .compact ? 7 : 9)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Add host project")

            Button {
                showsAgentVisibility.toggle()
            } label: {
                Group {
                    if horizontalSizeClass == .compact {
                        Image(systemName: "slider.horizontal.3")
                    } else {
                        Label("Agents", systemImage: "slider.horizontal.3")
                    }
                }
                    .padding(.horizontal, horizontalSizeClass == .compact ? 7 : 9)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Choose monitored projects")
            .popover(isPresented: $showsAgentVisibility) {
                projectVisibilityPopover
            }
        }
        .padding(.horizontal, horizontalSizeClass == .compact ? 12 : 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func draggableProjectCard(_ project: CoFleetProject) -> some View {
        projectCard(project: project)
            .draggable(project.id) {
                Label(project.displayName, systemImage: "rectangle.stack")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .dropDestination(for: String.self) { projectIDs, _ in
                guard let projectID = projectIDs.first else { return false }
                return fleetStore.moveProject(projectID, before: project.id)
            } isTargeted: { isTargeted in
                withAnimation(.easeOut(duration: 0.12)) {
                    if isTargeted {
                        dropTargetProjectID = project.id
                    } else if dropTargetProjectID == project.id {
                        dropTargetProjectID = nil
                    }
                }
            }
    }

    @ViewBuilder
    private func projectCard(project: CoFleetProject) -> some View {
        let host = fleetStore.hosts.first { $0.id == project.hostID }
        let selected = fleetStore.selectedProjectID == project.id
        let preview = threadStore.latestPreview(for: project.id)
        CoFleetProjectCard(
            project: project,
            host: host,
            activity: fleetStore.activity(for: project.id)?.activity,
            session: threadStore.latestSession(for: project.id),
            sessionCount: threadStore.sessionsByProjectID[project.id]?.count ?? 0,
            messages: preview?.messages ?? [],
            draft: draftBinding(for: project.id),
            selected: selected,
            todos: workspaceStore.battleTodosByProjectID[project.id],
            petManifest: workspaceStore.battlePetManifestsByProjectID[project.id],
            petAsset: workspaceStore.battlePetAssetsByProjectID[project.id],
            localThreadURL: localURL(for: project),
            isLoadingPreview: threadStore.previewLoadingProjectIDs.contains(project.id),
            isLoadingTodos: workspaceStore.battleTodoLoadingProjectIDs.contains(project.id),
            previewError: threadStore.previewErrorsByProjectID[project.id],
            isSending: sendingProjectID == project.id,
            isDropTarget: dropTargetProjectID == project.id,
            onSelect: { Task { await selectOrOpen(project) } },
            onShowSessions: {
                Task { await showSessions(for: project) }
            },
            onShowPets: {
                fleetStore.selectedProjectID = project.id
                showsPetLibrary = true
            },
            onSend: {
                Task { await sendMessage(for: project) }
            },
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

    private var sendErrorIsPresented: Binding<Bool> {
        Binding(
            get: { sendError != nil },
            set: { presented in
                if !presented { sendError = nil }
            }
        )
    }

    private var visibleProjectsRefreshIdentity: String {
        fleetStore.visibleProjects
            .map { "\($0.hostID.rawValue):\($0.id)" }
            .joined(separator: "|")
    }

    private func draftBinding(for projectID: String) -> Binding<String> {
        Binding(
            get: { draftsByProjectID[projectID, default: ""] },
            set: { draftsByProjectID[projectID] = $0 }
        )
    }

    private func selectOrOpen(_ project: CoFleetProject) async {
        guard codexCompanionMode else {
            fleetStore.selectedProjectID = project.id
            onOpenProject(project.id)
            return
        }

        companionError = nil
        let requestID = UUID()
        companionRequestID = requestID
        guard let host = fleetStore.hosts.first(where: { $0.id == project.hostID }) else {
            companionError = "This project’s host is no longer registered."
            return
        }
        guard host.reachability == .online else {
            companionError = "\(host.displayName) is offline, so it can’t open this task."
            return
        }
        guard host.capabilities.canNavigateCodexDesktop else {
            companionError = "Update cofleet-host on \(host.displayName), then refresh Progress to enable Codex Companion."
            return
        }

        fleetStore.selectedProjectID = project.id
        let cachedSessions = threadStore.sessionsByProjectID[project.id] ?? []
        guard let sessionID = CoFleetProgressSessionPolicy.sessionID(
            for: project,
            activeSessionID: activeTurnSessionID(for: project),
            sessions: cachedSessions
        ) else {
            companionRequestID = nil
            companionError = "This project does not have a Codex task to open yet."
            return
        }

        do {
            try await threadStore.openInCodex(hostID: project.hostID, sessionID: sessionID)
        } catch {
            companionError = error.localizedDescription
        }
        if companionRequestID == requestID { companionRequestID = nil }
    }

    private func showSessions(for project: CoFleetProject) async {
        fleetStore.selectedProjectID = project.id
        // Present immediately. `loadInitial` publishes the in-memory project cache
        // before its first suspension, so the sheet never waits on Codex just to
        // become visible; the live first page refreshes behind it.
        showsSessionPicker = true
        await threadStore.loadInitial(hostID: project.hostID, projectID: project.id)
    }

    private func sendMessage(for project: CoFleetProject) async {
        let message = draftsByProjectID[project.id, default: ""]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, sendingProjectID == nil else { return }

        sendingProjectID = project.id
        defer { sendingProjectID = nil }
        sendError = nil

        do {
            fleetStore.selectedProjectID = project.id
            await threadStore.loadInitial(hostID: project.hostID, projectID: project.id)
            guard threadStore.loadedProjectID == project.id else {
                throw CoFleetClientError.unavailable("The project changed before its Codex tasks finished loading.")
            }

            let sessionID: String
            let turnSettings: CoFleetSessionSettings
            if let existingSessionID = CoFleetProgressSessionPolicy.sessionID(
                for: project,
                activeSessionID: activeTurnSessionID(for: project),
                sessions: threadStore.sessions
            ) {
                threadStore.selectedSessionID = existingSessionID
                sessionID = existingSessionID
                turnSettings = CoFleetProgressSessionPolicy.settings(
                    for: existingSessionID,
                    sessions: threadStore.sessions
                )
            } else {
                // Progress has no runtime editor of its own. A new project must not
                // inherit settings from whichever project happened to be open in
                // Agent Bay, so start from Codex/host defaults.
                let session = try await threadStore.createSession(settings: CoFleetSessionSettings())
                sessionID = session.id
                turnSettings = session.settings
            }

            if turnStore.loadedHostID != project.hostID
                || turnStore.loadedProjectID != project.id
                || turnStore.loadedSessionID != sessionID {
                await turnStore.open(hostID: project.hostID, projectID: project.id, sessionID: sessionID)
            }
            if let routeError = turnStore.errorMessage {
                throw CoFleetClientError.unavailable(routeError)
            }

            turnStore.draft = message
            _ = try await turnStore.send(settings: turnSettings)
            draftsByProjectID[project.id] = ""
            threadStore.updateLoadedProjectPreview(items: turnStore.items)
        } catch {
            sendError = "\(project.displayName): \(error.localizedDescription)"
        }
    }

    private func beginRenaming(_ project: CoFleetProject) {
        guard projectOperationID == nil else { return }
        projectLifecycleError = nil
        renameDraft = project.displayName
        projectPendingRename = project
    }

    private func hatchAction(
        for project: CoFleetProject
    ) -> (@MainActor () async throws -> Void)? {
        guard let onHatchPet else { return nil }
        return { try await onHatchPet(project) }
    }

    private func activeTurnSessionID(for project: CoFleetProject) -> String? {
        guard turnStore.loadedHostID == project.hostID,
              turnStore.loadedProjectID == project.id else { return nil }
        return turnStore.loadedSessionID
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
              let session = threadStore.latestSession(for: project.id) else { return nil }
        return CodexDeepLinkResolver.localThreadURL(session: session, localHostID: localHostID)
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

}

enum CoFleetProgressLayoutPolicy {
    private static let horizontalContentInset: CGFloat = 32
    private static let columnSpacing: CGFloat = 12
    private static let minimumTwoColumnCardWidth: CGFloat = 410

    static func columnCount(availableWidth: CGFloat) -> Int {
        let contentWidth = max(0, availableWidth - horizontalContentInset)
        let twoColumnCardWidth = (contentWidth - columnSpacing) / 2
        return twoColumnCardWidth >= minimumTwoColumnCardWidth ? 2 : 1
    }

    static func columns<T>(from items: [T]) -> (left: [T], right: [T]) {
        var left: [T] = []
        var right: [T] = []
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 2) {
                left.append(item)
            } else {
                right.append(item)
            }
        }
        return (left, right)
    }
}

/// Preserves the host's canonical current task and an already-open in-app task,
/// then falls back to the freshest actual Codex task. The first history page is
/// enough for that fallback, but not for the canonical ID which may be older.
enum CoFleetProgressSessionPolicy {
    static func sessionID(
        for project: CoFleetProject,
        activeSessionID: String?,
        sessions: [CoFleetSessionSummary]
    ) -> String? {
        if let currentSessionID = normalized(project.currentSessionID) {
            return currentSessionID
        }
        if let activeSessionID = normalized(activeSessionID) {
            return activeSessionID
        }
        return sessions.filter { session in
            session.hostID == project.hostID
                && session.projectID == project.id
        }
        .max(by: { $0.updatedAt < $1.updatedAt })?
        .id
    }

    static func settings(
        for sessionID: String,
        sessions: [CoFleetSessionSummary]
    ) -> CoFleetSessionSettings {
        sessions.first(where: { $0.id == sessionID })?.settings
            ?? CoFleetSessionSettings()
    }

    private static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public struct CoFleetProjectCard: View {
    public var project: CoFleetProject
    public var host: CoFleetHostInfo?
    public var activity: CoFleetProjectActivity?
    public var session: CoFleetSessionSummary?
    public var sessionCount: Int
    public var messages: [CoFleetTurnItem]
    @Binding public var draft: String
    public var selected: Bool
    public var todos: [CoFleetTodoItem]?
    public var petManifest: CoFleetPetManifest?
    public var petAsset: CoFleetPetAsset?
    public var localThreadURL: URL?
    public var isLoadingPreview: Bool
    public var isLoadingTodos: Bool
    public var previewError: String?
    public var isSending: Bool
    public var isDropTarget: Bool
    public var onSelect: () -> Void
    public var onShowSessions: () -> Void
    public var onShowPets: () -> Void
    public var onSend: () -> Void
    public var isManagingProject: Bool
    public var onRenameProject: () -> Void
    public var onRemoveProject: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var pulse = false
    @State private var selectionExclusionFrames: [CGRect] = []

    public init(
        project: CoFleetProject,
        host: CoFleetHostInfo?,
        activity: CoFleetProjectActivity? = nil,
        session: CoFleetSessionSummary?,
        sessionCount: Int = 0,
        messages: [CoFleetTurnItem],
        draft: Binding<String>,
        selected: Bool,
        todos: [CoFleetTodoItem]? = nil,
        petManifest: CoFleetPetManifest?,
        petAsset: CoFleetPetAsset?,
        localThreadURL: URL?,
        isLoadingPreview: Bool = false,
        isLoadingTodos: Bool = false,
        previewError: String? = nil,
        isSending: Bool = false,
        isDropTarget: Bool = false,
        onSelect: @escaping () -> Void,
        onShowSessions: @escaping () -> Void,
        onShowPets: @escaping () -> Void,
        onSend: @escaping () -> Void,
        isManagingProject: Bool = false,
        onRenameProject: @escaping () -> Void = {},
        onRemoveProject: @escaping () -> Void = {}
    ) {
        self.project = project
        self.host = host
        self.activity = activity
        self.session = session
        self.sessionCount = sessionCount
        self.messages = messages
        _draft = draft
        self.selected = selected
        self.todos = todos
        self.petManifest = petManifest
        self.petAsset = petAsset
        self.localThreadURL = localThreadURL
        self.isLoadingPreview = isLoadingPreview
        self.isLoadingTodos = isLoadingTodos
        self.previewError = previewError
        self.isSending = isSending
        self.isDropTarget = isDropTarget
        self.onSelect = onSelect
        self.onShowSessions = onShowSessions
        self.onShowPets = onShowPets
        self.onSend = onSend
        self.isManagingProject = isManagingProject
        self.onRenameProject = onRenameProject
        self.onRemoveProject = onRemoveProject
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            cardSurface

            VStack(alignment: .leading, spacing: 11) {
                projectHeader

                conversationPreview
                    .allowsHitTesting(false)

                composer
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // Keep selection on the actual card container. The old iOS Button lived
        // behind the visible VStack, so most of the card intercepted its touches.
        // A simultaneous spatial tap lets descendant controls keep their native
        // gestures; measured exclusion frames prevent their taps from also
        // selecting the card.
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .coordinateSpace(name: selectionCoordinateSpace)
        .onPreferenceChange(CoFleetCardSelectionExclusionKey.self) {
            selectionExclusionFrames = $0
        }
        .simultaneousGesture(
            SpatialTapGesture(coordinateSpace: .named(selectionCoordinateSpace))
                .onEnded { value in
                    guard !selectionExclusionFrames.contains(where: { $0.contains(value.location) }) else {
                        return
                    }
                    onSelect()
                }
        )
        .accessibilityAction(named: "Open \(project.displayName)", onSelect)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .shadow(color: accent.opacity(hovered ? 0.13 : 0), radius: 16, y: 5)
        .scaleEffect(hovered && !reduceMotion ? 1.006 : 1)
        .animation(.easeOut(duration: 0.16), value: hovered)
        .onHover { hovered = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .top) {
            if isDropTarget {
                Capsule()
                    .fill(accent)
                    .frame(height: 4)
                    .padding(.horizontal, 9)
                    .offset(y: -7)
                    .shadow(color: accent.opacity(0.8), radius: 7)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var cardSurface: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(
                selected
                    ? accent.opacity(0.15)
                    : Color.white.opacity(hovered ? 0.085 : 0.052)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(
                        selected ? accent.opacity(0.65) : progressColor.opacity(progressState.needsAttention ? 0.5 : 0.14)
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var conversationPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let session {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("LAST SESSION")
                        .tracking(0.7)
                    Text("·")
                    Text(session.updatedAt.formatted(.relative(presentation: .named)))
                }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 2)
                .accessibilityLabel("Last session, \(session.title), \(session.updatedAt.formatted(.relative(presentation: .named)))")

                if messages.isEmpty {
                    if let previewError {
                        Label(previewError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(CoFleetTheme.orange)
                            .lineLimit(2)
                    } else {
                        emptyConversationLabel(
                            isLoadingPreview ? "Loading latest messages…" : "No chat history yet",
                            loading: isLoadingPreview
                        )
                    }
                } else {
                    ForEach(messages) { message in
                        CoFleetProgressMessagePreview(
                            item: message,
                            agentName: project.displayName,
                            accent: accent
                        )
                    }
                }
            } else if isLoadingPreview {
                emptyConversationLabel("Loading latest Codex task…", loading: true)
            } else if let previewError {
                Label(previewError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(CoFleetTheme.orange)
                    .lineLimit(2)
            } else {
                emptyConversationLabel("No chat history yet", loading: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyConversationLabel(_ title: String, loading: Bool) -> some View {
        HStack(spacing: 8) {
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(.tertiary)
            }
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 11)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }

    private var projectHeader: some View {
        GeometryReader { proxy in
            let metrics = CoFleetProgressHeaderLayout.metrics(availableWidth: proxy.size.width)
            HStack(alignment: .top, spacing: metrics.spacing) {
                identity(metrics: metrics)
                    .frame(width: metrics.identityWidth, alignment: .leading)
                todoPreview
                    .frame(width: metrics.detailWidth)
                    .frame(minHeight: 92, maxHeight: 92)
            }
        }
        .frame(height: 92)
    }

    private func identity(metrics: CoFleetProgressHeaderMetrics) -> some View {
        HStack(alignment: .center, spacing: metrics.isCompact ? 8 : 11) {
            portrait(metrics: metrics)

            VStack(alignment: .leading, spacing: metrics.isCompact ? 4 : 6) {
                Text(project.displayName)
                    .font(.system(metrics.isCompact ? .headline : .title3, design: .rounded).weight(.heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)

                HStack(spacing: metrics.isCompact ? 4 : 7) {
                    Text((host?.displayName ?? "Unknown host").uppercased())
                        .font(.system(size: metrics.isCompact ? 10.5 : 13.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .layoutPriority(1)
                    sessionHistoryButton(compact: metrics.isCompact)
                }

                codexPill(compact: metrics.isCompact)
            }
        }
        .padding(.vertical, 4)
    }

    private func sessionHistoryButton(compact: Bool) -> some View {
        Button(action: onShowSessions) {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: compact ? 12 : 16, weight: .bold))
                if sessionCount > 0 {
                    Text("\(sessionCount)")
                        .font(.system(size: compact ? 12 : 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, compact ? 7 : 12)
            .padding(.vertical, compact ? 3 : 4.5)
            .background(Color.white.opacity(0.07), in: Capsule())
            .overlay { Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .cofleetCardSelectionExclusion(in: selectionCoordinateSpace)
        .help("Browse and switch sessions")
        .accessibilityLabel("Session history for \(project.displayName)")
        .accessibilityValue("\(sessionCount) session\(sessionCount == 1 ? "" : "s")")
    }

    private var todoPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "checklist")
                    .foregroundStyle(accent)
                Text("TODOS")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                projectMenu
            }

            if isLoadingTodos, todos == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Loading…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if let todos, !todos.isEmpty {
                ForEach(CoFleetProgressTodoProjection.preview(todos, limit: 3)) { todo in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: todo.isCompleted ? "checkmark.square.fill" : "square")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(todo.isCompleted ? CoFleetTheme.green : .secondary)
                        Text(todo.title)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(todo.isCompleted ? Color.secondary : Color.primary.opacity(0.9))
                            .strikethrough(todo.isCompleted)
                            .lineLimit(1)
                    }
                }
            } else {
                Text("Add two todos to unlock Battle.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(accent.opacity(0.14))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project todos")
    }

    private var projectMenu: some View {
        Menu {
            Button(action: onShowPets) {
                Label("Choose Pet", systemImage: "pawprint")
            }
            if let localThreadURL {
                Link(destination: localThreadURL) {
                    Label("Open in Codex", systemImage: "arrow.up.forward.app")
                }
            }
            Button(action: onRenameProject) {
                Label("Rename Project", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive, action: onRemoveProject) {
                Label("Remove Project", systemImage: "minus.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isManagingProject)
        .cofleetCardSelectionExclusion(in: selectionCoordinateSpace)
        .accessibilityLabel("Manage \(project.displayName)")
    }

    private func portrait(metrics: CoFleetProgressHeaderMetrics) -> some View {
        ZStack {
            Circle().fill(accent.opacity(0.18))
            Circle().stroke(accent.opacity(0.32), lineWidth: 1)
            if petManifest != nil, petAsset != nil {
                CoFleetPetSpriteView(
                    name: project.displayName,
                    manifest: petManifest,
                    asset: petAsset,
                    // Match Manada's portrait behavior: the pet keeps its full
                    // idle preview loop while action state lives in its own ball.
                    action: .idle,
                    size: metrics.spriteDiameter
                )
                .scaleEffect(progressState == .working && pulse && !reduceMotion ? 1.055 : 1)
            } else {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: metrics.isCompact ? 20 : 25, weight: .bold))
                    .foregroundStyle(accent.opacity(0.88))
                    .scaleEffect(progressState == .working && pulse && !reduceMotion ? 1.055 : 1)
            }
        }
        .frame(width: metrics.portraitDiameter, height: metrics.portraitDiameter)
        .shadow(
            color: progressColor.opacity(progressState == .working ? (pulse ? 0.72 : 0.34) : 0.22),
            radius: progressState == .working ? (pulse ? 15 : 7) : 5
        )
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(progressColor)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.black.opacity(0.8), lineWidth: 2))
                .shadow(color: progressColor.opacity(0.85), radius: progressState == .working ? 6 : 2)
        }
        .animation(.easeInOut(duration: 1.25), value: pulse)
        .accessibilityLabel("\(project.displayName) avatar, \(progressState.label.lowercased())")
    }

    @ViewBuilder
    private func codexPill(compact: Bool) -> some View {
        let content = HStack(spacing: compact ? 5 : 7) {
            CoFleetProgressCodexMark()
                .frame(width: compact ? 15 : 22, height: compact ? 15 : 22)
            Text("Codex")
                .font(.system(size: compact ? 12 : 16, weight: .bold, design: .rounded))
            Text("·")
                .foregroundStyle(providerActivityColor.opacity(0.62))
            Text(providerActivityLabel)
                .font(.system(size: compact ? 12 : 16, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            if providerActivityShowsProgress {
                ProgressView()
                    .controlSize(.mini)
                    .tint(providerActivityColor)
            }
        }
        .foregroundStyle(providerActivityColor)
        .padding(.horizontal, compact ? 7 : 12)
        .padding(.vertical, compact ? 4 : 6)
        .background(providerActivityColor.opacity(0.11), in: Capsule())
        .overlay { Capsule().stroke(providerActivityColor.opacity(0.24), lineWidth: 1) }
        .contentShape(Capsule())

        if let localThreadURL {
            Link(destination: localThreadURL) { content }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cofleetCardSelectionExclusion(in: selectionCoordinateSpace)
                .help("Open this task in Codex")
                .accessibilityLabel("Codex, \(providerActivityLabel)")
        } else {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Codex, \(providerActivityLabel)")
        }
    }

    private var composer: some View {
        let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSubmit = hasDraft && !isSending
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(project.displayName)…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .lineLimit(1...3)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.14)))
                .onSubmit(onSend)

            Button(action: onSend) {
                Group {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color(red: 0.02, green: 0.08, blue: 0.13))
                    } else {
                        Image(systemName: "arrow.up")
                            .fontWeight(.black)
                    }
                }
                .frame(width: 34, height: 34)
                .foregroundStyle(Color(red: 0.02, green: 0.08, blue: 0.13))
                .background(accent.opacity(canSubmit ? 1 : 0.34), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .help("Send to \(project.displayName)")
            .accessibilityLabel("Send message")
        }
        .padding(.top, 2)
        .cofleetCardSelectionExclusion(in: selectionCoordinateSpace)
    }

    private var selectionCoordinateSpace: String {
        "cofleet.progress.card.\(project.hostID.rawValue).\(project.id)"
    }

    private var accent: Color { CoFleetTheme.violet }

    private var progressState: ProgressState {
        switch project.state {
        case .waitingForApproval, .waitingForAnswer: return .attention
        case .working: return .working
        case .idle, .replied, .unavailable: break
        }
        switch host?.reachability ?? .unknown {
        case .offline: return .offline
        case .unknown: return .checking
        case .degraded: return .offline
        case .online: break
        }
        switch project.state {
        case .idle, .replied: return .idle
        case .unavailable: return .offline
        case .working, .waitingForApproval, .waitingForAnswer: return .idle
        }
    }

    private var progressColor: Color {
        switch progressState {
        case .working: accent
        case .attention: CoFleetTheme.danger
        case .idle: CoFleetTheme.green
        case .offline: CoFleetTheme.orange
        case .checking: .gray
        }
    }

    private var providerActivityLabel: String {
        CoFleetProgressProviderBadgePolicy.activityLabel(
            activity: activity,
            projectState: project.state,
            reachability: host?.reachability ?? .unknown
        )
    }

    private var providerActivityColor: Color {
        switch host?.reachability ?? .unknown {
        case .offline, .degraded:
            return CoFleetTheme.orange
        case .unknown:
            return .gray
        case .online:
            break
        }

        if let activity {
            switch activity {
            case .approval, .question: return CoFleetTheme.danger
            case .thinking, .reasoning, .runningCommand: return accent
            case .idle, .replied: return CoFleetTheme.green
            }
        }
        return progressColor
    }

    private var providerActivityShowsProgress: Bool {
        guard host?.reachability == .online else { return false }
        switch activity {
        case .thinking, .reasoning, .runningCommand:
            return true
        case .idle, .approval, .question, .replied, .none:
            return activity == nil && project.state == .working
        }
    }

    private enum ProgressState: Equatable {
        case working
        case attention
        case idle
        case offline
        case checking

        var label: String {
            switch self {
            case .working: "WORKING"
            case .attention: "NEEDS ATTENTION"
            case .idle: "IDLE"
            case .offline: "OFFLINE"
            case .checking: "CHECKING"
            }
        }

        var needsAttention: Bool { self == .attention }
    }
}

private struct CoFleetCardSelectionExclusionKey: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    func cofleetCardSelectionExclusion(in coordinateSpace: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CoFleetCardSelectionExclusionKey.self,
                    value: [proxy.frame(in: .named(coordinateSpace))]
                )
            }
        }
    }
}

struct CoFleetProgressMessagePreview: View {
    let item: CoFleetTurnItem
    var agentName = "Codex"
    var accent = CoFleetTheme.violet
    var compact = false

    private var isUser: Bool { item.kind == .userMessage }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: compact ? 10 : 22) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(isUser ? "YOU" : agentName.uppercased())
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(isUser ? accent : .secondary)
                    Text(item.createdAt, style: .time)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(previewText)
                    .font(.system(size: compact ? 11.5 : 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.9))
                    .multilineTextAlignment(isUser ? .trailing : .leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            }
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 6 : 7)
            .background(
                isUser ? accent.opacity(0.12) : Color.white.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isUser ? accent.opacity(0.18) : Color.white.opacity(0.07))
            }

            if !isUser { Spacer(minLength: compact ? 10 : 22) }
        }
    }

    private var previewText: String {
        item.text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

private struct CoFleetProgressCodexMark: View {
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            CodexKnotShape()
                .stroke(
                    .foreground,
                    style: StrokeStyle(
                        lineWidth: max(0.7, side * 0.13),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: side, height: side)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private struct CodexKnotShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height)

            func point(radius normalizedRadius: CGFloat, angle: CGFloat) -> CGPoint {
                CGPoint(
                    x: center.x + cos(angle) * radius * normalizedRadius,
                    y: center.y + sin(angle) * radius * normalizedRadius
                )
            }

            for index in 0..<6 {
                let angle = CGFloat(index) * .pi / 3 - .pi / 2
                path.move(to: point(radius: 0.14, angle: angle - .pi / 7))
                path.addCurve(
                    to: point(radius: 0.25, angle: angle + .pi / 3),
                    control1: point(radius: 0.38, angle: angle - .pi / 12),
                    control2: point(radius: 0.43, angle: angle + .pi / 5)
                )
            }
            return path
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
