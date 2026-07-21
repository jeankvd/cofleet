import CoFleetUI
import SwiftUI

@main
struct CoFleetMacApp: App {
    @State private var controller = CoFleetAppController()

    var body: some Scene {
        WindowGroup("CoFleet for Codex") {
            CoFleetAppSceneView(controller: controller)
                .frame(minWidth: 860, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)

        Settings {
            NavigationStack { CoFleetLegalView() }
                .frame(width: 640, height: 560)
        }
    }
}
