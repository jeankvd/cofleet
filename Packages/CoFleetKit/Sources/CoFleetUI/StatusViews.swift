import CoFleetCore
import SwiftUI
import WidgetKit

public struct CoFleetPetPlaceholder: View {
    private let name: String
    private let size: CGFloat

    public init(name: String, size: CGFloat = 58) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        placeholder
            .frame(width: size, height: size)
            .accessibilityLabel("No pet selected for \(name)")
    }

    private var placeholder: some View {
        ZStack {
            fullColorNeutralSymbol
            Text(name.prefix(1).uppercased())
                .font(.system(size: size * 0.18, weight: .black, design: .rounded))
                .foregroundStyle(.black.opacity(0.72))
                .offset(x: size * 0.24, y: size * 0.23)
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    @ViewBuilder
    private var fullColorNeutralSymbol: some View {
        if #available(iOS 18.0, macOS 15.0, watchOS 11.0, *) {
            Image(systemName: "pawprint.circle.fill")
                .symbolRenderingMode(.palette)
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
                .scaledToFit()
                .foregroundStyle(.white, placeholderGradient)
        } else {
            Image(systemName: "pawprint.circle.fill")
                .symbolRenderingMode(.palette)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white, placeholderGradient)
        }
    }

    private var placeholderGradient: LinearGradient {
        LinearGradient(
            colors: [CoFleetTheme.violet.opacity(0.88), CoFleetTheme.cyan.opacity(0.72)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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
        HStack(spacing: indicatorSpacing) {
            Circle()
                .fill(reachabilityColor)
                .frame(width: availabilitySize, height: availabilitySize)
                .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 0.7))
                .accessibilityLabel("Host \(reachability.rawValue)")

            indicatorBall(color: actionColor, label: actionLabel, symbol: actionSymbol)

            ZStack {
                Circle().fill(CoFleetTheme.green.opacity(0.9))
                CoFleetCodexMark()
                    .foregroundStyle(.black.opacity(0.82))
                    .padding(providerMarkPadding)
            }
            .frame(width: indicatorSize, height: indicatorSize)
            .accessibilityLabel("Codex")

            indicatorBall(color: sourceColor, label: sourceLabel, symbol: sourceSymbol)
        }
        .labelStyle(.iconOnly)
    }

    private func indicatorBall(color: Color, label: String, symbol: String) -> some View {
        let base = ZStack {
            Circle().fill(color.opacity(0.9))
            Image(systemName: symbol)
                .font(.system(size: glyphSize, weight: .black))
                .foregroundStyle(.black.opacity(0.78))
                .minimumScaleFactor(0.45)
        }
        .frame(width: indicatorSize, height: indicatorSize)
        .accessibilityLabel(label)
        #if os(watchOS)
        return base
        #else
        return base.help(label)
        #endif
    }

    private var indicatorSpacing: CGFloat {
        #if os(watchOS)
        2
        #else
        4
        #endif
    }

    private var availabilitySize: CGFloat {
        #if os(watchOS)
        7
        #else
        9
        #endif
    }

    private var indicatorSize: CGFloat {
        #if os(watchOS)
        10
        #else
        16
        #endif
    }

    private var glyphSize: CGFloat {
        #if os(watchOS)
        5.5
        #else
        8
        #endif
    }

    private var providerMarkPadding: CGFloat {
        #if os(watchOS)
        2
        #else
        3
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

/// A font-independent Codex knot that remains legible in the Watch's smallest
/// provider ball and does not depend on a private or third-party image asset.
private struct CoFleetCodexMark: View {
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            CoFleetCodexKnotShape()
                .stroke(
                    .foreground,
                    style: StrokeStyle(
                        lineWidth: max(0.7, side * 0.13),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: side, height: side)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct CoFleetCodexKnotShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height)

        func point(radius normalizedRadius: CGFloat, angle: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + cos(angle) * radius * normalizedRadius,
                y: center.y + sin(angle) * radius * normalizedRadius
            )
        }

        for index in 0..<6 {
            let angle = CGFloat(index) * .pi / 3 - .pi / 2
            path.move(to: point(radius: 0.14, angle: angle - .pi / 7))
            path.addCurve(
                to: point(radius: 0.25, angle: angle + .pi / 3),
                control1: point(radius: 0.38, angle: angle - .pi / 12),
                control2: point(radius: 0.43, angle: angle + .pi / 5)
            )
        }
        return path
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

public extension CoFleetProjectActivity {
    var actionIndicator: CoFleetActionIndicator {
        switch self {
        case .idle: .idle
        case .thinking: .thinking
        case .reasoning: .reasoning
        case .runningCommand: .runningCommand
        case .approval: .approvalNeeded
        case .question: .questionAsked
        case .replied: .replied
        }
    }
}
