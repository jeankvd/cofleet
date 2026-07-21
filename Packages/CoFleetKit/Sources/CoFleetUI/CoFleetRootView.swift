import CoFleetCore
import SwiftUI

#if !os(watchOS)
public enum CoFleetDestination: String, CaseIterable, Identifiable, Sendable {
    case progress = "Progress"
    case dashboard = "Dashboard"
    case agentBay = "Agent Bay"
    case active = "Active"
    case battle = "Battle"

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .progress: "rectangle.grid.2x2.fill"
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .agentBay: "bubble.left.and.bubble.right.fill"
        case .active: "bolt.horizontal.fill"
        case .battle: "shield.lefthalf.filled"
        }
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

    @State private var destination = CoFleetDestination.progress
    @State private var settings = CoFleetSessionSettings()
    @State private var showsLegal = false
    @AppStorage("cofleet.onboarding.setupInProgress") private var setupInProgress = false
    @AppStorage("cofleet.onboarding.setupCompleted") private var setupCompleted = false

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
        .accessibilityIdentifier("cofleet.root")
        .sheet(isPresented: $showsLegal) {
            NavigationStack { CoFleetLegalView() }
        }
        .onChange(of: threadStore.selectedSessionID) { _, _ in
            settings = threadStore.selectedSession?.settings ?? CoFleetSessionSettings()
        }
    }

    private var shouldShowFirstRun: Bool {
        !fleetStore.hosts.isEmpty
            && (setupInProgress || (!setupCompleted && fleetStore.projects.isEmpty))
    }

    #if os(macOS)
    private var desktopContent: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Destination", selection: $destination) {
                    ForEach(CoFleetDestination.allCases) { item in
                        Text(item.rawValue)
                            .tag(item)
                            .accessibilityIdentifier(item == .progress ? "cofleet.destination.progress" : "cofleet.destination.\(item.id)")
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 560)
                Spacer()
                Button { showsLegal = true } label: { Image(systemName: "info.circle") }
            }
            .padding(10)
            .background(CoFleetTheme.surface)
            destinationView
        }
    }
    #endif

    private var mobileContent: some View {
        TabView(selection: $destination) {
            ForEach(CoFleetDestination.allCases) { item in
                destinationView(for: item)
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
            CoFleetProgressView(
                fleetStore: fleetStore,
                threadStore: threadStore,
                turnStore: turnStore,
                workspaceStore: workspaceStore,
                settings: $settings,
                localHostID: localHostID
            )
        case .dashboard:
            CoFleetDashboardView(
                fleetStore: fleetStore,
                threadStore: threadStore,
                turnStore: turnStore,
                pairAction: pairAction
            )
        case .agentBay:
            CoFleetAgentBayView(
                threadStore: threadStore,
                turnStore: turnStore,
                settings: $settings,
                models: models,
                fleetStore: fleetStore,
                localHostID: localHostID
            )
        case .active:
            CoFleetActiveView(
                fleetStore: fleetStore,
                threadStore: threadStore,
                turnStore: turnStore,
                workspaceStore: workspaceStore,
                settings: $settings,
                models: models,
                localHostID: localHostID
            )
        case .battle:
            CoFleetBattleView(projects: fleetStore.visibleProjects, hosts: fleetStore.hosts)
        }
    }
}
#endif
