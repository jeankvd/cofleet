import CoFleetCore
import SwiftUI

public struct CoFleetPetPlaceholder: View {
    private let name: String
    private let size: CGFloat

    public init(name: String, size: CGFloat = 58) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [CoFleetTheme.violet.opacity(0.72), CoFleetTheme.cyan.opacity(0.48)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "shippingbox.fill")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(.white)
            Text(name.prefix(1).uppercased())
                .font(.system(size: size * 0.18, weight: .black, design: .rounded))
                .foregroundStyle(.black.opacity(0.72))
                .offset(x: size * 0.24, y: size * 0.23)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("No pet selected for \(name)")
    }
}

public struct CoFleetStatusIndicators: View {
    public var reachability: CoFleetReachability
    public var action: CoFleetActionIndicator
    public var sourceControl: CoFleetSourceControlStatus?

    public init(
        reachability: CoFleetReachability,
        action: CoFleetActionIndicator,
        sourceControl: CoFleetSourceControlStatus?
    ) {
        self.reachability = reachability
        self.action = action
        self.sourceControl = sourceControl
    }

    public var body: some View {
        HStack(spacing: 6) {
            indicator(color: reachabilityColor, label: "Host \(reachability.rawValue)", symbol: "network")
            indicator(color: actionColor, label: actionLabel, symbol: actionSymbol)
            indicator(color: CoFleetTheme.cyan, label: "Codex", symbol: "terminal.fill")
            indicator(color: sourceColor, label: sourceLabel, symbol: sourceSymbol)
        }
        .labelStyle(.iconOnly)
    }

    private func indicator(color: Color, label: String, symbol: String) -> some View {
        let base = ZStack {
            Circle().fill(color.opacity(0.18))
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel(label)
        #if os(watchOS)
        return base
        #else
        return base.help(label)
        #endif
    }

    private var reachabilityColor: Color {
        switch reachability {
        case .online: CoFleetTheme.green
        case .degraded: CoFleetTheme.orange
        case .offline, .unknown: .gray
        }
    }

    private var actionColor: Color {
        switch action {
        case .approvalNeeded, .questionAsked: CoFleetTheme.orange
        case .replied: CoFleetTheme.green
        case .idle: .secondary
        default: CoFleetTheme.violet
        }
    }

    private var actionSymbol: String {
        switch action {
        case .idle: "pause.fill"
        case .thinking, .reasoning: "brain.head.profile"
        case .runningCommand: "terminal"
        case .approvalNeeded: "hand.raised.fill"
        case .questionAsked: "questionmark"
        case .working: "hammer.fill"
        case .replied: "checkmark"
        }
    }

    private var actionLabel: String {
        switch action {
        case .runningCommand: "Running command"
        case .approvalNeeded: "Approval needed"
        case .questionAsked: "Question asked"
        default: action.rawValue
        }
    }

    private var sourceColor: Color {
        switch sourceControl?.state {
        case .clean: CoFleetTheme.green
        case .dirty, .staged, .unpushed: CoFleetTheme.orange
        case .draftPullRequest, .openPullRequest: CoFleetTheme.cyan
        default: .gray
        }
    }

    private var sourceSymbol: String {
        switch sourceControl?.kind {
        case .git: "arrow.triangle.branch"
        case .plastic: "square.stack.3d.up.fill"
        case .some(.none), nil: "questionmark.folder"
        }
    }

    private var sourceLabel: String {
        guard let sourceControl else { return "Source control unavailable" }
        return "\(sourceControl.kind.rawValue) \(sourceControl.state.rawValue)"
    }
}

public extension CoFleetProjectState {
    var actionIndicator: CoFleetActionIndicator {
        switch self {
        case .idle: .idle
        case .working: .working
        case .waitingForApproval: .approvalNeeded
        case .waitingForAnswer: .questionAsked
        case .replied: .replied
        case .unavailable: .idle
        }
    }
}
