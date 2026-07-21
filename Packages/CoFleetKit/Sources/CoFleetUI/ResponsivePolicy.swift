import Foundation

public enum CoFleetColumnCount: Int, Equatable, Sendable {
    case one = 1
    case two = 2
}

public enum CoFleetResponsivePolicy {
    public static func progressColumns(availableWidth: CGFloat) -> CoFleetColumnCount {
        availableWidth >= 760 ? .two : .one
    }

    public static func activeUsesSideBySide(availableWidth: CGFloat) -> Bool {
        availableWidth >= 820
    }

    public static func cardHeaderPlacesNotesBesideIdentity(availableWidth: CGFloat) -> Bool {
        availableWidth >= 430
    }
}
