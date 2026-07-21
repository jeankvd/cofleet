import CoFleetCore
import SwiftUI

#if !os(watchOS)
public enum CoFleetNavigationPlatform: Sendable {
    case macOS
    case mobile
}

public enum CoFleetDestination: String, CaseIterable, Identifiable, Sendable {
    case progress = "Progress"
    case dashboard = "Dashboard"
    case agentBay = "Agent Bay"
    case active = "Active"
    case battle = "Battle"

    public var id: String { rawValue }

    public var symbol: String {
        symbol(for: Self.currentPlatform)
    }

    public static var navigationOrder: [Self] {
        navigationOrder(for: currentPlatform)
    }

    public static var defaultDestination: Self {
        defaultDestination(for: currentPlatform)
    }

    public static func navigationOrder(for platform: CoFleetNavigationPlatform) -> [Self] {
        switch platform {
        case .macOS:
            [.progress, .dashboard, .agentBay, .battle]
        case .mobile:
            [.dashboard, .progress, .agentBay, .battle]
        }
    }

    public static func defaultDestination(for platform: CoFleetNavigationPlatform) -> Self {
        switch platform {
        case .macOS: .progress
        case .mobile: .dashboard
        }
    }

    public func symbol(for platform: CoFleetNavigationPlatform) -> String {
        switch self {
        case .progress: "chart.bar.xaxis"
        case .dashboard: "rectangle.3.group"
        case .agentBay: platform == .macOS ? "sparkles" : "person.3.sequence"
        case .active: "bolt.horizontal.circle"
        case .battle: "shield.lefthalf.filled"
        }
    }

    private static var currentPlatform: CoFleetNavigationPlatform {
        #if os(macOS)
        .macOS
        #else
        .mobile
        #endif
    }
}

public struct CoFleetRootView: View {
    @Bindable private var fleetStore: FleetStore
    @Bindable private var threadStore: ThreadStore
    @Bindable private var turnStore: TurnStore
    @Bindable private var workspaceStore: WorkspaceStore
    private let models: [CoFleetModelInfo]
    private let localHostID: CoFleetHostID?
    private let pairAction: CoFleetOnboardingView.PairAction

    @State private var destination = CoFleetDestination.defaultDestination
    @State private var settings = CoFleetSessionSettings()
    @State private var showsLegal = false
    @State private var isReconcilingPetHatch = false
    @State private var petHatchNotice: String?
    @State private var showsBattleWorkspace = false
    @State private var battleWorkspaceProjectID: String?
    @AppStorage("cofleet.onboarding.setupInProgress") private var setupInProgress = false
    @AppStorage("cofleet.onboarding.setupCompleted") private var setupCompleted = false
    @AppStorage(CoFleetPendingPetHatch.storageIdentifier) private var pendingPetHatchPayload = ""

    public init(
        fleetStore: FleetStore,
        threadStore: ThreadStore,
        turnStore: TurnStore,
        workspaceStore: WorkspaceStore,
        models: [CoFleetModelInfo] = [],
        localHostID: CoFleetHostID? = nil,
        pairAction: @escaping CoFleetOnboardingView.PairAction
    ) {
        self.fleetStore = fleetStore
        self.threadStore = threadStore
        self.turnStore = turnStore
        self.workspaceStore = workspaceStore
        self.models = models
        self.localHostID = localHostID
        self.pairAction = pairAction
    }

    public var body: some View {
        Group {
            if fleetStore.hosts.isEmpty && !fleetStore.isLoading {
                CoFleetOnboardingView(pair: pairAction) { _ in
                    Task { await fleetStore.refresh() }
                }
            } else if shouldShowFirstRun {
                CoFleetFirstRunView(
                    fleetStore: fleetStore,
                    workspaceStore: workspaceStore
                ) {
                    setupCompleted = true
                    setupInProgress = false
                }
                .onAppear { setupInProgress = true }
            } else {
                #if os(macOS)
                desktopContent
                #else
                mobileContent
                #endif
            }
        }
        .tint(CoFleetTheme.cyan)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("cofleet.root")
        .sheet(isPresented: $showsLegal) {
            NavigationStack { CoFleetLegalView() }
        }
        .sheet(isPresented: $showsBattleWorkspace) {
            if let project = battleWorkspaceProject {
                CoFleetWorkspaceView(
                    workspaceStore: workspaceStore,
                    projectName: project.displayName
                )
            }
        }
        .alert("Pet Hatch", isPresented: petHatchNoticeIsPresented) {
            Button("OK", role: .cancel) { petHatchNotice = nil }
        } message: {
            Text(petHatchNotice ?? "The pet hatch was updated.")
        }
        .onChange(of: threadStore.selectedSessionID) { _, _ in
            syncSettingsFromSelectedSession()
        }
        .onChange(of: fleetStore.selectedProjectID) { _, projectID in
            guard let projectID else {
                settings = CoFleetSessionSettings()
                return
            }
            let project = fleetStore.projects.first { $0.id == projectID }
            let projectSessions = threadStore.sessionsByProjectID[projectID] ?? []
            let selectedForProject = threadStore.selectedSessionID.flatMap { selectedID in
                projectSessions.first { $0.id == selectedID }
            }
            let matchingCurrent = project?.currentSessionID.flatMap { currentID in
                projectSessions.first { $0.id == currentID }
            }
            settings = selectedForProject?.settings
                ?? matchingCurrent?.settings
                ?? CoFleetSessionSettings()
        }
        .onChange(of: turnStore.activeTurn?.id) { _, activeTurnID in
            guard activeTurnID == nil else { return }
            Task { await reconcilePendingPetHatch() }
        }
        .onChange(of: turnStore.loadedSessionID) { _, _ in
            Task { await reconcilePendingPetHatch() }
        }
        .onChange(of: turnStore.items.count) { _, _ in
            Task { await reconcilePendingPetHatch() }
        }
    }

    private var shouldShowFirstRun: Bool {
        !fleetStore.hosts.isEmpty
            && (setupInProgress || (!setupCompleted && fleetStore.projects.isEmpty))
    }

    #if os(macOS)
    private var desktopContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("Section", selection: $destination) {
                    ForEach(CoFleetDestination.navigationOrder) { item in
                        Label(item.rawValue, systemImage: item.symbol)
                            .tag(item)
                            .accessibilityIdentifier(item == .progress ? "cofleet.destination.progress" : "cofleet.destination.\(item.id)")
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 560)

                Spacer()
                Button { showsLegal = true } label: {
                    Label("Legal", systemImage: "info.circle")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Legal")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)

            Divider()

            destinationView
        }
    }
    #endif

    private var mobileContent: some View {
        TabView(selection: $destination) {
            ForEach(CoFleetDestination.navigationOrder) { item in
                NavigationStack {
                    if item == .progress {
                        progressView { projectID in
                            fleetStore.selectedProjectID = projectID
                            destination = .agentBay
                        }
                    } else {
                        destinationView(for: item)
                    }
                }
                .tabItem { Label(item.rawValue, systemImage: item.symbol) }
                .tag(item)
                .accessibilityIdentifier(item == .progress ? "cofleet.destination.progress" : "cofleet.destination.\(item.id)")
            }
        }
    }

    @ViewBuilder
    private var destinationView: some View {
        destinationView(for: destination)
    }

    @ViewBuilder
    private func destinationView(for destination: CoFleetDestination) -> some View {
        switch destination {
        case .progress:
            progressView { projectID in
                fleetStore.selectedProjectID = projectID
                self.destination = .agentBay
            }
        case .dashboard:
            CoFleetDashboardView(
                fleetStore: fleetStore,
                threadStore: threadStore,
                turnStore: turnStore,
                pairAction: pairAction
            )
        case .agentBay:
            agentBayView
        case .active:
            CoFleetActiveView(
                fleetStore: fleetStore,
                threadStore: threadStore,
                turnStore: turnStore,
                workspaceStore: workspaceStore,
                settings: $settings,
                models: models,
                localHostID: localHostID,
                isVisible: self.destination == .active,
                onHatchPet: beginPetHatch
            )
        case .battle:
            battleDestinationView
        }
    }

    @ViewBuilder
    private var battleDestinationView: some View {
        let readiness = CoFleetBattleOnboardingPolicy.readiness(
            projects: fleetStore.visibleProjects,
            preferredProjectID: fleetStore.selectedProjectID,
            todosByProjectID: workspaceStore.battleTodosByProjectID
        )

        Group {
            switch readiness {
            case let .ready(projectID):
                CoFleetBattleView(
                    projects: battleProjects(startingWith: projectID),
                    hosts: fleetStore.hosts,
                    petManifests: workspaceStore.battlePetManifestsByProjectID,
                    petAssets: workspaceStore.battlePetAssetsByProjectID,
                    todosByProjectID: workspaceStore.battleTodosByProjectID,
                    onToggleTodo: { projectID, todoID in
                        Task {
                            await workspaceStore.toggleBattleTodo(
                                projectID: projectID,
                                todoID: todoID
                            )
                        }
                    }
                )
            case .noProject, .loading, .needsTodos:
                CoFleetBattleOnboardingView(
                    readiness: readiness,
                    onAddProject: { destination = .progress },
                    onAddTodos: { projectID in
                        Task { await openBattleWorkspace(for: projectID) }
                    }
                )
            }
        }
        .task(id: "\(visibleProjectsIdentity):\(self.destination == .battle)") {
            guard self.destination == .battle else { return }
            async let pets: Void = workspaceStore.loadBattlePets(for: fleetStore.visibleProjects)
            async let todos: Void = workspaceStore.loadBattleTodos(for: fleetStore.visibleProjects)
            _ = await (pets, todos)
        }
    }

    private func progressView(
        onOpenProject: @escaping (String) -> Void
    ) -> some View {
        CoFleetProgressView(
            fleetStore: fleetStore,
            threadStore: threadStore,
            turnStore: turnStore,
            workspaceStore: workspaceStore,
            settings: $settings,
            localHostID: localHostID,
            isVisible: self.destination == .progress,
            onOpenProject: onOpenProject,
            onHatchPet: beginPetHatch
        )
    }

    private var agentBayView: some View {
        CoFleetAgentBayView(
            threadStore: threadStore,
            turnStore: turnStore,
            settings: $settings,
            models: models,
            fleetStore: fleetStore,
            workspaceStore: workspaceStore,
            localHostID: localHostID,
            onHatchPet: beginPetHatch
        )
    }

    private var visibleProjectsIdentity: String {
        fleetStore.visibleProjects
            .map { "\($0.hostID.rawValue):\($0.id):\($0.selectedPetID ?? "")" }
            .joined(separator: "|")
    }

    private var battleWorkspaceProject: CoFleetProject? {
        guard let battleWorkspaceProjectID else { return nil }
        return fleetStore.projects.first { $0.id == battleWorkspaceProjectID }
    }

    private func battleProjects(startingWith projectID: String) -> [CoFleetProject] {
        guard let project = fleetStore.visibleProjects.first(where: { $0.id == projectID }) else {
            return fleetStore.visibleProjects
        }
        return [project] + fleetStore.visibleProjects.filter { $0.id != projectID }
    }

    private func openBattleWorkspace(for projectID: String) async {
        guard let project = fleetStore.projects.first(where: { $0.id == projectID }) else { return }
        let hostIsOnline = fleetStore.hosts.first(where: { $0.id == project.hostID })?.reachability == .online
        fleetStore.selectedProjectID = project.id
        battleWorkspaceProjectID = project.id
        await workspaceStore.open(
            hostID: project.hostID,
            projectID: project.id,
            isHostOnline: hostIsOnline,
            selectedPetID: project.selectedPetID
        )
        showsBattleWorkspace = true
    }

    private var petHatchNoticeIsPresented: Binding<Bool> {
        Binding(
            get: { petHatchNotice != nil },
            set: { if !$0 { petHatchNotice = nil } }
        )
    }

    private func beginPetHatch(for project: CoFleetProject) async throws {
        guard let host = fleetStore.hosts.first(where: { $0.id == project.hostID }) else {
            throw CoFleetClientError.unavailable("This project’s host is no longer paired.")
        }
        guard host.reachability == .online else {
            throw CoFleetClientError.unavailable("\(host.displayName) must be online to hatch and import a pet.")
        }
        guard host.capabilities.canImportPets else {
            throw CoFleetClientError.incompatible("Update cofleet-host on \(host.displayName) to hatch and import pets.")
        }

        fleetStore.selectedProjectID = project.id
        if threadStore.loadedHostID != project.hostID || threadStore.loadedProjectID != project.id {
            await threadStore.loadInitial(hostID: project.hostID, projectID: project.id)
        }
        guard threadStore.loadedHostID == project.hostID,
              threadStore.loadedProjectID == project.id else {
            throw CoFleetClientError.unavailable("CoFleet couldn’t open \(project.displayName) on \(host.displayName).")
        }

        if workspaceStore.loadedHostID != project.hostID
            || workspaceStore.loadedProjectID != project.id {
            await workspaceStore.open(
                hostID: project.hostID,
                projectID: project.id,
                sessionID: threadStore.selectedSessionID,
                isHostOnline: true,
                selectedPetID: project.selectedPetID
            )
        }
        try await workspaceStore.discoverPets()
        let baseline = Set(workspaceStore.discoveredPets.map(\.digest))
        let session = try await threadStore.createSession(settings: settings)

        await turnStore.open(
            hostID: project.hostID,
            projectID: project.id,
            sessionID: session.id
        )
        if let routeError = turnStore.errorMessage {
            throw CoFleetClientError.unavailable(routeError)
        }

        let hatch = CoFleetPendingPetHatch(
            hostID: project.hostID,
            projectID: project.id,
            sessionID: session.id,
            baselineDigests: baseline
        )
        savePendingPetHatch(hatch)
        turnStore.draft = CoFleetPendingPetHatch.codexPrompt
        do {
            _ = try await turnStore.send(settings: settings)
        } catch {
            savePendingPetHatch(nil)
            throw error
        }

        destination = .agentBay
        threadStore.updateLoadedProjectPreview(items: turnStore.items)
    }

    private func reconcilePendingPetHatch() async {
        guard !isReconcilingPetHatch,
              let hatch = loadPendingPetHatch(),
              turnStore.loadedHostID == hatch.hostID,
              turnStore.loadedProjectID == hatch.projectID,
              turnStore.loadedSessionID == hatch.sessionID,
              workspaceStore.loadedHostID == hatch.hostID,
              workspaceStore.loadedProjectID == hatch.projectID,
              workspaceStore.isHostOnline else { return }
        let readyPath = hatch.readyPackagePath(in: turnStore.items)
        guard turnStore.activeTurn == nil || readyPath != nil else { return }

        isReconcilingPetHatch = true
        defer { isReconcilingPetHatch = false }
        do {
            try await workspaceStore.discoverPets()
            let candidates = hatch.newlyDiscoveredPets(in: workspaceStore.discoveredPets)
            guard let package = matchingHatchedPet(
                candidates: candidates,
                readyPath: readyPath
            ) else { return }
            guard let imported = try await workspaceStore.importPet(sourcePath: package.sourcePath),
                  let updated = try await workspaceStore.selectPet(id: imported.id) else { return }

            fleetStore.applyProjectUpdate(updated)
            await workspaceStore.loadBattlePets(for: [updated])
            savePendingPetHatch(nil)
            petHatchNotice = "\(imported.displayName) was validated, imported, and selected for \(updated.displayName)."
        } catch {
            // Keep the durable handoff so a retry after reconnect can still import
            // the completed package instead of losing the result of a long hatch.
            petHatchNotice = "The Codex pet task is saved, but CoFleet couldn’t import it yet: \(error.localizedDescription)"
        }
    }

    private func matchingHatchedPet(
        candidates: [CoFleetDiscoveredPet],
        readyPath: String?
    ) -> CoFleetDiscoveredPet? {
        if let readyPath {
            let normalizedReadyPath = normalizedPetPackagePath(readyPath)
            if let exact = candidates.first(where: {
                normalizedPetPackagePath($0.sourcePath) == normalizedReadyPath
            }) {
                return exact
            }
        }
        // A normal hatch creates exactly one package. Refuse to guess if another
        // process created multiple pets on the same host during the conversation.
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func normalizedPetPackagePath(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("/pet.json") { value.removeLast("/pet.json".count) }
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private func loadPendingPetHatch() -> CoFleetPendingPetHatch? {
        guard let data = pendingPetHatchPayload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CoFleetPendingPetHatch.self, from: data)
    }

    private func savePendingPetHatch(_ hatch: CoFleetPendingPetHatch?) {
        guard let hatch else {
            pendingPetHatchPayload = ""
            return
        }
        guard let data = try? JSONEncoder().encode(hatch),
              let payload = String(data: data, encoding: .utf8) else { return }
        pendingPetHatchPayload = payload
    }

    private func syncSettingsFromSelectedSession() {
        guard let project = fleetStore.selectedProject,
              threadStore.loadedHostID == project.hostID,
              threadStore.loadedProjectID == project.id,
              let selectedSessionID = threadStore.selectedSessionID,
              let selectedSession = threadStore.sessions.first(where: {
                  $0.id == selectedSessionID
                      && $0.hostID == project.hostID
                      && $0.projectID == project.id
              }) else {
            settings = CoFleetSessionSettings()
            return
        }
        settings = selectedSession.settings
    }
}
#endif
