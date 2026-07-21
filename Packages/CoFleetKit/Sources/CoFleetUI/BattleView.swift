import CoFleetCore
import CoreGraphics
import Foundation
import SwiftUI

#if os(iOS) || os(macOS)
@preconcurrency import ImageIO
@preconcurrency import SceneKit

#if os(iOS)
import UIKit
private typealias BattleNativeColor = UIColor
private typealias BattleNativeFont = UIFont
#elseif os(macOS)
import AppKit
private typealias BattleNativeColor = NSColor
private typealias BattleNativeFont = NSFont
#endif
#endif

public enum CoFleetBattleReadiness: Equatable, Sendable {
    case noProject
    case loading
    case needsTodos(projectID: String, projectName: String, count: Int)
    case ready(projectID: String)
}

public enum CoFleetBattleOnboardingPolicy {
    public static func readiness(
        projects: [CoFleetProject],
        preferredProjectID: String?,
        todosByProjectID: [String: [CoFleetTodoItem]]
    ) -> CoFleetBattleReadiness {
        guard !projects.isEmpty else { return .noProject }

        let ordered = projects.sorted { lhs, rhs in
            if lhs.id == preferredProjectID { return true }
            if rhs.id == preferredProjectID { return false }
            return lhs.sortIndex < rhs.sortIndex
        }
        if let ready = ordered.first(where: { (todosByProjectID[$0.id]?.count ?? 0) >= 2 }) {
            return .ready(projectID: ready.id)
        }

        let target = ordered[0]
        if todosByProjectID[target.id] == nil {
            return .loading
        }
        return .needsTodos(
            projectID: target.id,
            projectName: target.displayName,
            count: todosByProjectID[target.id]?.count ?? 0
        )
    }
}

public struct CoFleetBattleOnboardingView: View {
    public var readiness: CoFleetBattleReadiness
    public var onAddProject: () -> Void
    public var onAddTodos: (String) -> Void

    public init(
        readiness: CoFleetBattleReadiness,
        onAddProject: @escaping () -> Void,
        onAddTodos: @escaping (String) -> Void
    ) {
        self.readiness = readiness
        self.onAddProject = onAddProject
        self.onAddTodos = onAddTodos
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.025, green: 0.055, blue: 0.07),
                    Color(red: 0.025, green: 0.035, blue: 0.045),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(CoFleetTheme.violet.opacity(0.17))
                        .frame(width: 104, height: 104)
                    Circle()
                        .stroke(CoFleetTheme.cyan.opacity(0.28), lineWidth: 1)
                        .frame(width: 104, height: 104)
                    Image(systemName: symbol)
                        .font(.system(size: 42, weight: .black))
                        .foregroundStyle(CoFleetTheme.cyan)
                }
                .shadow(color: CoFleetTheme.cyan.opacity(0.18), radius: 24)

                VStack(spacing: 8) {
                    Text(title)
                        .font(.system(.title, design: .rounded).weight(.black))
                        .multilineTextAlignment(.center)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                if case let .needsTodos(_, _, count) = readiness {
                    HStack(spacing: 8) {
                        ForEach(0..<2, id: \.self) { index in
                            Image(systemName: index < count ? "checkmark.square.fill" : "square")
                                .foregroundStyle(index < count ? CoFleetTheme.green : .secondary)
                        }
                        Text("\(min(count, 2)) of 2 todos ready")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.055), in: Capsule())
                }

                action
            }
            .padding(28)
        }
        .accessibilityIdentifier("cofleet-battle-onboarding")
    }

    @ViewBuilder
    private var action: some View {
        switch readiness {
        case .noProject:
            Button(action: onAddProject) {
                Label("Add your first project", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .loading:
            ProgressView("Checking battle setup…")
                .controlSize(.large)
        case let .needsTodos(projectID, _, _):
            Button { onAddTodos(projectID) } label: {
                Label("Add battle todos", systemImage: "checklist")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .ready:
            EmptyView()
        }
    }

    private var symbol: String {
        switch readiness {
        case .noProject: "folder.badge.plus"
        case .loading: "shield.lefthalf.filled"
        case .needsTodos: "checklist"
        case .ready: "shield.checkered"
        }
    }

    private var title: String {
        switch readiness {
        case .noProject: "Build your battle party"
        case .loading: "Preparing Battle"
        case .needsTodos: "Give your agent objectives"
        case .ready: "Battle ready"
        }
    }

    private var detail: String {
        switch readiness {
        case .noProject:
            "Battle needs a Codex project first. Add one from a paired host, then give it two concrete objectives."
        case .loading:
            "CoFleet is checking your project’s host-authoritative todo list."
        case let .needsTodos(_, projectName, count):
            count == 0
                ? "Add at least two todos to \(projectName). Each completed objective becomes an attack."
                : "Add one more todo to \(projectName). Each completed objective becomes an attack."
        case .ready:
            "Your first battle is ready."
        }
    }
}

/// CoFleet's native battle presentation. The SceneKit scene is owned by the
/// representable coordinator, so ordinary SwiftUI updates reconcile the
/// combatants without rebuilding the camera, terrain, lighting, or renderer.
@MainActor
public struct CoFleetBattleView: View {
    public var projects: [CoFleetProject]
    public var hosts: [CoFleetHostInfo]
    public var petManifests: [String: CoFleetPetManifest]
    public var petAssets: [String: CoFleetPetAsset]
    public var todosByProjectID: [String: [CoFleetTodoItem]]
    public var onToggleTodo: (String, String) -> Void

    @AppStorage("cofleet.battle.partyProjectIDs.v1")
    private var partyProjectIDsJSON = ""

    @State private var activeProjectID: String
    @State private var demoCompletedObjectiveIDs: Set<String> = []
    @State private var attackingProjectID: String?
    @State private var impactToken = 0
    @State private var lastRemainingObjectiveCount: Int?

    public init(
        projects: [CoFleetProject],
        hosts: [CoFleetHostInfo],
        petManifests: [String: CoFleetPetManifest] = [:],
        petAssets: [String: CoFleetPetAsset] = [:],
        todosByProjectID: [String: [CoFleetTodoItem]] = [:],
        onToggleTodo: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.projects = projects
        self.hosts = hosts
        self.petManifests = petManifests
        self.petAssets = petAssets
        self.todosByProjectID = todosByProjectID
        self.onToggleTodo = onToggleTodo
        _activeProjectID = State(initialValue: projects.first?.id ?? "")
    }

    public var body: some View {
        #if os(watchOS)
        CoFleetWatchBattleView(projects: projects.map(CoFleetWatchProjectSnapshot.init(project:)))
        #else
        GeometryReader { geometry in
            VStack(spacing: 0) {
                battleHeader(compact: geometry.size.width < 720)
                Divider().opacity(0.28)

                if geometry.size.width >= 760 {
                    HStack(spacing: 0) {
                        battleStage
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        Divider().opacity(0.22)

                        objectivePanel
                            .frame(width: min(340, geometry.size.width * 0.34))
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            battleStage
                                .frame(height: min(max(geometry.size.height * 0.57, 360), 500))
                            objectivePanel
                        }
                        .padding(.bottom, 18)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .background(battleBackground)
        }
        .task {
            establishDefaultPartyIfNeeded()
            lastRemainingObjectiveCount = remainingObjectiveCount
        }
        .onChange(of: projects.map(\.id)) {
            pruneAndEstablishParty()
        }
        .onChange(of: partyProjectIDsJSON) {
            ensureActiveProjectIsInParty()
            lastRemainingObjectiveCount = remainingObjectiveCount
        }
        .onChange(of: activeProjectID) {
            lastRemainingObjectiveCount = remainingObjectiveCount
        }
        .onChange(of: remainingObjectiveCount) { oldValue, newValue in
            if lastRemainingObjectiveCount != nil, newValue < oldValue {
                playAttack(projectID: resolvedActiveProjectID)
            }
            lastRemainingObjectiveCount = newValue
        }
        .onChange(of: battlePartyState) { oldValue, newValue in
            guard let projectID = CoFleetBattlePartyState.firstReplyTransition(
                from: oldValue,
                to: newValue
            ) else { return }
            playAttack(projectID: projectID)
        }
        .accessibilityIdentifier("cofleet-battle")
        #endif
    }

    #if !os(watchOS)
    private var battleBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.025, green: 0.055, blue: 0.07),
                Color(red: 0.025, green: 0.035, blue: 0.045),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private func battleHeader(compact: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Battle")
                    .font(.system(compact ? .title2 : .title, design: .rounded).weight(.black))
                if !compact {
                    Text("Finish objectives to break the backlog.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)
            partyMenu

            Button {
                playAttack(projectID: resolvedActiveProjectID)
            } label: {
                Label(compact ? "Attack" : "Preview attack", systemImage: "burst.fill")
                    .font(.subheadline.weight(.bold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(attackingProjectID != nil || battleParty.isEmpty)
            .accessibilityIdentifier("cofleet-battle-attack")
        }
        .padding(.horizontal, compact ? 14 : 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var partyMenu: some View {
        Menu {
            ForEach(projects) { project in
                Button {
                    togglePartyProject(project.id)
                } label: {
                    Label(
                        project.displayName,
                        systemImage: partyProjectIDs.contains(project.id) ? "checkmark.circle.fill" : "circle"
                    )
                }
            }

            Divider()
            Text("Choose up to three pets")
        } label: {
            Label("Party \(battleParty.count)/3", systemImage: "person.3.fill")
                .font(.subheadline.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("cofleet-battle-party")
    }

    private var battleStage: some View {
        GeometryReader { geometry in
            ZStack {
                CoFleetBattleSceneView(
                    pets: battlePets,
                    activeProjectID: resolvedActiveProjectID,
                    attackingProjectID: attackingProjectID,
                    enemyHealthFraction: enemyHealthFraction,
                    impactToken: impactToken,
                    onSelectPet: { activeProjectID = $0 }
                )

                LinearGradient(
                    colors: [.black.opacity(0.42), .clear, .clear, .black.opacity(0.28)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                RadialGradient(
                    colors: [.clear, .clear, .black.opacity(0.34)],
                    center: .center,
                    startRadius: 80,
                    endRadius: max(geometry.size.width, geometry.size.height) * 0.7
                )
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.11), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.5), radius: 22, y: 12)
            .padding(geometry.size.width < 760 ? 12 : 18)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("HD 2D Codex battle field")
    }

    private var objectivePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enemy health")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("\(remainingObjectiveCount) objectives remain")
                            .font(.headline.weight(.black))
                    }
                    Spacer()
                    Text("\(Int((enemyHealthFraction * 100).rounded()))%")
                        .font(.title3.monospacedDigit().weight(.black))
                        .foregroundStyle(healthColor)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.black.opacity(0.42))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [healthColor.opacity(0.76), healthColor],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, geometry.size.width * enemyHealthFraction))
                    }
                }
                .frame(height: 13)
                .animation(.spring(response: 0.45, dampingFraction: 0.78), value: enemyHealthFraction)
            }

            Divider().opacity(0.28)

            HStack {
                Label("Battle todos", systemImage: "checklist")
                    .font(.headline.weight(.black))
                Spacer()
                if let activeProject {
                    Text(activeProject.displayName.uppercased())
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(CoFleetTheme.cyan)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(objectives.enumerated()), id: \.element.id) { index, objective in
                    Button {
                        toggleObjective(objective)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: objective.isComplete ? "checkmark.square.fill" : "square")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(objective.isComplete ? Color.green : Color.secondary)
                            Text(objective.title)
                                .font(.subheadline)
                                .foregroundStyle(objective.isComplete ? .secondary : .primary)
                                .strikethrough(objective.isComplete)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(objective.isComplete ? Color.green.opacity(0.07) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < objectives.count - 1 {
                        Divider()
                            .padding(.leading, 35)
                            .opacity(0.24)
                    }
                }
            }
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(CoFleetTheme.orange.opacity(0.18), lineWidth: 1)
            }

            Spacer(minLength: 0)

            Text(usingLiveTodos
                 ? "Synced from this project’s CoFleet todos. Completing an item triggers an attack."
                 : "Preview objectives — tap one to preview task-driven combat.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08))
        }
        .padding(18)
        .accessibilityIdentifier("cofleet-battle-objectives")
    }

    private var battlePets: [CoFleetBattleScenePet] {
        battleParty.map { project in
            CoFleetBattleScenePet(
                id: project.id,
                name: project.displayName,
                state: project.state,
                isHostOnline: hosts.first(where: { $0.id == project.hostID })?.reachability == .online,
                manifest: petManifests[project.id],
                asset: petAssets[project.id]
            )
        }
    }

    private var resolvedActiveProjectID: String {
        battleParty.contains(where: { $0.id == activeProjectID })
            ? activeProjectID
            : (battleParty.first?.id ?? "")
    }

    private var partyProjectIDs: [String] {
        guard let data = partyProjectIDsJSON.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        let valid = Set(projects.map(\.id))
        return ids.filter(valid.contains)
    }

    private var battleParty: [CoFleetProject] {
        let selected = Set(partyProjectIDs)
        return projects.filter { selected.contains($0.id) }
    }

    private var battlePartyState: [CoFleetBattlePartyState] {
        battleParty.map { CoFleetBattlePartyState(projectID: $0.id, state: $0.state) }
    }

    private var enemyHealthFraction: CGFloat {
        guard !objectives.isEmpty else { return 0 }
        return CGFloat(remainingObjectiveCount) / CGFloat(objectives.count)
    }

    private var healthColor: Color {
        switch enemyHealthFraction {
        case 0 ..< 0.3: .red
        case 0.3 ..< 0.65: .orange
        default: .green
        }
    }

    private var activeProject: CoFleetProject? {
        battleParty.first { $0.id == resolvedActiveProjectID } ?? battleParty.first
    }

    private var liveTodos: [CoFleetTodoItem] {
        guard let activeProject else { return [] }
        return (todosByProjectID[activeProject.id] ?? [])
            .sorted { lhs, rhs in
                lhs.sortIndex == rhs.sortIndex ? lhs.updatedAt < rhs.updatedAt : lhs.sortIndex < rhs.sortIndex
            }
    }

    private var usingLiveTodos: Bool {
        guard let activeProject else { return false }
        return todosByProjectID[activeProject.id] != nil
    }

    private var objectives: [CoFleetBattleObjective] {
        if usingLiveTodos {
            return liveTodos.prefix(7).map {
                CoFleetBattleObjective(id: $0.id, title: $0.title, isComplete: $0.isCompleted, isLive: true)
            }
        }
        return Self.demoObjectives(completed: demoCompletedObjectiveIDs)
    }

    private var remainingObjectiveCount: Int {
        objectives.filter { !$0.isComplete }.count
    }

    private func establishDefaultPartyIfNeeded() {
        guard partyProjectIDs.isEmpty else {
            ensureActiveProjectIsInParty()
            return
        }
        guard let initialID = projects.first(where: { $0.id == activeProjectID })?.id ?? projects.first?.id else { return }
        persistParty([initialID])
        activeProjectID = initialID
    }

    private func pruneAndEstablishParty() {
        let valid = Set(projects.map(\.id))
        let pruned = partyProjectIDs.filter(valid.contains)
        if pruned != partyProjectIDs { persistParty(pruned) }
        establishDefaultPartyIfNeeded()
    }

    private func ensureActiveProjectIsInParty() {
        guard !battleParty.contains(where: { $0.id == activeProjectID }) else { return }
        activeProjectID = battleParty.first?.id ?? ""
    }

    private func togglePartyProject(_ projectID: String) {
        var ids = partyProjectIDs
        if let index = ids.firstIndex(of: projectID) {
            guard ids.count > 1 else { return }
            ids.remove(at: index)
        } else {
            if ids.count == 3 { ids.removeFirst() }
            ids.append(projectID)
            activeProjectID = projectID
        }
        persistParty(ids)
    }

    private func persistParty(_ ids: [String]) {
        guard let data = try? JSONEncoder().encode(Array(ids.prefix(3))),
              let value = String(data: data, encoding: .utf8) else { return }
        partyProjectIDsJSON = value
    }

    private func toggleObjective(_ objective: CoFleetBattleObjective) {
        if objective.isLive, let activeProject {
            onToggleTodo(activeProject.id, objective.id)
        } else if objective.isComplete {
            demoCompletedObjectiveIDs.remove(objective.id)
        } else {
            demoCompletedObjectiveIDs.insert(objective.id)
        }
    }

    private func playAttack(projectID: String) {
        guard !projectID.isEmpty, attackingProjectID == nil else { return }
        activeProjectID = projectID
        attackingProjectID = projectID
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(185))
            impactToken &+= 1
            try? await Task.sleep(for: .milliseconds(430))
            if attackingProjectID == projectID {
                attackingProjectID = nil
            }
        }
    }

    private static func demoObjectives(completed: Set<String>) -> [CoFleetBattleObjective] {
        [
            ("connect", "Connect a Codex project host"),
            ("turn", "Send a turn to the active project"),
            ("review", "Review the streamed Codex reply"),
            ("backlog", "Clear the project backlog"),
        ].map { id, title in
            CoFleetBattleObjective(id: id, title: title, isComplete: completed.contains(id), isLive: false)
        }
    }
    #endif
}

private struct CoFleetBattleObjective: Identifiable, Equatable {
    let id: String
    let title: String
    let isComplete: Bool
    let isLive: Bool
}

struct CoFleetBattlePartyState: Equatable {
    let projectID: String
    let state: CoFleetProjectState

    static func firstReplyTransition(
        from oldParty: [Self],
        to newParty: [Self]
    ) -> String? {
        let oldStates = Dictionary(uniqueKeysWithValues: oldParty.map { ($0.projectID, $0.state) })
        return newParty.first { member in
            guard let oldState = oldStates[member.projectID] else { return false }
            return oldState != .replied && member.state == .replied
        }?.projectID
    }
}

#if os(watchOS)
public struct CoFleetWatchBattleView: View {
    public var projects: [CoFleetWatchProjectSnapshot]
    @Binding private var selectedProjectID: String?
    private let onSend: (CoFleetWatchProjectSnapshot, String) -> Void
    private let onToggleTodo: (CoFleetWatchProjectSnapshot) -> Void

    @State private var presentedPanel: CoFleetBattlePanel?
    @State private var petFloating = false
    @State private var enemyPulsing = false

    public init(
        projects: [CoFleetWatchProjectSnapshot],
        selectedProjectID: Binding<String?> = .constant(nil),
        onSend: @escaping (CoFleetWatchProjectSnapshot, String) -> Void = { _, _ in },
        onToggleTodo: @escaping (CoFleetWatchProjectSnapshot) -> Void = { _ in }
    ) {
        self.projects = projects
        _selectedProjectID = selectedProjectID
        self.onSend = onSend
        self.onToggleTodo = onToggleTodo
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                battlefieldBackground

                petAura
                    .frame(width: 74, height: 74)
                    .position(x: geometry.size.width * 0.27, y: geometry.size.height * 0.35)

                CoFleetPetPreviewView(
                    name: selectedProject?.name ?? "Codex",
                    preview: selectedProject?.petPreview,
                    size: 76
                )
                .scaleEffect(x: -1, y: 1)
                .offset(y: petFloating ? -3 : 2)
                .shadow(color: CoFleetTheme.cyan.opacity(0.40), radius: 5)
                .position(x: geometry.size.width * 0.27, y: geometry.size.height * 0.35)

                enemy
                    .frame(width: 54, height: 54)
                    .scaleEffect(enemyPulsing ? 1.04 : 0.96)
                    .position(x: geometry.size.width * 0.74, y: geometry.size.height * 0.35)

                projectPlate
                    .frame(width: geometry.size.width * 0.45)
                    .position(x: geometry.size.width * 0.26, y: geometry.size.height * 0.62)

                enemyPlate
                    .frame(width: geometry.size.width * 0.45)
                    .position(x: geometry.size.width * 0.74, y: geometry.size.height * 0.62)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    actionGrid.frame(height: 57)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 3)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea(.container, edges: .all)
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("watch-2d-battle")
        .sheet(item: $presentedPanel) { panel in
            switch panel {
            case .status:
                CoFleetWatchBattleStatusView(project: selectedProject)
            case .dictate:
                CoFleetWatchBattleDictationView(project: selectedProject, onSend: onSend)
            case .todos:
                CoFleetWatchBattleTodosView(project: selectedProject, onToggleTodo: onToggleTodo)
            case .projects:
                CoFleetWatchBattleProjectPickerView(
                    projects: projects,
                    selectedProjectID: $selectedProjectID
                )
            }
        }
        .onAppear {
            if selectedProjectID == nil { selectedProjectID = projects.first?.id }
            withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) {
                petFloating = true
            }
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                enemyPulsing = true
            }
        }
    }

    private var battlefieldBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.005, green: 0.04, blue: 0.08),
                    Color(red: 0.06, green: 0.02, blue: 0.09),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(CoFleetTheme.cyan.opacity(0.14))
                .frame(width: 160)
                .blur(radius: 42)
                .offset(x: -88, y: -80)

            Circle()
                .fill(CoFleetTheme.violet.opacity(0.13))
                .frame(width: 150)
                .blur(radius: 44)
                .offset(x: 92, y: 92)

            VStack(spacing: 17) {
                ForEach(0..<7, id: \.self) { index in
                    Rectangle()
                        .fill(index.isMultiple(of: 2) ? Color.white.opacity(0.025) : CoFleetTheme.cyan.opacity(0.035))
                        .frame(height: 1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 24) {
                ForEach(0..<8, id: \.self) { _ in
                    Rectangle().fill(Color.white.opacity(0.018)).frame(width: 1)
                }
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.06), .black.opacity(0.32)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var enemyPlate: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text("WRAITH")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                Spacer(minLength: 1)
                Text("\(remainingTodos) LEFT")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }
            HStack(spacing: 3) {
                Text("HP")
                    .font(.system(size: 6, weight: .black, design: .rounded))
                    .foregroundStyle(.orange)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.black.opacity(0.62))
                        Capsule().fill(enemyHealthColor)
                            .frame(width: proxy.size.width * enemyHealthFraction)
                    }
                }
                .frame(height: 5)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(CoFleetTheme.violet.opacity(0.38), lineWidth: 1))
    }

    private var enemy: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                Capsule()
                    .fill(CoFleetTheme.violet.opacity(0.78))
                    .frame(width: 6, height: 15)
                    .offset(y: -29)
                    .rotationEffect(.degrees(Double(index) * 45))
            }
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.pink.opacity(0.92), Color(red: 0.18, green: 0.025, blue: 0.28)],
                        center: .topLeading,
                        startRadius: 3,
                        endRadius: 38
                    )
                )
                .overlay(Circle().stroke(CoFleetTheme.violet.opacity(0.9), lineWidth: 2))
            Text("!")
                .font(.system(size: 25, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
        }
        .shadow(color: CoFleetTheme.violet.opacity(0.5), radius: 7)
        .accessibilityLabel("Backlog wraith, \(remainingTodos) tasks remaining")
    }

    private var petAura: some View {
        Circle()
            .fill(CoFleetTheme.cyan.opacity(0.08))
            .overlay(Circle().stroke(CoFleetTheme.cyan.opacity(0.28), lineWidth: 1))
            .shadow(color: CoFleetTheme.cyan.opacity(0.18), radius: 8)
    }

    private var projectPlate: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text((selectedProject?.name ?? "NO PROJECT").uppercased())
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                Spacer(minLength: 1)
                if let selectedProject {
                    CoFleetStatusIndicators(
                        reachability: selectedProject.hostReachability,
                        action: selectedProject.action,
                        sourceControl: selectedProject.sourceControl
                    )
                }
            }
            HStack(spacing: 3) {
                Text("AP")
                    .font(.system(size: 6, weight: .black, design: .rounded))
                    .foregroundStyle(selectedAction.battleColor)
                GeometryReader { proxy in
                    Capsule()
                        .fill(.black.opacity(0.20))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(selectedAction.battleColor)
                                .frame(width: proxy.size.width * actionProgress)
                        }
                }
                .frame(height: 5)
            }
            Text(selectedAction.battleLabel)
                .font(.system(size: 6.5, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(CoFleetTheme.cyan.opacity(0.38), lineWidth: 1))
    }

    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 3) {
            battleButton(.status, title: "STATUS", icon: selectedAction.battleIcon, color: selectedAction.battleColor)
            battleButton(.dictate, title: "DICTATE", icon: "mic.fill", color: .cyan)
            battleButton(.todos, title: "TODOs \(remainingTodos)", icon: "checklist", color: .orange)
            battleButton(.projects, title: "PROJECT", icon: "person.2.fill", color: CoFleetTheme.cyan)
        }
        .padding(4)
        .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.10), lineWidth: 1))
    }

    private func battleButton(_ panel: CoFleetBattlePanel, title: String, icon: String, color: Color) -> some View {
        Button { presentedPanel = panel } label: {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 8, weight: .black))
                Text(title)
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 21)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.34), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("watch-battle-\(panel.rawValue)")
    }

    private var selectedProject: CoFleetWatchProjectSnapshot? {
        projects.first { $0.id == selectedProjectID } ?? projects.first
    }

    private var selectedAction: CoFleetActionIndicator { selectedProject?.action ?? .idle }
    private var remainingTodos: Int { selectedProject?.pendingTodoCount ?? 0 }

    private var enemyHealthFraction: CGFloat {
        guard remainingTodos > 0 else { return 0.08 }
        return max(0.08, min(1, CGFloat(remainingTodos) / 6))
    }

    private var enemyHealthColor: Color {
        enemyHealthFraction < 0.3 ? .red : (enemyHealthFraction < 0.65 ? .orange : .green)
    }

    private var actionProgress: CGFloat {
        switch selectedAction {
        case .idle: 0.22
        case .thinking: 0.40
        case .runningCommand: 0.62
        case .reasoning: 0.52
        case .approvalNeeded, .questionAsked: 0.48
        case .working: 0.78
        case .replied: 1
        }
    }
}

private enum CoFleetBattlePanel: String, Identifiable {
    case status
    case dictate
    case todos
    case projects

    var id: String { rawValue }
}

private struct CoFleetWatchBattleStatusView: View {
    let project: CoFleetWatchProjectSnapshot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    CoFleetPetPreviewView(name: project?.name ?? "Codex", preview: project?.petPreview, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project?.name ?? "No project").font(.headline)
                        Text((project?.action ?? .idle).battleLabel)
                            .font(.caption.bold())
                            .foregroundStyle((project?.action ?? .idle).battleColor)
                    }
                }
                Text(project?.latestMessage ?? "No recent turn yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 5)
        }
        .navigationTitle("Status")
    }
}

private struct CoFleetWatchBattleDictationView: View {
    @Environment(\.dismiss) private var dismiss
    let project: CoFleetWatchProjectSnapshot?
    let onSend: (CoFleetWatchProjectSnapshot, String) -> Void
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 8) {
            Text("Command \(project?.name ?? "Codex")")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            TextField("Type or dictate…", text: $draft)
                .accessibilityIdentifier("watch-battle-dictation-field")
            Button {
                guard let project else { return }
                onSend(project, draft)
                dismiss()
            } label: {
                Label("Send turn", systemImage: "arrow.up.circle.fill")
            }
            .disabled(project == nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 5)
    }
}

private struct CoFleetWatchBattleTodosView: View {
    let project: CoFleetWatchProjectSnapshot?
    let onToggleTodo: (CoFleetWatchProjectSnapshot) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                if let project, project.pendingTodoCount > 0 {
                    Text("\(project.pendingTodoCount) pending \(project.pendingTodoCount == 1 ? "todo" : "todos")")
                        .font(.headline)
                    Button {
                        onToggleTodo(project)
                    } label: {
                        Label("Complete next todo", systemImage: "checkmark.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(project.nextPendingTodoID == nil)
                } else {
                    Label("Backlog cleared", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(CoFleetTheme.green)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 5)
        }
        .navigationTitle("TODOs")
    }
}

private struct CoFleetWatchBattleProjectPickerView: View {
    let projects: [CoFleetWatchProjectSnapshot]
    @Binding var selectedProjectID: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(projects) { project in
            Button {
                selectedProjectID = project.id
                dismiss()
            } label: {
                HStack(spacing: 7) {
                    CoFleetPetPreviewView(name: project.name, preview: project.petPreview, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name).font(.caption.bold())
                        Text(project.action.battleLabel)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(project.action.battleColor)
                    }
                    Spacer(minLength: 0)
                    if project.id == selectedProjectID {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(CoFleetTheme.cyan)
                    }
                }
            }
        }
        .navigationTitle("Project")
    }
}

private extension CoFleetActionIndicator {
    var battleLabel: String {
        switch self {
        case .idle: "Idle — ready for a turn"
        case .thinking: "Thinking"
        case .runningCommand: "Running commands"
        case .reasoning: "Reasoning"
        case .approvalNeeded: "Approval needed"
        case .questionAsked: "Question asked"
        case .working: "Working"
        case .replied: "Replied"
        }
    }

    var battleIcon: String {
        switch self {
        case .idle: "pause.fill"
        case .thinking: "ellipsis"
        case .runningCommand: "terminal.fill"
        case .reasoning: "brain.head.profile"
        case .approvalNeeded: "hand.raised.fill"
        case .questionAsked: "questionmark"
        case .working: "gearshape.fill"
        case .replied: "checkmark"
        }
    }

    var battleColor: Color {
        switch self {
        case .idle: .gray
        case .thinking: .cyan
        case .runningCommand: .orange
        case .reasoning: .purple
        case .approvalNeeded: .yellow
        case .questionAsked: .pink
        case .working: .blue
        case .replied: .green
        }
    }
}

private extension CoFleetWatchProjectSnapshot {
    init(project: CoFleetProject) {
        self.init(
            id: project.id,
            hostID: project.hostID,
            name: project.displayName,
            hostReachability: project.state == .unavailable ? .offline : .online,
            action: project.state.actionIndicator,
            selectedPetID: project.selectedPetID,
            sourceControl: project.sourceControl
        )
    }
}
#endif

#if os(iOS) || os(macOS)

private struct CoFleetBattleScenePet: Identifiable, Equatable {
    let id: String
    let name: String
    let state: CoFleetProjectState
    let isHostOnline: Bool
    let textureRequest: CoFleetBattlePetTextureRequest?

    init(
        id: String,
        name: String,
        state: CoFleetProjectState,
        isHostOnline: Bool,
        manifest: CoFleetPetManifest?,
        asset: CoFleetPetAsset?
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.isHostOnline = isHostOnline
        if let manifest, let asset,
           manifest.hostID == asset.hostID,
           manifest.id == asset.petID,
           manifest.spritesheetPath == asset.assetName,
           (try? CoFleetPetManifestValidator.validate(manifest)) != nil {
            textureRequest = CoFleetBattlePetTextureRequest(
                cacheKey: "\(manifest.canonicalIdentity):\(manifest.digest):\(Self.animationRow(for: state))",
                manifest: manifest,
                asset: asset,
                row: Self.animationRow(for: state)
            )
        } else {
            textureRequest = nil
        }
    }

    var stateLabel: String {
        guard isHostOnline else { return "OFFLINE" }
        return switch state {
        case .waitingForApproval: "APPROVAL"
        case .waitingForAnswer: "QUESTION"
        default: state.rawValue.uppercased()
        }
    }

    private static func animationRow(for state: CoFleetProjectState) -> Int {
        switch state {
        case .idle: 0
        case .replied: 3
        case .waitingForApproval, .waitingForAnswer: 6
        case .working: 7
        case .unavailable: 0
        }
    }
}

private struct CoFleetBattlePetTextureRequest: Equatable, @unchecked Sendable {
    let cacheKey: String
    let manifest: CoFleetPetManifest
    let asset: CoFleetPetAsset
    let row: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cacheKey == rhs.cacheKey
    }
}

private actor CoFleetBattlePetTextureCache {
    static let shared = CoFleetBattlePetTextureCache()
    private static let maximumRetainedBytes = 48 * 1_024 * 1_024

    private var textures: [String: CoFleetBattlePetTexture] = [:]
    private var pending: [String: Task<CoFleetBattlePetTexture?, Never>] = [:]
    private var recency: [String] = []
    private var retainedBytes = 0

    func texture(for request: CoFleetBattlePetTextureRequest) async -> CoFleetBattlePetTexture? {
        if let cached = textures[request.cacheKey] {
            touch(request.cacheKey)
            return cached
        }
        if let task = pending[request.cacheKey] {
            return await task.value
        }

        let task = Task.detached(priority: .utility) {
            CoFleetBattlePetTexture(
                manifest: request.manifest,
                asset: request.asset,
                row: request.row
            )
        }
        pending[request.cacheKey] = task
        let texture = await task.value
        pending[request.cacheKey] = nil
        guard let texture else { return nil }

        let byteCount = texture.estimatedByteCount
        if byteCount <= Self.maximumRetainedBytes {
            while retainedBytes + byteCount > Self.maximumRetainedBytes,
                  let oldest = recency.first {
                recency.removeFirst()
                if let removed = textures.removeValue(forKey: oldest) {
                    retainedBytes = max(0, retainedBytes - removed.estimatedByteCount)
                }
            }
            textures[request.cacheKey] = texture
            retainedBytes += byteCount
            touch(request.cacheKey)
        }
        return texture
    }

    private func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

private struct CoFleetBattlePetTexture: @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let image: CGImage
        let endTime: TimeInterval
    }

    let frames: [Frame]
    let duration: TimeInterval

    init?(manifest: CoFleetPetManifest, asset: CoFleetPetAsset, row: Int, outlineRadius: Int = 2) {
        guard (try? CoFleetPetManifestValidator.validate(manifest)) != nil,
              manifest.hostID == asset.hostID,
              manifest.id == asset.petID,
              manifest.spritesheetPath == asset.assetName,
              let source = CGImageSourceCreateWithData(asset.data as CFData, nil),
              let atlas = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCache: true,
                  kCGImageSourceShouldAllowFloat: false,
              ] as CFDictionary),
              atlas.width == manifest.pixelWidth,
              atlas.height == manifest.pixelHeight else { return nil }

        let sequence = CoFleetPetFramePolicy.sequence(
            in: atlas,
            manifest: manifest,
            row: row
        )
        var decoded: [Frame] = []
        for (frameIndex, column) in sequence.columns.enumerated() {
            let crop = CGRect(
                x: column * manifest.frameWidth,
                y: sequence.row * manifest.frameHeight,
                width: manifest.frameWidth,
                height: manifest.frameHeight
            )
            guard let frame = atlas.cropping(to: crop),
                  let outlined = Self.outlinedImage(frame, radius: outlineRadius) else { continue }
            decoded.append(Frame(image: outlined, endTime: Double(frameIndex + 1) * 0.12))
        }
        guard !decoded.isEmpty else { return nil }
        frames = decoded
        duration = Double(decoded.count) * 0.12
    }

    init?(image: CGImage, outlineRadius: Int = 2) {
        guard let outlined = Self.outlinedImage(image, radius: outlineRadius) else { return nil }
        frames = [Frame(image: outlined, endTime: 0.12)]
        duration = 0.12
    }

    var aspectRatio: CGFloat {
        guard let image = frames.first?.image, image.height > 0 else { return 1 }
        return CGFloat(image.width) / CGFloat(image.height)
    }

    var estimatedByteCount: Int {
        frames.reduce(into: 0) { result, frame in
            let (frameBytes, overflow) = frame.image.bytesPerRow.multipliedReportingOverflow(
                by: frame.image.height
            )
            let (total, totalOverflow) = result.addingReportingOverflow(frameBytes)
            result = overflow || totalOverflow ? Int.max : total
        }
    }

    static func outlinedImage(_ image: CGImage, radius: Int) -> CGImage? {
        let padding = max(0, radius)
        let width = image.width + padding * 2
        let height = image.height + padding * 2
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.interpolationQuality = .none
        let sourceSize = CGSize(width: image.width, height: image.height)
        if padding > 0 {
            for yOffset in -padding ... padding {
                for xOffset in -padding ... padding where xOffset != 0 || yOffset != 0 {
                    guard xOffset * xOffset + yOffset * yOffset <= padding * padding + 1 else { continue }
                    let rect = CGRect(
                        origin: CGPoint(x: padding + xOffset, y: padding + yOffset),
                        size: sourceSize
                    )
                    context.saveGState()
                    context.clip(to: rect, mask: image)
                    context.setFillColor(CGColor(gray: 0, alpha: 1))
                    context.fill(rect)
                    context.restoreGState()
                }
            }
        }
        context.draw(image, in: CGRect(origin: CGPoint(x: padding, y: padding), size: sourceSize))
        return context.makeImage()
    }
}

private struct CoFleetBattleSceneView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    let pets: [CoFleetBattleScenePet]
    let activeProjectID: String
    let attackingProjectID: String?
    let enemyHealthFraction: CGFloat
    let impactToken: Int
    let onSelectPet: (String) -> Void

    var body: some View {
        CoFleetBattleSceneRepresentable(
            pets: pets,
            activeProjectID: activeProjectID,
            attackingProjectID: attackingProjectID,
            enemyHealthFraction: enemyHealthFraction,
            impactToken: impactToken,
            isActive: isVisible && scenePhase == .active,
            onSelectPet: onSelectPet
        )
        .ignoresSafeArea()
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .accessibilityLabel("3D agent battle field. Tap a pet to select the attacker.")
    }
}

#if os(iOS)
private struct CoFleetBattleSceneRepresentable: UIViewRepresentable {
    let pets: [CoFleetBattleScenePet]
    let activeProjectID: String
    let attackingProjectID: String?
    let enemyHealthFraction: CGFloat
    let impactToken: Int
    let isActive: Bool
    let onSelectPet: (String) -> Void

    func makeCoordinator() -> CoFleetBattleSceneCoordinator { CoFleetBattleSceneCoordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = context.coordinator.makeView()
        context.coordinator.installInteraction(on: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onSelectPet = onSelectPet
        context.coordinator.updatePlayback(isActive: isActive, on: view)
        context.coordinator.updateCombatants(
            pets: pets,
            activeProjectID: activeProjectID,
            attackingProjectID: attackingProjectID,
            enemyHealthFraction: enemyHealthFraction
        )
        context.coordinator.updateImpact(impactToken)
    }

    static func dismantleUIView(_ view: SCNView, coordinator: CoFleetBattleSceneCoordinator) {
        coordinator.dismantle(view)
    }
}
#elseif os(macOS)
private struct CoFleetBattleSceneRepresentable: NSViewRepresentable {
    let pets: [CoFleetBattleScenePet]
    let activeProjectID: String
    let attackingProjectID: String?
    let enemyHealthFraction: CGFloat
    let impactToken: Int
    let isActive: Bool
    let onSelectPet: (String) -> Void

    func makeCoordinator() -> CoFleetBattleSceneCoordinator { CoFleetBattleSceneCoordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = context.coordinator.makeView()
        context.coordinator.installInteraction(on: view)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.onSelectPet = onSelectPet
        context.coordinator.updatePlayback(isActive: isActive, on: view)
        context.coordinator.updateCombatants(
            pets: pets,
            activeProjectID: activeProjectID,
            attackingProjectID: attackingProjectID,
            enemyHealthFraction: enemyHealthFraction
        )
        context.coordinator.updateImpact(impactToken)
    }

    static func dismantleNSView(_ view: SCNView, coordinator: CoFleetBattleSceneCoordinator) {
        coordinator.dismantle(view)
    }
}
#endif

struct CoFleetBattleSceneQualityProfile {
    let antialiasingMode: SCNAntialiasingMode
    let preferredFramesPerSecond: Int
    let rendersContinuously: Bool
    let isJitteringEnabled: Bool
    let wantsDepthOfField: Bool
    let focalBlurSampleCount: Int
    let shadowMapSize: CGFloat

    static let desktop = CoFleetBattleSceneQualityProfile(
        antialiasingMode: .multisampling4X,
        preferredFramesPerSecond: 60,
        rendersContinuously: true,
        isJitteringEnabled: true,
        wantsDepthOfField: true,
        focalBlurSampleCount: 64,
        shadowMapSize: 2_048
    )

    static func mobile(isLowPowerModeEnabled: Bool) -> CoFleetBattleSceneQualityProfile {
        CoFleetBattleSceneQualityProfile(
            antialiasingMode: isLowPowerModeEnabled ? .none : .multisampling2X,
            preferredFramesPerSecond: isLowPowerModeEnabled ? 24 : 30,
            rendersContinuously: false,
            isJitteringEnabled: false,
            wantsDepthOfField: !isLowPowerModeEnabled,
            focalBlurSampleCount: isLowPowerModeEnabled ? 8 : 16,
            shadowMapSize: isLowPowerModeEnabled ? 512 : 1_024
        )
    }

    static var current: CoFleetBattleSceneQualityProfile {
        #if os(iOS)
        mobile(isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled)
        #else
        desktop
        #endif
    }
}

struct CoFleetBattleScenePlaybackState: Equatable {
    let isPlaying: Bool
    let rendersContinuously: Bool

    static func resolve(
        isActive: Bool,
        quality: CoFleetBattleSceneQualityProfile
    ) -> CoFleetBattleScenePlaybackState {
        CoFleetBattleScenePlaybackState(
            isPlaying: isActive,
            rendersContinuously: isActive && quality.rendersContinuously
        )
    }
}

struct CoFleetBattleCameraConfiguration {
    let focalLength: CGFloat
    let sensorHeight: CGFloat
    let position: SCNVector3
    let target: SCNVector3

    static let manada = CoFleetBattleCameraConfiguration(
        focalLength: 50,
        sensorHeight: 24,
        position: SCNVector3(0, 9.2, 12.2),
        target: SCNVector3(0, 0.1, -1.4)
    )
}

@MainActor
private final class CoFleetBattleSceneCoordinator {
    private weak var cameraNode: SCNNode?
    private weak var sceneRoot: SCNNode?
    private weak var enemyRoot: SCNNode?
    private weak var enemyCore: SCNNode?
    private weak var enemyHealthFill: SCNNode?
    private weak var enemyHealthLabel: SCNText?
    private var petNodes: [String: SCNNode] = [:]
    private var petDescriptors: [String: CoFleetBattleScenePet] = [:]
    private var petTextureTasks: [String: Task<Void, Never>] = [:]
    private var lastAttackingProjectID: String?
    private var lastImpactToken = 0
    private let quality = CoFleetBattleSceneQualityProfile.current
    var onSelectPet: ((String) -> Void)?

    func makeView() -> SCNView {
        let view = SCNView(frame: .zero)
        let built = Self.makeScene(quality: quality)
        view.scene = built.scene
        view.pointOfView = built.camera
        view.backgroundColor = BattleNativeColor(red: 0.04, green: 0.12, blue: 0.11, alpha: 1)
        view.antialiasingMode = quality.antialiasingMode
        view.preferredFramesPerSecond = quality.preferredFramesPerSecond
        view.rendersContinuously = false
        view.isJitteringEnabled = quality.isJitteringEnabled
        view.isPlaying = false
        view.allowsCameraControl = false
        cameraNode = built.camera
        sceneRoot = built.scene.rootNode

        let enemy = Self.makeEnemy()
        built.scene.rootNode.addChildNode(enemy.root)
        enemyRoot = enemy.root
        enemyCore = enemy.core
        enemyHealthFill = enemy.healthFill
        enemyHealthLabel = enemy.healthLabel
        return view
    }

    func updatePlayback(isActive: Bool, on view: SCNView) {
        let playback = CoFleetBattleScenePlaybackState.resolve(isActive: isActive, quality: quality)
        view.isPlaying = playback.isPlaying
        view.rendersContinuously = playback.rendersContinuously
    }

    func dismantle(_ view: SCNView) {
        view.isPlaying = false
        view.rendersContinuously = false
        view.scene?.rootNode.enumerateChildNodes { node, _ in node.removeAllActions() }
        view.pointOfView = nil
        view.scene = nil
        onSelectPet = nil
        for task in petTextureTasks.values { task.cancel() }
        petTextureTasks.removeAll()
        petNodes.removeAll()
        petDescriptors.removeAll()
        lastAttackingProjectID = nil
    }

    func updateCombatants(
        pets: [CoFleetBattleScenePet],
        activeProjectID: String,
        attackingProjectID: String?,
        enemyHealthFraction: CGFloat
    ) {
        reconcilePets(pets)
        updatePetSelection(activeProjectID)
        updateEnemyHealth(enemyHealthFraction)

        if let attackingProjectID, lastAttackingProjectID == nil {
            animateAttack(projectID: attackingProjectID)
        }
        lastAttackingProjectID = attackingProjectID
    }

    func installInteraction(on view: SCNView) {
        #if os(iOS)
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        #elseif os(macOS)
        view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:))))
        #endif
    }

    #if os(iOS)
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view as? SCNView else { return }
        selectPet(at: gesture.location(in: view), in: view)
    }
    #elseif os(macOS)
    @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view as? SCNView else { return }
        selectPet(at: gesture.location(in: view), in: view)
    }
    #endif

    private func selectPet(at point: CGPoint, in view: SCNView) {
        guard let hit = view.hitTest(point, options: nil).first else { return }
        var candidate: SCNNode? = hit.node
        while let node = candidate {
            if let name = node.name, name.hasPrefix("battle-pet::") {
                onSelectPet?(String(name.dropFirst("battle-pet::".count)))
                return
            }
            candidate = node.parent
        }
    }

    private func reconcilePets(_ pets: [CoFleetBattleScenePet]) {
        guard let sceneRoot else { return }
        let incomingIDs = Set(pets.map(\.id))
        for (id, node) in petNodes where !incomingIDs.contains(id) {
            petTextureTasks.removeValue(forKey: id)?.cancel()
            node.removeFromParentNode()
            petNodes.removeValue(forKey: id)
            petDescriptors.removeValue(forKey: id)
        }

        for (index, descriptor) in pets.enumerated() {
            let previous = petDescriptors[descriptor.id]
            let node: SCNNode
            if let existing = petNodes[descriptor.id] {
                node = existing
                Self.updatePetPresentation(descriptor, on: node)
            } else {
                node = Self.makePet(descriptor)
                petNodes[descriptor.id] = node
                sceneRoot.addChildNode(node)
            }
            petDescriptors[descriptor.id] = descriptor
            if previous?.textureRequest != descriptor.textureRequest {
                if descriptor.textureRequest == nil,
                   let fallback = Self.fallbackPetTexture(name: descriptor.name) {
                    petTextureTasks.removeValue(forKey: descriptor.id)?.cancel()
                    Self.install(fallback, on: node)
                } else {
                    loadPetTexture(for: descriptor)
                }
            }
            if node.action(forKey: "pet-strike") == nil {
                node.position = Self.petPosition(index: index)
            }
        }
    }

    private func loadPetTexture(for descriptor: CoFleetBattleScenePet) {
        guard let request = descriptor.textureRequest else { return }
        petTextureTasks[descriptor.id]?.cancel()
        petTextureTasks[descriptor.id] = Task { [weak self] in
            let texture = await CoFleetBattlePetTextureCache.shared.texture(for: request)
            guard !Task.isCancelled,
                  let self,
                  self.petDescriptors[descriptor.id]?.textureRequest == request,
                  let node = self.petNodes[descriptor.id],
                  let texture else { return }
            self.petTextureTasks[descriptor.id] = nil
            Self.install(texture, on: node)
        }
    }

    private func updatePetSelection(_ activeProjectID: String) {
        for (id, node) in petNodes {
            let isActive = id == activeProjectID
            node.opacity = isActive ? 1 : 0.84
            let scale: Float = isActive ? 1.06 : 0.92
            node.scale = SCNVector3(scale, scale, scale)
            node.childNode(withName: "selection", recursively: true)?.isHidden = !isActive
        }
    }

    private func updateEnemyHealth(_ fraction: CGFloat) {
        guard let enemyHealthFill else { return }
        let clamped = max(0, min(1, fraction))
        let maximumWidth: CGFloat = 2.65
        let width = max(0.035, maximumWidth * clamped)
        let fill = SCNBox(width: width, height: 0.11, length: 0.075, chamferRadius: 0.05)
        fill.firstMaterial = Self.emissiveMaterial(Self.healthColor(clamped), intensity: 0.20)
        enemyHealthFill.geometry = fill
        enemyHealthFill.position.x = SCNFloat(-maximumWidth / 2 + width / 2)
        enemyHealthLabel?.string = "\(Int((clamped * 100).rounded()))%"
    }

    private func animateAttack(projectID: String) {
        guard let node = petNodes[projectID] else { return }
        node.removeAction(forKey: "pet-strike")
        let strike = SCNAction.group([
            .moveBy(x: 4.65, y: 0.26, z: -0.16, duration: 0.17),
            .rotateBy(x: 0, y: 0, z: -0.10, duration: 0.17),
        ])
        strike.timingMode = .easeIn
        let returnAction = SCNAction.group([
            .moveBy(x: -4.65, y: -0.26, z: 0.16, duration: 0.31),
            .rotateBy(x: 0, y: 0, z: 0.10, duration: 0.31),
        ])
        returnAction.timingMode = .easeOut
        node.runAction(.sequence([strike, .wait(duration: 0.12), returnAction]), forKey: "pet-strike")
    }

    func updateImpact(_ token: Int) {
        guard token != lastImpactToken else { return }
        lastImpactToken = token
        if let cameraNode {
            cameraNode.removeAction(forKey: "battle-impact")
            let shake = SCNAction.sequence([
                .moveBy(x: 0.10, y: 0.04, z: 0, duration: 0.045),
                .moveBy(x: -0.20, y: -0.08, z: 0, duration: 0.06),
                .moveBy(x: 0.15, y: 0.07, z: 0, duration: 0.055),
                .moveBy(x: -0.05, y: -0.03, z: 0, duration: 0.05),
            ])
            shake.timingMode = .easeInEaseOut
            cameraNode.runAction(shake, forKey: "battle-impact")
        }

        if let enemyRoot {
            enemyRoot.removeAction(forKey: "enemy-impact")
            let recoil = SCNAction.sequence([
                .moveBy(x: 0.22, y: 0, z: 0, duration: 0.045),
                .moveBy(x: -0.42, y: 0.04, z: 0, duration: 0.055),
                .moveBy(x: 0.28, y: -0.04, z: 0, duration: 0.06),
                .moveBy(x: -0.08, y: 0, z: 0, duration: 0.07),
            ])
            enemyRoot.runAction(recoil, forKey: "enemy-impact")
            Self.emitImpactParticles(from: enemyRoot)
        }

        if let material = enemyCore?.geometry?.firstMaterial {
            material.emission.contents = BattleNativeColor.white
            material.emission.intensity = 2.4
            enemyCore?.runAction(.sequence([
                .scale(to: 1.18, duration: 0.055),
                .scale(to: 1.0, duration: 0.18),
            ]))
            Task { @MainActor [weak material] in
                try? await Task.sleep(for: .milliseconds(145))
                material?.emission.contents = BattleNativeColor(red: 0.38, green: 0.035, blue: 0.01, alpha: 1)
                material?.emission.intensity = 0.55
            }
        }
    }

    private static func petPosition(index: Int) -> SCNVector3 {
        let positions = [
            SCNVector3(-2.78, 0.02, -0.48),
            SCNVector3(-3.36, 0.02, 0.92),
            SCNVector3(-2.08, 0.02, 1.46),
        ]
        return positions[min(index, positions.count - 1)]
    }

    private static func makePet(_ descriptor: CoFleetBattleScenePet) -> SCNNode {
        let root = SCNNode()
        root.name = "battle-pet::\(descriptor.id)"

        let texture = fallbackPetTexture(name: descriptor.name)
        let aspectRatio = texture?.aspectRatio ?? 1
        let spriteWidth: CGFloat = aspectRatio >= 1 ? 1 : aspectRatio
        let spriteHeight: CGFloat = aspectRatio >= 1 ? 1 / aspectRatio : 1
        let spritePlane = SCNPlane(width: spriteWidth, height: spriteHeight)
        let spriteMaterial = SCNMaterial()
        if let image = texture?.frames.first?.image {
            spriteMaterial.diffuse.contents = image
            spriteMaterial.transparent.contents = image
        }
        configureSpriteMaterial(spriteMaterial)
        spritePlane.firstMaterial = spriteMaterial

        let sprite = SCNNode(geometry: spritePlane)
        sprite.name = "sprite"
        sprite.position = SCNVector3(0, SCNFloat(spriteHeight / 2 + 0.06), 0)
        sprite.scale.x = -1
        sprite.castsShadow = true
        sprite.eulerAngles = SCNVector3Zero
        root.addChildNode(CoFleetBattlePetBillboard.makeContainer(for: sprite))

        let selection = SCNNode(geometry: SCNTorus(ringRadius: 0.34, pipeRadius: 0.022))
        selection.name = "selection"
        selection.geometry?.firstMaterial = emissiveMaterial(
            BattleNativeColor(red: 0.18, green: 1, blue: 0.42, alpha: 1),
            intensity: 1.5
        )
        selection.eulerAngles = SCNVector3Zero
        selection.position = SCNVector3(0, 0.045, 0)
        selection.castsShadow = false
        root.addChildNode(selection)

        let accent = petAccent(for: descriptor)
        let hud = makeWorldHUD(
            role: "CODEX",
            title: descriptor.name,
            state: descriptor.stateLabel,
            accent: accent,
            maximumWidth: 2.15,
            healthFraction: descriptor.isHostOnline ? 1 : 0.22
        )
        hud.root.position = SCNVector3(0, 1.55, 0.05)
        root.addChildNode(hud.root)
        return root
    }

    private static func updatePetPresentation(_ descriptor: CoFleetBattleScenePet, on root: SCNNode) {
        let accent = petAccent(for: descriptor)
        let healthFraction: CGFloat = descriptor.isHostOnline ? 1 : 0.22

        if let title = root.childNode(withName: "title-text", recursively: true)?.geometry as? SCNText {
            title.string = descriptor.name.uppercased()
        }
        if let state = root.childNode(withName: "state-text", recursively: true)?.geometry as? SCNText {
            state.string = descriptor.stateLabel.uppercased()
        }
        root.childNode(withName: "role-text", recursively: true)?.geometry?.firstMaterial = emissiveMaterial(accent, intensity: 0.22)
        root.childNode(withName: "accent-rail", recursively: true)?.geometry?.firstMaterial = emissiveMaterial(accent, intensity: 0.34)
        root.childNode(withName: "panel-border", recursively: true)?.geometry?.firstMaterial = emissiveMaterial(
            accent.withAlphaComponent(0.44),
            intensity: 0.12
        )
        root.childNode(withName: "bar-border", recursively: true)?.geometry?.firstMaterial = emissiveMaterial(
            accent.withAlphaComponent(0.38),
            intensity: 0.08
        )

        if let healthFill = root.childNode(withName: "health-fill", recursively: true) {
            let maximumWidth: CGFloat = 2.15
            let width = max(0.035, maximumWidth * healthFraction)
            let geometry = SCNBox(width: width, height: 0.11, length: 0.075, chamferRadius: 0.05)
            geometry.firstMaterial = emissiveMaterial(accent, intensity: 0.20)
            healthFill.geometry = geometry
            healthFill.position.x = SCNFloat(-maximumWidth / 2 + width / 2)
        }
    }

    private static func petAccent(for descriptor: CoFleetBattleScenePet) -> BattleNativeColor {
        descriptor.isHostOnline
            ? BattleNativeColor(red: 0.15, green: 0.92, blue: 0.42, alpha: 1)
            : BattleNativeColor(white: 0.48, alpha: 1)
    }

    private static func configureSpriteMaterial(_ material: SCNMaterial) {
        material.diffuse.magnificationFilter = .nearest
        material.diffuse.minificationFilter = .nearest
        material.diffuse.mipFilter = .none
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.transparent.magnificationFilter = .nearest
        material.transparent.minificationFilter = .nearest
        material.transparent.mipFilter = .none
        material.transparent.wrapS = .clamp
        material.transparent.wrapT = .clamp
        material.transparencyMode = .aOne
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = true
    }

    private static func install(_ texture: CoFleetBattlePetTexture, on root: SCNNode) {
        guard let sprite = root.childNode(withName: "sprite", recursively: true),
              let material = sprite.geometry?.firstMaterial else { return }
        let aspectRatio = texture.aspectRatio
        let spriteWidth: CGFloat = aspectRatio >= 1 ? 1 : aspectRatio
        let spriteHeight: CGFloat = aspectRatio >= 1 ? 1 / aspectRatio : 1
        let plane = SCNPlane(width: spriteWidth, height: spriteHeight)
        plane.firstMaterial = material
        sprite.geometry = plane
        sprite.position.y = SCNFloat(spriteHeight / 2 + 0.06)

        let image = texture.frames[0].image
        material.diffuse.contents = image
        material.transparent.contents = image
        sprite.removeAction(forKey: "pet-animation")
        if texture.frames.count > 1 {
            sprite.runAction(petAnimationAction(texture, material: material), forKey: "pet-animation")
        }
    }

    private static func makeEnemy() -> (root: SCNNode, core: SCNNode, healthFill: SCNNode, healthLabel: SCNText) {
        let root = SCNNode()
        root.name = "backlog-wraith"
        root.position = SCNVector3(2.72, 0, -0.58)

        let orb = SCNSphere(radius: 0.88)
        orb.segmentCount = 72
        let orbMaterial = material(BattleNativeColor(red: 0.62, green: 0.025, blue: 0.03, alpha: 1), roughness: 0.34)
        orbMaterial.emission.contents = BattleNativeColor(red: 0.38, green: 0.035, blue: 0.01, alpha: 1)
        orbMaterial.emission.intensity = 0.55
        orb.firstMaterial = orbMaterial
        let core = SCNNode(geometry: orb)
        core.name = "enemy-core"
        core.position = SCNVector3(0, 1.08, 0)
        core.castsShadow = true
        root.addChildNode(core)

        for index in 0 ..< 9 {
            let angle = (Double(index) / 9.0) * Double.pi * 2
            let flame = SCNCone(topRadius: 0.04, bottomRadius: 0.20, height: 0.60)
            flame.firstMaterial = emissiveMaterial(
                index.isMultiple(of: 2)
                    ? BattleNativeColor(red: 1, green: 0.24, blue: 0.02, alpha: 1)
                    : BattleNativeColor(red: 1, green: 0.62, blue: 0.02, alpha: 1),
                intensity: 0.9
            )
            let flameNode = SCNNode(geometry: flame)
            flameNode.position = SCNVector3(cos(angle) * 0.73, 1.08 + sin(angle) * 0.73, -0.06)
            flameNode.eulerAngles.z = SCNFloat(angle - Double.pi / 2)
            flameNode.castsShadow = true
            root.addChildNode(flameNode)
        }

        let warning = SCNText(string: "!", extrusionDepth: 0.055)
        warning.font = BattleNativeFont.systemFont(ofSize: 72, weight: .black)
        warning.alignmentMode = CATextLayerAlignmentMode.center.rawValue
        warning.containerFrame = CGRect(x: -50, y: -46, width: 100, height: 100)
        warning.flatness = 0.12
        warning.firstMaterial = emissiveMaterial(BattleNativeColor.white, intensity: 0.4)
        let warningNode = SCNNode(geometry: warning)
        warningNode.scale = SCNVector3(0.014, 0.014, 0.014)
        warningNode.position = SCNVector3(0, 0.64, 0.84)
        core.addChildNode(warningNode)

        let hud = makeWorldHUD(
            role: "BACKLOG",
            title: "WRAITH",
            state: "100%",
            accent: BattleNativeColor(red: 1, green: 0.15, blue: 0.04, alpha: 1),
            maximumWidth: 2.65,
            healthFraction: 1
        )
        hud.root.position = SCNVector3(0, 2.74, 0.07)
        root.addChildNode(hud.root)
        return (root, core, hud.healthFill, hud.stateText)
    }

    private static func makeWorldHUD(
        role: String,
        title: String,
        state: String,
        accent: BattleNativeColor,
        maximumWidth: CGFloat,
        healthFraction: CGFloat
    ) -> (root: SCNNode, healthFill: SCNNode, stateText: SCNText) {
        let root = SCNNode()
        root.name = "world-hud"
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        root.constraints = [billboard]

        let panelWidth = maximumWidth + 0.42
        let panelHeight: CGFloat = 0.72
        let border = SCNBox(
            width: panelWidth + 0.045,
            height: panelHeight + 0.045,
            length: 0.045,
            chamferRadius: 0.145
        )
        border.firstMaterial = emissiveMaterial(accent.withAlphaComponent(0.44), intensity: 0.12)
        let borderNode = SCNNode(geometry: border)
        borderNode.name = "panel-border"
        borderNode.position.z = -0.075
        root.addChildNode(borderNode)

        let panel = SCNBox(width: panelWidth, height: panelHeight, length: 0.065, chamferRadius: 0.13)
        panel.firstMaterial = material(BattleNativeColor(red: 0.018, green: 0.035, blue: 0.043, alpha: 0.94), roughness: 0.48)
        let panelNode = SCNNode(geometry: panel)
        panelNode.position.z = -0.04
        root.addChildNode(panelNode)

        let accentRail = SCNBox(width: 0.055, height: 0.40, length: 0.065, chamferRadius: 0.027)
        accentRail.firstMaterial = emissiveMaterial(accent, intensity: 0.34)
        let accentRailNode = SCNNode(geometry: accentRail)
        accentRailNode.name = "accent-rail"
        accentRailNode.position = SCNVector3(SCNFloat(-panelWidth / 2 + 0.105), 0.075, 0.025)
        root.addChildNode(accentRailNode)

        let textLeft = -maximumWidth / 2 + 0.05
        let textWidth = maximumWidth - 0.14
        let roleGeometry = makeText(role.uppercased(), size: 7, weight: .bold, color: accent, width: textWidth, alignment: .left)
        let roleNode = SCNNode(geometry: roleGeometry)
        roleNode.name = "role-text"
        roleNode.scale = SCNVector3(0.010, 0.010, 0.010)
        roleNode.position = SCNVector3(SCNFloat(textLeft), 0.215, 0.025)
        root.addChildNode(roleNode)

        let titleGeometry = makeText(title.uppercased(), size: 12, weight: .black, color: .white, width: textWidth, alignment: .left)
        let titleNode = SCNNode(geometry: titleGeometry)
        titleNode.name = "title-text"
        titleNode.scale = SCNVector3(0.011, 0.011, 0.011)
        titleNode.position = SCNVector3(SCNFloat(textLeft), 0.035, 0.03)
        root.addChildNode(titleNode)

        let stateGeometry = makeText(
            state.uppercased(),
            size: 7,
            weight: .bold,
            color: BattleNativeColor(white: 0.72, alpha: 1),
            width: textWidth,
            alignment: .right
        )
        let stateNode = SCNNode(geometry: stateGeometry)
        stateNode.name = "state-text"
        stateNode.scale = SCNVector3(0.010, 0.010, 0.010)
        stateNode.position = SCNVector3(SCNFloat(textLeft), 0.215, 0.03)
        root.addChildNode(stateNode)

        let barBorder = SCNBox(width: maximumWidth + 0.045, height: 0.17, length: 0.055, chamferRadius: 0.075)
        barBorder.firstMaterial = emissiveMaterial(accent.withAlphaComponent(0.38), intensity: 0.08)
        let barBorderNode = SCNNode(geometry: barBorder)
        barBorderNode.name = "bar-border"
        barBorderNode.position = SCNVector3(0, -0.235, 0.018)
        root.addChildNode(barBorderNode)

        let barBackground = SCNBox(width: maximumWidth, height: 0.13, length: 0.065, chamferRadius: 0.06)
        barBackground.firstMaterial = material(BattleNativeColor(red: 0.025, green: 0.055, blue: 0.065, alpha: 1), roughness: 0.62)
        let barBackgroundNode = SCNNode(geometry: barBackground)
        barBackgroundNode.position = SCNVector3(0, -0.235, 0.045)
        root.addChildNode(barBackgroundNode)

        let width = max(0.035, maximumWidth * healthFraction)
        let fillGeometry = SCNBox(width: width, height: 0.11, length: 0.075, chamferRadius: 0.05)
        fillGeometry.firstMaterial = emissiveMaterial(accent, intensity: 0.20)
        let healthFill = SCNNode(geometry: fillGeometry)
        healthFill.name = "health-fill"
        healthFill.position = SCNVector3(SCNFloat(-maximumWidth / 2 + width / 2), -0.235, 0.085)
        root.addChildNode(healthFill)

        CoFleetBattleHUDShadowPolicy.disableShadows(in: root)
        return (root, healthFill, stateGeometry)
    }

    private static func makeText(
        _ string: String,
        size: CGFloat,
        weight: BattleNativeFont.Weight,
        color: BattleNativeColor,
        width: CGFloat,
        alignment: CATextLayerAlignmentMode
    ) -> SCNText {
        let text = SCNText(string: string, extrusionDepth: size > 8 ? 0.012 : 0.008)
        text.font = BattleNativeFont.monospacedSystemFont(ofSize: size, weight: weight)
        text.alignmentMode = alignment.rawValue
        text.containerFrame = CGRect(x: 0, y: size > 8 ? -8 : -5, width: width / 0.010, height: size > 8 ? 20 : 12)
        text.flatness = 0.15
        text.firstMaterial = emissiveMaterial(color, intensity: 0.22)
        return text
    }

    private static func fallbackPetTexture(name: String) -> CoFleetBattlePetTexture? {
        let renderer = ImageRenderer(
            content: ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [CoFleetTheme.violet, CoFleetTheme.cyan.opacity(0.72)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 116, weight: .bold))
                    .foregroundStyle(.white)
                Text(name.prefix(1).uppercased())
                    .font(.system(size: 46, weight: .black, design: .rounded))
                    .foregroundStyle(.black.opacity(0.7))
                    .offset(x: 78, y: 78)
            }
            .frame(width: 256, height: 256)
        )
        renderer.scale = 2
        #if os(iOS)
        guard let image = renderer.uiImage?.cgImage else { return nil }
        #elseif os(macOS)
        guard let nativeImage = renderer.nsImage,
              let image = nativeImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #endif
        return CoFleetBattlePetTexture(image: image)
    }

    private static func petAnimationAction(_ texture: CoFleetBattlePetTexture, material: SCNMaterial) -> SCNAction {
        var actions: [SCNAction] = []
        var previousEndTime: TimeInterval = 0
        for frame in texture.frames {
            let image = frame.image
            actions.append(.run { _ in
                material.diffuse.contents = image
                material.transparent.contents = image
            })
            actions.append(.wait(duration: max(0.04, frame.endTime - previousEndTime)))
            previousEndTime = frame.endTime
        }
        return .repeatForever(.sequence(actions))
    }

    private static func healthColor(_ fraction: CGFloat) -> BattleNativeColor {
        switch fraction {
        case 0 ..< 0.3: BattleNativeColor(red: 0.96, green: 0.08, blue: 0.07, alpha: 1)
        case 0.3 ..< 0.65: BattleNativeColor(red: 1, green: 0.47, blue: 0.04, alpha: 1)
        default: BattleNativeColor(red: 0.16, green: 0.86, blue: 0.30, alpha: 1)
        }
    }

    private static func emitImpactParticles(from root: SCNNode) {
        let particles = SCNParticleSystem()
        particles.loops = false
        particles.birthRate = 720
        particles.emissionDuration = 0.11
        particles.particleLifeSpan = 0.48
        particles.particleLifeSpanVariation = 0.18
        particles.particleVelocity = 7.2
        particles.particleVelocityVariation = 2.8
        particles.spreadingAngle = 180
        particles.particleSize = 0.16
        particles.particleSizeVariation = 0.10
        particles.particleColor = BattleNativeColor(red: 1, green: 0.56, blue: 0.06, alpha: 1)
        particles.blendMode = .additive
        particles.emitterShape = SCNSphere(radius: 0.22)
        particles.birthLocation = .surface

        let emitter = SCNNode()
        emitter.position = SCNVector3(0, 1.1, 0.55)
        emitter.addParticleSystem(particles)
        root.addChildNode(emitter)
        emitter.runAction(.sequence([.wait(duration: 1), .removeFromParentNode()]))
    }

    private static func emissiveMaterial(_ color: BattleNativeColor, intensity: CGFloat) -> SCNMaterial {
        let result = material(color, roughness: 0.34)
        result.emission.contents = color
        result.emission.intensity = intensity
        return result
    }

    private static func makeScene(
        quality: CoFleetBattleSceneQualityProfile
    ) -> (scene: SCNScene, camera: SCNNode) {
        let scene = SCNScene()
        scene.background.contents = BattleNativeColor(red: 0.12, green: 0.35, blue: 0.28, alpha: 1)
        scene.fogColor = BattleNativeColor(red: 0.42, green: 0.66, blue: 0.48, alpha: 1)
        scene.fogStartDistance = 14
        scene.fogEndDistance = 31

        let floor = SCNNode(geometry: SCNFloor())
        floor.geometry?.firstMaterial = material(
            BattleNativeColor(red: 0.12, green: 0.48, blue: 0.18, alpha: 1),
            roughness: 0.94
        )
        floor.position.y = -0.12
        scene.rootNode.addChildNode(floor)

        addBattleTiles(to: scene.rootNode)
        addGrass(to: scene.rootNode)
        addForest(to: scene.rootNode)

        let camera = SCNNode()
        let cameraComponent = SCNCamera()
        let cameraConfiguration = CoFleetBattleCameraConfiguration.manada
        cameraComponent.focalLength = cameraConfiguration.focalLength
        cameraComponent.sensorHeight = cameraConfiguration.sensorHeight
        cameraComponent.wantsDepthOfField = quality.wantsDepthOfField
        cameraComponent.focusDistance = 15.2
        cameraComponent.fStop = 0.82
        cameraComponent.apertureBladeCount = 8
        cameraComponent.focalBlurSampleCount = quality.focalBlurSampleCount
        cameraComponent.zNear = 0.1
        cameraComponent.zFar = 80
        camera.camera = cameraComponent
        camera.position = cameraConfiguration.position
        camera.look(at: cameraConfiguration.target)
        scene.rootNode.addChildNode(camera)

        let key = SCNNode()
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.color = BattleNativeColor(red: 1, green: 0.91, blue: 0.69, alpha: 1)
        keyLight.intensity = 1_650
        keyLight.castsShadow = true
        keyLight.shadowRadius = 7
        keyLight.shadowColor = BattleNativeColor.black.withAlphaComponent(0.58)
        keyLight.shadowMapSize = CGSize(width: quality.shadowMapSize, height: quality.shadowMapSize)
        keyLight.automaticallyAdjustsShadowProjection = true
        keyLight.maximumShadowDistance = 28
        keyLight.orthographicScale = 18
        key.light = keyLight
        key.position = SCNVector3(4, 10, -7)
        key.look(at: SCNVector3(-1.5, 0, 1))
        scene.rootNode.addChildNode(key)

        let rim = SCNNode()
        let rimLight = SCNLight()
        rimLight.type = .omni
        rimLight.color = BattleNativeColor(red: 0.20, green: 0.72, blue: 1, alpha: 1)
        rimLight.intensity = 680
        rimLight.attenuationEndDistance = 23
        rim.light = rimLight
        rim.position = SCNVector3(5, 5, -7)
        scene.rootNode.addChildNode(rim)

        let ambient = SCNNode()
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.color = BattleNativeColor(red: 0.24, green: 0.34, blue: 0.28, alpha: 1)
        ambientLight.intensity = 520
        ambient.light = ambientLight
        scene.rootNode.addChildNode(ambient)
        return (scene, camera)
    }

    private static func addBattleTiles(to root: SCNNode) {
        let stone = material(BattleNativeColor(red: 0.69, green: 0.74, blue: 0.57, alpha: 1), roughness: 0.89)
        let grassA = material(BattleNativeColor(red: 0.24, green: 0.66, blue: 0.20, alpha: 1), roughness: 0.96)
        let grassB = material(BattleNativeColor(red: 0.18, green: 0.57, blue: 0.16, alpha: 1), roughness: 0.96)

        for x in -5 ... 5 {
            for z in -4 ... 4 {
                let isPath = abs(x) <= 1 || (z == 0 && abs(x) < 5) || (z == -2 && x > 0)
                let tile = SCNBox(width: 1.28, height: 0.10, length: 1.28, chamferRadius: 0.025)
                tile.firstMaterial = isPath ? stone : ((x + z).isMultiple(of: 2) ? grassA : grassB)
                let node = SCNNode(geometry: tile)
                node.position = SCNVector3(Float(x) * 1.30, isPath ? 0.02 : 0, Float(z) * 1.30 - 0.6)
                root.addChildNode(node)
            }
        }
    }

    private static func addGrass(to root: SCNNode) {
        let colors = [
            BattleNativeColor(red: 0.12, green: 0.49, blue: 0.14, alpha: 1),
            BattleNativeColor(red: 0.30, green: 0.72, blue: 0.18, alpha: 1),
        ]
        for index in 0 ..< 72 {
            let x = Float((index * 37) % 130) / 10 - 6.5
            let z = Float((index * 53) % 105) / 10 - 5.8
            guard abs(x) > 1.5 || index.isMultiple(of: 4) else { continue }
            let tuft = SCNPyramid(width: 0.12, height: 0.48, length: 0.12)
            tuft.firstMaterial = material(colors[index % colors.count], roughness: 1)
            let node = SCNNode(geometry: tuft)
            node.position = SCNVector3(x, 0.24, z)
            node.eulerAngles.y = SCNFloat(index % 5) * 0.42
            root.addChildNode(node)
        }
    }

    private static func addForest(to root: SCNNode) {
        let positions: [(Float, Float, Float)] = [
            (-7.0, -7.6, 1.1), (-5.2, -8.2, 1.25), (-3.2, -8.8, 1.1),
            (-1.1, -9.1, 1.35), (1.2, -9.0, 1.2), (3.5, -8.5, 1.3),
            (5.7, -8.0, 1.18), (7.4, -7.4, 1.3),
            (-8.4, 1.8, 1.15), (8.2, 1.2, 1.15), (-7.3, 4.7, 1.3), (7.0, 4.5, 1.25),
        ]
        for (index, value) in positions.enumerated() {
            root.addChildNode(tree(x: value.0, z: value.1, scale: value.2, variant: index))
        }
    }

    private static func tree(x: Float, z: Float, scale: Float, variant: Int) -> SCNNode {
        let tree = SCNNode()
        tree.position = SCNVector3(x, 0, z)
        tree.scale = SCNVector3(scale, scale, scale)

        let trunk = SCNBox(width: 0.38, height: 2, length: 0.38, chamferRadius: 0.035)
        trunk.firstMaterial = material(BattleNativeColor(red: 0.27, green: 0.12, blue: 0.06, alpha: 1), roughness: 1)
        let trunkNode = SCNNode(geometry: trunk)
        trunkNode.position.y = 1
        tree.addChildNode(trunkNode)

        let leafColors = [
            BattleNativeColor(red: 0.05, green: 0.35, blue: 0.13, alpha: 1),
            BattleNativeColor(red: 0.08, green: 0.48, blue: 0.16, alpha: 1),
            BattleNativeColor(red: 0.18, green: 0.58, blue: 0.18, alpha: 1),
        ]
        let clusters: [(Float, Float, Float, CGFloat)] = [
            (0, 2.35, 0, 1.18), (-0.72, 2.20, 0.08, 0.8),
            (0.68, 2.18, -0.02, 0.82), (0.06, 3.02, -0.08, 0.72),
        ]
        for (clusterIndex, cluster) in clusters.enumerated() {
            let leaves = SCNBox(width: cluster.3, height: cluster.3 * 0.86, length: cluster.3, chamferRadius: 0.16)
            leaves.firstMaterial = material(leafColors[(variant + clusterIndex) % leafColors.count], roughness: 0.92)
            let leafNode = SCNNode(geometry: leaves)
            leafNode.position = SCNVector3(cluster.0, cluster.1, cluster.2)
            leafNode.eulerAngles.y = SCNFloat(clusterIndex) * 0.24
            tree.addChildNode(leafNode)
        }
        return tree
    }

    private static func material(_ color: BattleNativeColor, roughness: CGFloat) -> SCNMaterial {
        let result = SCNMaterial()
        result.lightingModel = .physicallyBased
        result.diffuse.contents = color
        result.roughness.contents = roughness
        result.metalness.contents = 0.02
        return result
    }
}

@MainActor
enum CoFleetBattlePetBillboard {
    /// Camera-facing rotation belongs on a parent node. Keeping the mirrored
    /// sprite transform on its child avoids SceneKit's upside-down billboard
    /// solution while preserving the authored atlas orientation.
    static func makeContainer(for sprite: SCNNode) -> SCNNode {
        let container = SCNNode()
        container.name = "sprite-billboard"
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        container.constraints = [billboard]
        container.addChildNode(sprite)
        return container
    }
}

@MainActor
enum CoFleetBattleHUDShadowPolicy {
    /// Screen-facing status geometry is an overlay and must not participate in
    /// the directional shadow pass. Pet sprite planes keep castsShadow enabled.
    static func disableShadows(in root: SCNNode) {
        root.castsShadow = false
        root.enumerateChildNodes { node, _ in node.castsShadow = false }
    }
}
#endif
