import CoFleetCore
import SwiftUI

#if !os(watchOS)

/// Keeps the real Progress workspace visible while the selected project's
/// canonical Codex conversation remains available beside it on macOS or below
/// it on iPhone and iPad.
public struct CoFleetActiveView: View {
    @Bindable private var fleetStore: FleetStore
    @Bindable private var threadStore: ThreadStore
    @Bindable private var turnStore: TurnStore
    @Bindable private var workspaceStore: WorkspaceStore
    @Binding private var settings: CoFleetSessionSettings
    private let models: [CoFleetModelInfo]
    private let localHostID: CoFleetHostID?
    private let isVisible: Bool
    private let onHatchPet: (@MainActor (CoFleetProject) async throws -> Void)?

    public init(
        fleetStore: FleetStore,
        threadStore: ThreadStore,
        turnStore: TurnStore,
        workspaceStore: WorkspaceStore,
        settings: Binding<CoFleetSessionSettings>,
        models: [CoFleetModelInfo],
        localHostID: CoFleetHostID? = nil,
        isVisible: Bool = true,
        onHatchPet: (@MainActor (CoFleetProject) async throws -> Void)? = nil
    ) {
        self.fleetStore = fleetStore
        self.threadStore = threadStore
        self.turnStore = turnStore
        self.workspaceStore = workspaceStore
        _settings = settings
        self.models = models
        self.localHostID = localHostID
        self.isVisible = isVisible
        self.onHatchPet = onHatchPet
    }

    public var body: some View {
#if os(macOS)
        HSplitView {
            progress
                .frame(minWidth: 340, idealWidth: 560, maxWidth: 720)

            agentBay
                .frame(minWidth: 420)
        }
        .accessibilityIdentifier("cofleet.active.workspace")
#else
        GeometryReader { geometry in
            VStack(spacing: 0) {
                progress
                    .frame(height: CoFleetActiveLayoutPolicy.progressHeight(
                        availableHeight: geometry.size.height
                    ))

                Divider().opacity(0.45)

                agentBay
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier("cofleet.active.workspace")
#endif
    }

    private var progress: some View {
        CoFleetProgressView(
            fleetStore: fleetStore,
            threadStore: threadStore,
            turnStore: turnStore,
            workspaceStore: workspaceStore,
            settings: $settings,
            localHostID: localHostID,
            isVisible: isVisible,
            // Progress already selects the project. Remaining in Active lets the
            // app controller route the matching task into the adjacent Agent Bay.
            onOpenProject: { _ in },
            onHatchPet: onHatchPet
        )
    }

    private var agentBay: some View {
        CoFleetAgentBayView(
            threadStore: threadStore,
            turnStore: turnStore,
            settings: $settings,
            models: models,
            fleetStore: fleetStore,
            workspaceStore: workspaceStore,
            localHostID: localHostID,
            onHatchPet: onHatchPet
        )
    }
}

enum CoFleetActiveLayoutPolicy {
    static func progressHeight(availableHeight: CGFloat) -> CGFloat {
        // Fresh Codex cards include two message bubbles. Reserving roughly half
        // the phone workspace lets one complete card remain visible while the
        // lower conversation still keeps a useful reading/composer area.
        min(max(availableHeight * 0.52, 340), 420)
    }
}
#endif
