import Foundation

#if !os(watchOS)
public enum CoFleetColumnCount: Int, Equatable, Sendable {
    case one = 1
    case two = 2
}

public enum CoFleetActivePresentation: Equatable, Sendable {
    case sideBySide
    case vertical
}

/// Compatibility facade for callers that need to reason about the same layout
/// decisions used by the concrete Progress and Active views.
public enum CoFleetResponsivePolicy {
    public static func progressColumns(availableWidth: CGFloat) -> CoFleetColumnCount {
        CoFleetProgressLayoutPolicy.columnCount(availableWidth: availableWidth) == 2 ? .two : .one
    }

    public static var activePresentation: CoFleetActivePresentation {
        #if os(macOS)
        .sideBySide
        #else
        .vertical
        #endif
    }
}
#endif
