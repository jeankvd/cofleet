import CoFleetCore
import SwiftUI

#if !os(watchOS)

struct CoFleetFirstRunView: View {
    @Bindable var fleetStore: FleetStore
    @Bindable var workspaceStore: WorkspaceStore
    let onComplete: () -> Void

    @SceneStorage("cofleet.onboarding.setupStage") private var stageValue = Stage.project.rawValue
    @State private var isPreparingPets = false

    private enum Stage: String {
        case project
        case pet
        case ready
    }

    var body: some View {
        Group {
            switch stage {
            case .project:
                projectStep
            case .pet:
                petStep
            case .ready:
                readyStep
            }
        }
        .background(CoFleetTheme.background)
        .task { normalizeStage() }
    }

    private var projectStep: some View {
        VStack(spacing: 0) {
            setupHeader(
                step: 2,
                title: "Add your first project",
                detail: "Choose the folder where Codex should work. CoFleet never moves or deletes it."
            )
            if isPreparingPets {
                ProgressView("Preparing your project…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CoFleetProjectRegistrationView(
                    fleetStore: fleetStore,
                    showsCloseButton: false,
                    dismissesOnRegistration: false,
                    onRegistered: preparePets
                )
            }
        }
    }

    @ViewBuilder
    private var petStep: some View {
        if let project = setupProject {
            VStack(spacing: 0) {
                setupHeader(
                    step: 3,
                    title: "Choose a project pet",
                    detail: "Import a compatible Codex pet, select one already on this host, or tap Done to skip."
                )
                CoFleetPetLibraryView(
                    workspaceStore: workspaceStore,
                    project: project,
                    onProjectUpdated: fleetStore.applyProjectUpdate,
                    onDone: { stage = .ready }
                )
            }
        } else {
            ProgressView("Loading your project…")
                .task { stage = .project }
        }
    }

    private var readyStep: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 70, weight: .bold))
                    .foregroundStyle(CoFleetTheme.green)
                VStack(spacing: 8) {
                    Text("Your fleet is ready")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("Open Progress to see the project, start a Codex task, manage notes and todos, or add another project now.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 12) {
                    Button {
                        stage = .project
                    } label: {
                        Label("Add Another Project", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        onComplete()
                    } label: {
                        Label("Open Progress", systemImage: "arrow.right.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CoFleetTheme.cyan)
                }
                .frame(maxWidth: 420)
            }
            .padding(30)
            .frame(maxWidth: .infinity, minHeight: 520)
        }
    }

    private func setupHeader(step: Int, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("STEP \(step) OF 3")
                    .font(.caption.bold())
                    .foregroundStyle(CoFleetTheme.cyan)
                Spacer()
                Text("Connect")
                Image(systemName: "chevron.right")
                Text("Project")
                Image(systemName: "chevron.right")
                Text("Pet")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text(title)
                .font(.system(.title2, design: .rounded, weight: .bold))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(CoFleetTheme.surface)
    }

    private var stage: Stage {
        get { Stage(rawValue: stageValue) ?? .project }
        nonmutating set { stageValue = newValue.rawValue }
    }

    private var setupProject: CoFleetProject? {
        if let selected = fleetStore.selectedProject {
            return selected
        }
        return fleetStore.projects.first
    }

    private func normalizeStage() {
        if fleetStore.projects.isEmpty {
            stage = .project
        } else if stage == .project {
            preparePets(fleetStore.selectedProject ?? fleetStore.projects[0])
        }
    }

    private func preparePets(_ project: CoFleetProject) {
        isPreparingPets = true
        Task { @MainActor in
            let online = fleetStore.hosts.first { $0.id == project.hostID }?.reachability == .online
            await workspaceStore.open(
                hostID: project.hostID,
                projectID: project.id,
                isHostOnline: online,
                selectedPetID: project.selectedPetID
            )
            isPreparingPets = false
            stage = .pet
        }
    }
}

#endif
