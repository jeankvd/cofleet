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

    public init(repository: CoFleetAppRepository? = nil) {
        let resolvedRepository = repository ?? Self.defaultRepository()
        self.repository = resolvedRepository
        fleetStore = FleetStore(repository: resolvedRepository)
        threadStore = ThreadStore(repository: resolvedRepository)
        turnStore = TurnStore(repository: resolvedRepository)
        workspaceStore = WorkspaceStore(repository: resolvedRepository)
    }

    public func start() async {
        await fleetStore.refresh()
        models = await repository.fetchModels()
        localHostID = await repository.localHostID()
        await fleetStore.refreshAccountState()
        await openSelectedProject()
    }

    public func pair(_ input: CoFleetPairingInput) async throws -> CoFleetHostInfo {
        let host = try await repository.pair(
            CoFleetPairingInputValue(endpoint: input.endpoint, code: input.code, deviceName: input.deviceName)
        )
        await fleetStore.refresh()
        models = await repository.fetchModels()
        localHostID = await repository.localHostID()
        await fleetStore.refreshAccountState()
        return host
    }

    public func openSelectedProject() async {
        guard let project = fleetStore.selectedProject else { return }
        models = await repository.fetchModels(hostID: project.hostID)
        await threadStore.loadInitial(hostID: project.hostID, projectID: project.id)
        await openSelectedSession()
    }

    public func openSelectedSession() async {
        guard let project = fleetStore.selectedProject else { return }
        await workspaceStore.open(
            hostID: project.hostID,
            projectID: project.id,
            sessionID: threadStore.selectedSessionID,
            isHostOnline: fleetStore.hosts.first { $0.id == project.hostID }?.reachability == .online,
            selectedPetID: project.selectedPetID
        )
        guard let sessionID = threadStore.selectedSessionID else { return }
        let settings = threadStore.selectedSession?.settings ?? CoFleetSessionSettings()
        _ = try? await threadStore.resumeSelected(settings: settings)
        await turnStore.open(hostID: project.hostID, projectID: project.id, sessionID: sessionID)
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
            Task { await controller.openSelectedProject() }
        }
        .onChange(of: controller.threadStore.selectedSessionID) {
            Task { await controller.openSelectedSession() }
        }
    }
}
#endif
