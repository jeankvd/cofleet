import CoFleetCore
import SwiftUI

#if os(watchOS)
public enum CoFleetWatchScreen: String, CaseIterable, Identifiable, Sendable {
    case agentBay = "Agent Bay"
    case battle = "Battle"
    case progress = "Progress"

    public var id: String { rawValue }
    public var symbol: String {
        switch self {
        case .agentBay: "bubble.left.and.bubble.right.fill"
        case .battle: "shield.lefthalf.filled"
        case .progress: "rectangle.grid.1x2.fill"
        }
    }
}

public struct CoFleetWatchRootView: View {
    public var snapshot: CoFleetWatchSnapshot
    public var onSend: (CoFleetWatchProjectSnapshot, String) -> Void
    public var onToggleTodo: (CoFleetWatchProjectSnapshot) -> Void

    @State private var screen: CoFleetWatchScreen?
    @State private var selectedProjectID: String?
    @State private var draft = ""

    public init(
        snapshot: CoFleetWatchSnapshot,
        onSend: @escaping (CoFleetWatchProjectSnapshot, String) -> Void,
        onToggleTodo: @escaping (CoFleetWatchProjectSnapshot) -> Void
    ) {
        self.snapshot = snapshot
        self.onSend = onSend
        self.onToggleTodo = onToggleTodo
    }

    public var body: some View {
        Group {
            if let screen {
                screenView(screen)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 24)
                            .onEnded { value in
                                if value.translation.width > 38 { self.screen = nil }
                            }
                    )
            } else {
                menu
            }
        }
        .containerBackground(CoFleetTheme.background.gradient, for: .navigation)
        .onAppear { selectedProjectID = selectedProjectID ?? snapshot.focusedProjectID ?? snapshot.projects.first?.id }
    }

    private var menu: some View {
        List(CoFleetWatchScreen.allCases) { item in
            Button {
                screen = item
            } label: {
                Label(item.rawValue, systemImage: item.symbol)
                    .font(.headline)
            }
        }
        .navigationTitle("CoFleet")
    }

    @ViewBuilder
    private func screenView(_ screen: CoFleetWatchScreen) -> some View {
        switch screen {
        case .agentBay: agentBay
        case .battle: CoFleetWatchBattleView(projects: battleProjects)
        case .progress: progress
        }
    }

    private var agentBay: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let project = selectedProject {
                    HStack(spacing: 7) {
                        CoFleetPetPreviewView(
                            name: project.name,
                            preview: project.petPreview,
                            size: 38
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name).font(.caption.bold()).lineLimit(1)
                            CoFleetStatusIndicators(
                                reachability: project.hostReachability,
                                action: project.action,
                                sourceControl: project.sourceControl
                            )
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)

                    if let latestMessage = project.latestMessage {
                        Text(latestMessage)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(CoFleetTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                    }

                    HStack(spacing: 6) {
                        TextField("Type or dictate", text: $draft)
                            .font(.caption)
                        Button {
                            let prompt = draft
                            draft = ""
                            onSend(project, prompt)
                        } label: {
                            Image(systemName: "arrow.up")
                                .frame(width: 28, height: 28)
                                .background(CoFleetTheme.cyan, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    Text("Pair a host on iPhone first.").font(.caption)
                }
            }
        }
    }

    private var progress: some View {
        List(snapshot.projects) { project in
            Button {
                selectedProjectID = project.id
                screen = .agentBay
            } label: {
                HStack {
                    CoFleetPetPreviewView(
                        name: project.name,
                        preview: project.petPreview,
                        size: 34
                    )
                    VStack(alignment: .leading) {
                        Text(project.name).font(.caption.bold())
                        Text(project.action.rawValue).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if project.pendingTodoCount > 0 {
                        Button { onToggleTodo(project) } label: {
                            Text("\(project.pendingTodoCount)")
                                .font(.caption2.bold())
                        }
                    }
                }
            }
        }
    }

    private var selectedProject: CoFleetWatchProjectSnapshot? {
        snapshot.projects.first { $0.id == selectedProjectID } ?? snapshot.projects.first
    }

    private var battleProjects: [CoFleetProject] {
        snapshot.projects.map {
            CoFleetProject(
                id: $0.id,
                hostID: .init(rawValue: "watch-snapshot"),
                displayName: $0.name,
                canonicalPath: "/snapshot/\($0.id)",
                state: projectState(for: $0.action),
                sourceControl: $0.sourceControl
            )
        }
    }

    private func projectState(for action: CoFleetActionIndicator) -> CoFleetProjectState {
        switch action {
        case .approvalNeeded: .waitingForApproval
        case .questionAsked: .waitingForAnswer
        case .replied: .replied
        case .idle: .idle
        default: .working
        }
    }
}
#endif
