import SwiftUI

public enum CoFleetTheme {
    public static let background = Color(red: 0.025, green: 0.035, blue: 0.045)
    public static let surface = Color(red: 0.07, green: 0.085, blue: 0.10)
    public static let elevated = Color(red: 0.105, green: 0.12, blue: 0.14)
    public static let panelFill = Color.white.opacity(0.075)
    public static let subtleFill = Color.white.opacity(0.045)
    public static let hairline = Color.white.opacity(0.09)
    public static let cyan = Color(red: 0.10, green: 0.72, blue: 0.92)
    public static let violet = Color(red: 0.68, green: 0.22, blue: 0.92)
    public static let green = Color(red: 0.18, green: 0.82, blue: 0.45)
    public static let orange = Color(red: 1.0, green: 0.52, blue: 0.14)
    public static let danger = Color(red: 0.95, green: 0.24, blue: 0.30)
}

public struct CoFleetPanelModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .padding(14)
            .background(CoFleetTheme.panelFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(CoFleetTheme.hairline, lineWidth: 1)
            }
    }
}

public extension View {
    func coFleetPanel() -> some View { modifier(CoFleetPanelModifier()) }
}
