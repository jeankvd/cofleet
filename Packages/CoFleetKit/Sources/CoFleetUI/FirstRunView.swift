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
                title: "Add your first project"
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
                    Text("Open Progress to see each project's freshest Codex task. Notes, todos, and full conversations stay in Agent Bay.")
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

    private func setupHeader(step: Int, title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                ForEach(1...3, id: \.self) { item in
                    HStack(spacing: 4) {
                        Image(systemName: stepIcon(for: item, currentStep: step))
                        Text(stepTitle(for: item))
                    }
                    .font(.caption2.weight(item == step ? .bold : .medium))
                    .foregroundStyle(item <= step ? CoFleetTheme.cyan : Color.secondary)

                    if item < 3 {
                        Capsule()
                            .fill(item < step ? CoFleetTheme.cyan : Color.secondary.opacity(0.3))
                            .frame(maxWidth: .infinity)
                            .frame(height: 2)
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: step == 2 ? "folder.fill" : (step == 3 ? "pawprint.fill" : "shippingbox.fill"))
                    .foregroundStyle(CoFleetTheme.cyan)
                Text(title)
                    .font(.system(.headline, design: .rounded, weight: .bold))
            }

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(CoFleetTheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CoFleetTheme.cyan.opacity(0.18))
                .frame(height: 1)
        }
    }

    private func stepTitle(for step: Int) -> String {
        switch step {
        case 1: "Connect"
        case 2: "Project"
        default: "Pet"
        }
    }

    private func stepIcon(for step: Int, currentStep: Int) -> String {
        if step < currentStep {
            return "checkmark.circle.fill"
        }
        return step == currentStep ? "\(step).circle.fill" : "\(step).circle"
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
