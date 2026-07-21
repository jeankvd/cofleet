import CoFleetCore
import SwiftUI

#if !os(watchOS)

public struct CoFleetActiveView: View {
    @Bindable private var fleetStore: FleetStore
    @Bindable private var threadStore: ThreadStore
    @Bindable private var turnStore: TurnStore
    @Bindable private var workspaceStore: WorkspaceStore
    @Binding private var settings: CoFleetSessionSettings
    private let models: [CoFleetModelInfo]
    private let localHostID: CoFleetHostID?

    public init(
        fleetStore: FleetStore,
        threadStore: ThreadStore,
        turnStore: TurnStore,
        workspaceStore: WorkspaceStore,
        settings: Binding<CoFleetSessionSettings>,
        models: [CoFleetModelInfo],
        localHostID: CoFleetHostID? = nil
    ) {
        self.fleetStore = fleetStore
        self.threadStore = threadStore
        self.turnStore = turnStore
        self.workspaceStore = workspaceStore
        _settings = settings
        self.models = models
        self.localHostID = localHostID
    }

    public var body: some View {
        GeometryReader { proxy in
            if CoFleetResponsivePolicy.activeUsesSideBySide(availableWidth: proxy.size.width) {
                #if os(macOS)
                HSplitView {
                    progressRail
                        .frame(minWidth: 340, idealWidth: proxy.size.width * 0.42)
                    agentBay
                        .frame(minWidth: 420)
                }
                #else
                HStack(spacing: 0) {
                    progressRail
                        .frame(width: proxy.size.width * 0.42)
                    Divider()
                    agentBay
                }
                #endif
            } else {
                VStack(spacing: 0) {
                    progressRail
                        .frame(height: min(300, proxy.size.height * 0.36))
                    Divider()
                    agentBay
                }
            }
        }
        .background(CoFleetTheme.background)
    }

    private var progressRail: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(fleetStore.visibleProjects) { project in
                    let host = fleetStore.hosts.first { $0.id == project.hostID }
                    Button {
                        fleetStore.selectedProjectID = project.id
                    } label: {
                        HStack(spacing: 10) {
                            CoFleetPetPlaceholder(name: project.displayName, size: 46)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(project.displayName).font(.headline)
                                    Spacer()
                                    CoFleetStatusIndicators(
                                        reachability: host?.reachability ?? .unknown,
                                        action: project.state.actionIndicator,
                                        sourceControl: project.sourceControl
                                    )
                                }
                                if fleetStore.selectedProjectID == project.id {
                                    Text(workspaceStore.noteDraft.isEmpty ? "No notes" : workspaceStore.noteDraft)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(12)
                        .background(
                            fleetStore.selectedProjectID == project.id
                                ? CoFleetTheme.violet.opacity(0.16)
                                : CoFleetTheme.surface,
                            in: RoundedRectangle(cornerRadius: 15)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
    }

    private var agentBay: some View {
        CoFleetAgentBayView(
            threadStore: threadStore,
            turnStore: turnStore,
            settings: $settings,
            models: models,
            fleetStore: fleetStore,
            localHostID: localHostID
        )
    }
}
#endif
