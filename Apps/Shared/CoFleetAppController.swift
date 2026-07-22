import CoFleetCore
import CoFleetUI
import Foundation
import Observation
import SwiftUI

#if !os(watchOS)
@MainActor
@Observable
public final class CoFleetAppController {
    public let repository: CoFleetAppRepository
    public let fleetStore: FleetStore
    public let threadStore: ThreadStore
    public let turnStore: TurnStore
    public let workspaceStore: WorkspaceStore
    public private(set) var models: [CoFleetModelInfo] = []
    public private(set) var localHostID: CoFleetHostID?

    @ObservationIgnored private var routingTask: Task<Void, Never>?
    @ObservationIgnored private var routingGeneration: UInt = 0
    @ObservationIgnored private var requestedProjectID: String?
    @ObservationIgnored private var requestedSessionRoute: SessionRoute?
    @ObservationIgnored private var catalogLoadingProjectID: String?
    @ObservationIgnored private var hostEventTasks: [CoFleetHostID: Task<Void, Never>] = [:]
    @ObservationIgnored private var hostEventCursors: [CoFleetHostID: String] = [:]
    @ObservationIgnored private var catalogReconciliationTasks: [HostProjectRoute: Task<Void, Never>] = [:]
    @ObservationIgnored private var catalogReconciliationGenerations: [HostProjectRoute: UUID] = [:]
    @ObservationIgnored private var desktopIdlePendingRoutes: Set<HostProjectRoute> = []

    public init(
        repository: CoFleetAppRepository? = nil,
        threadSnapshotStorage: (any CoFleetThreadSnapshotStorage)? = nil
    ) {
        let resolvedRepository = repository ?? Self.defaultRepository()
        let resolvedThreadSnapshotStorage: any CoFleetThreadSnapshotStorage = threadSnapshotStorage
            ?? (repository == nil
                ? Self.defaultThreadSnapshotStorage()
                : CoFleetInMemoryThreadSnapshotStorage())
        self.repository = resolvedRepository
        fleetStore = FleetStore(repository: resolvedRepository)
        threadStore = ThreadStore(
            repository: resolvedRepository,
            previewRepository: resolvedRepository,
            snapshotStorage: resolvedThreadSnapshotStorage
        )
        turnStore = TurnStore(repository: resolvedRepository)
        workspaceStore = WorkspaceStore(repository: resolvedRepository)
    }

    deinit {
        routingTask?.cancel()
        for task in hostEventTasks.values { task.cancel() }
        for task in catalogReconciliationTasks.values { task.cancel() }
    }

    public func start() async {
        await fleetStore.refresh()
        guard !Task.isCancelled else { return }
        synchronizeHostEventStreams()
        selectedProjectDidChange()
        localHostID = await repository.localHostID()
        guard !Task.isCancelled else { return }
        await fleetStore.refreshAccountState()
        guard !Task.isCancelled else { return }
        await threadStore.refreshLatestSessionPreviews(for: fleetStore.visibleProjects)
    }

    public func pair(_ input: CoFleetPairingInput) async throws -> CoFleetHostInfo {
        let host = try await repository.pair(
            CoFleetPairingInputValue(endpoint: input.endpoint, code: input.code, deviceName: input.deviceName)
        )
        await fleetStore.refresh()
        guard !Task.isCancelled else { return host }
        synchronizeHostEventStreams()
        selectedProjectDidChange()
        localHostID = await repository.localHostID()
        guard !Task.isCancelled else { return host }
        await fleetStore.refreshAccountState()
        return host
    }

    public func selectedProjectDidChange() {
        guard let project = fleetStore.selectedProject,
              project.id == fleetStore.selectedProjectID else {
            guard requestedProjectID != nil || routingTask != nil else { return }
            cancelRouting()
            requestedProjectID = nil
            requestedSessionRoute = nil
            catalogLoadingProjectID = nil
            models = []
            turnStore.close()
            return
        }

        guard requestedProjectID != project.id else { return }
        requestedProjectID = project.id
        requestedSessionRoute = nil
        catalogLoadingProjectID = project.id
        turnStore.close()
        scheduleRouting { [weak self] generation in
            await self?.loadProject(project, generation: generation)
        }
    }

    public func selectedSessionDidChange() {
        guard catalogLoadingProjectID == nil,
              let project = fleetStore.selectedProject,
              project.id == fleetStore.selectedProjectID,
              threadStore.loadedHostID == project.hostID,
              threadStore.loadedProjectID == project.id else { return }

        let route = SessionRoute(projectID: project.id, sessionID: threadStore.selectedSessionID)
        guard requestedSessionRoute != route else { return }
        requestedSessionRoute = route
        scheduleRouting { [weak self] generation in
            await self?.loadSession(
                project: project,
                sessionID: route.sessionID,
                generation: generation
            )
        }
    }

    /// Maintains exactly one reconnecting global event stream for every paired
    /// host. Calling this repeatedly is cheap and only changes added/removed IDs.
    public func synchronizeHostEventStreams() {
        let desired = Set(fleetStore.hosts.map(\.id))
        let removedHostIDs = hostEventTasks.keys.filter { !desired.contains($0) }
        for hostID in removedHostIDs {
            hostEventTasks[hostID]?.cancel()
            hostEventTasks[hostID] = nil
            hostEventCursors[hostID] = nil
            let removedRoutes = catalogReconciliationTasks.keys.filter { $0.hostID == hostID }
            for route in removedRoutes {
                catalogReconciliationTasks[route]?.cancel()
                catalogReconciliationTasks[route] = nil
                catalogReconciliationGenerations[route] = nil
                desktopIdlePendingRoutes.remove(route)
            }
        }
        for hostID in desired where hostEventTasks[hostID] == nil {
            hostEventTasks[hostID] = Task { [weak self] in
                await self?.runHostEventStream(hostID: hostID)
            }
        }
    }

    private func loadProject(_ project: CoFleetProject, generation: UInt) async {
        guard isCurrentProjectRoute(project, generation: generation) else { return }
        let loadedModels = await repository.fetchModels(hostID: project.hostID)
        guard isCurrentProjectRoute(project, generation: generation) else { return }
        models = loadedModels

        await threadStore.loadInitial(hostID: project.hostID, projectID: project.id)
        guard isCurrentProjectRoute(project, generation: generation),
              threadStore.loadedHostID == project.hostID,
              threadStore.loadedProjectID == project.id else { return }

        let sessionID = threadStore.selectedSessionID
        requestedSessionRoute = SessionRoute(projectID: project.id, sessionID: sessionID)
        catalogLoadingProjectID = nil
        await loadSession(project: project, sessionID: sessionID, generation: generation)
    }

    private func loadSession(
        project: CoFleetProject,
        sessionID: String?,
        generation: UInt
    ) async {
        let expectedRoute = SessionRoute(projectID: project.id, sessionID: sessionID)
        guard isCurrentSessionRoute(project, route: expectedRoute, generation: generation) else { return }
        let hostIsOnline = fleetStore.hosts.first { $0.id == project.hostID }?.reachability == .online
        guard let sessionID else {
            turnStore.close()
            await workspaceStore.open(
                hostID: project.hostID,
                projectID: project.id,
                sessionID: nil,
                isHostOnline: hostIsOnline,
                selectedPetID: project.selectedPetID
            )
            return
        }

        async let workspace: Void = workspaceStore.open(
            hostID: project.hostID,
            projectID: project.id,
            sessionID: sessionID,
            isHostOnline: hostIsOnline,
            selectedPetID: project.selectedPetID
        )
        await turnStore.open(hostID: project.hostID, projectID: project.id, sessionID: sessionID)
        guard isCurrentSessionRoute(project, route: expectedRoute, generation: generation),
              turnStore.loadedHostID == project.hostID,
              turnStore.loadedProjectID == project.id,
              turnStore.loadedSessionID == sessionID else {
            await workspace
            return
        }
        threadStore.updateLoadedProjectPreview(items: turnStore.items)
        await workspace
    }

    private func scheduleRouting(
        operation: @escaping @MainActor (UInt) async -> Void
    ) {
        routingGeneration &+= 1
        let generation = routingGeneration
        routingTask?.cancel()
        routingTask = Task { [weak self] in
            await operation(generation)
            guard let self, self.routingGeneration == generation else { return }
            self.routingTask = nil
        }
    }

    private func runHostEventStream(hostID: CoFleetHostID) async {
        var backoff = CoFleetHostEventReconnectBackoff()
        var serverRetryMilliseconds: Int?
        while !Task.isCancelled {
            do {
                let stream = try await repository.hostEvents(
                    hostID: hostID,
                    afterEventID: hostEventCursors[hostID]
                )
                var receivedEvent = false
                for try await sequenced in stream {
                    try Task.checkCancellation()
                    if !receivedEvent {
                        receivedEvent = true
                        backoff.reset()
                    }
                    if let id = sequenced.id { hostEventCursors[hostID] = id }
                    if let retry = sequenced.retryMilliseconds { serverRetryMilliseconds = retry }
                    consumeHostEvent(
                        sequenced.event,
                        hostID: hostID,
                        isReplay: sequenced.isReplay
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                // Reachability is already represented by FleetStore. The stream
                // reconnects silently and replays from its last acknowledged ID.
            }
            guard !Task.isCancelled else { return }
            let delay = backoff.nextDelay(
                serverRetryMilliseconds: serverRetryMilliseconds,
                jitter: Double.random(in: 0.85...1.15)
            )
            try? await Task.sleep(for: delay)
        }
    }

    private func consumeHostEvent(
        _ event: CoFleetHostEvent,
        hostID: CoFleetHostID,
        isReplay: Bool
    ) {
        switch event {
        case let .sessionCatalogUpdated(update):
            guard update.hostID == hostID,
                  let project = fleetStore.projects.first(where: {
                      $0.id == update.projectID && $0.hostID == hostID
                  }) else { return }
            let previousCurrentSessionID = project.currentSessionID
            fleetStore.setCurrentSessionID(
                update.currentSessionID,
                projectID: project.id,
                hostID: hostID
            )
            scheduleCatalogReconciliation(
                projectID: project.id,
                hostID: hostID,
                previousCurrentSessionID: previousCurrentSessionID,
                currentSessionID: update.currentSessionID
            )
        case .resetRequired:
            for project in fleetStore.projects where project.hostID == hostID {
                scheduleCatalogReconciliation(
                    projectID: project.id,
                    hostID: hostID,
                    previousCurrentSessionID: project.currentSessionID,
                    currentSessionID: project.currentSessionID
                )
            }
        case .checkpoint:
            break
        default:
            guard let projectID = resolveProjectID(for: event, hostID: hostID),
                  let project = fleetStore.projects.first(where: {
                      $0.id == projectID && $0.hostID == hostID
                  }) else { return }
            let route = HostProjectRoute(hostID: hostID, projectID: projectID)
            if case let .activityChanged(update) = event,
               update.source == .codexDesktop {
                if update.state == .idle {
                    desktopIdlePendingRoutes.insert(route)
                    scheduleCatalogReconciliation(
                        projectID: projectID,
                        hostID: hostID,
                        previousCurrentSessionID: project.currentSessionID,
                        currentSessionID: update.sessionID ?? project.currentSessionID
                    )
                } else {
                    desktopIdlePendingRoutes.remove(route)
                }
            }
            fleetStore.applyHostEvent(event, to: projectID)
            switch event {
            case let .turnUpdated(_, turn):
                threadStore.applyLiveTurn(hostID: hostID, projectID: projectID, turn: turn)
            case let .turnItem(_, sessionID, item):
                // A reconnect can replay many historical partial deltas in a
                // fraction of a second. Ignore those partial snapshots; the
                // completed item (or catalog reconciliation) supplies the full
                // answer atomically. New events still stream normally.
                guard item.state != .streaming || !isReplay else { break }
                let activitySessionID = fleetStore.activity(for: projectID)?.sessionID
                threadStore.applyLiveItem(
                    hostID: hostID,
                    projectID: projectID,
                    sessionID: sessionID,
                    item: item,
                    isCurrentSession: project.currentSessionID == nil
                        || project.currentSessionID == sessionID
                        || activitySessionID == sessionID
                )
                if item.kind == .assistantMessage, item.state == .completed {
                    desktopIdlePendingRoutes.remove(route)
                }
            default:
                break
            }
        }
    }

    private func resolveProjectID(
        for event: CoFleetHostEvent,
        hostID: CoFleetHostID
    ) -> String? {
        if let projectID = event.explicitProjectID,
           fleetStore.projects.contains(where: { $0.id == projectID && $0.hostID == hostID }) {
            return projectID
        }
        guard let sessionID = event.sessionID else { return nil }
        return fleetStore.projects.first(where: {
            $0.hostID == hostID && $0.currentSessionID == sessionID
        })?.id ?? threadStore.projectID(hostID: hostID, sessionID: sessionID)
    }

    private func scheduleCatalogReconciliation(
        projectID: String,
        hostID: CoFleetHostID,
        previousCurrentSessionID: String?,
        currentSessionID: String?
    ) {
        let route = HostProjectRoute(hostID: hostID, projectID: projectID)
        catalogReconciliationTasks[route]?.cancel()
        let generation = UUID()
        catalogReconciliationGenerations[route] = generation
        catalogReconciliationTasks[route] = Task { [weak self] in
            // Coalesce a replay burst while remaining imperceptible for a live event.
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled,
                  let self,
                  let project = self.fleetStore.projects.first(where: {
                      $0.id == projectID && $0.hostID == hostID
                  }) else { return }
            let didReceiveReply = await self.threadStore.reconcileLatestSessionPreview(
                for: project,
                previousCurrentSessionID: previousCurrentSessionID,
                currentSessionID: currentSessionID
            )
            guard !Task.isCancelled else { return }
            let activity = self.fleetStore.activity(for: projectID)
            if didReceiveReply {
                self.desktopIdlePendingRoutes.remove(route)
                self.fleetStore.setProjectActivity(
                    .replied,
                    projectID: projectID,
                    sessionID: currentSessionID,
                    source: activity?.source ?? .unknown
                )
            } else if self.desktopIdlePendingRoutes.contains(route),
                      activity?.source == .codexDesktop,
                      activity?.activity == .thinking
                        || activity?.activity == .reasoning
                        || activity?.activity == .runningCommand {
                self.desktopIdlePendingRoutes.remove(route)
                self.fleetStore.setProjectActivity(
                    .idle,
                    projectID: projectID,
                    sessionID: currentSessionID,
                    source: .codexDesktop
                )
            }
            if self.catalogReconciliationGenerations[route] == generation {
                self.catalogReconciliationTasks[route] = nil
                self.catalogReconciliationGenerations[route] = nil
            }
        }
    }

    private func cancelRouting() {
        routingGeneration &+= 1
        routingTask?.cancel()
        routingTask = nil
    }

    private func isCurrentProjectRoute(_ project: CoFleetProject, generation: UInt) -> Bool {
        !Task.isCancelled
            && routingGeneration == generation
            && requestedProjectID == project.id
            && fleetStore.selectedProjectID == project.id
            && fleetStore.projects.contains { $0.id == project.id && $0.hostID == project.hostID }
    }

    private func isCurrentSessionRoute(
        _ project: CoFleetProject,
        route: SessionRoute,
        generation: UInt
    ) -> Bool {
        isCurrentProjectRoute(project, generation: generation)
            && requestedSessionRoute == route
            && threadStore.loadedHostID == project.hostID
            && threadStore.loadedProjectID == project.id
            && threadStore.selectedSessionID == route.sessionID
    }

    private static func defaultRepository() -> CoFleetAppRepository {
        guard ProcessInfo.processInfo.arguments.contains("-cofleetUITesting") else {
            return CoFleetAppRepository()
        }
        let suiteName = "org.cofleet.ui-tests"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return CoFleetAppRepository(defaultsSuiteName: suiteName)
    }

    private static func defaultThreadSnapshotStorage() -> any CoFleetThreadSnapshotStorage {
        guard ProcessInfo.processInfo.arguments.contains("-cofleetUITesting") else {
            return CoFleetUserDefaultsThreadSnapshotStorage()
        }
        let suiteName = "org.cofleet.ui-tests"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return CoFleetUserDefaultsThreadSnapshotStorage(defaults: defaults)
    }
}

private struct SessionRoute: Equatable {
    var projectID: String
    var sessionID: String?
}

private struct HostProjectRoute: Hashable {
    var hostID: CoFleetHostID
    var projectID: String
}

public struct CoFleetAppSceneView: View {
    @Bindable private var controller: CoFleetAppController

    public init(controller: CoFleetAppController) {
        self.controller = controller
    }

    public var body: some View {
        CoFleetRootView(
            fleetStore: controller.fleetStore,
            threadStore: controller.threadStore,
            turnStore: controller.turnStore,
            workspaceStore: controller.workspaceStore,
            models: controller.models,
            localHostID: controller.localHostID,
            pairAction: { input in try await controller.pair(input) }
        )
        .task { await controller.start() }
        .onChange(of: controller.fleetStore.selectedProjectID) {
            controller.selectedProjectDidChange()
        }
        .onChange(of: controller.threadStore.selectedSessionID) {
            controller.selectedSessionDidChange()
        }
        .onChange(of: controller.fleetStore.hosts.map(\.id)) {
            controller.synchronizeHostEventStreams()
        }
    }
}
#endif
