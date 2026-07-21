import CoFleetUI
import SwiftUI

@main
struct CoFleetIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let controller: CoFleetAppController
    @StateObject private var watchRelay: CoFleetPhoneRelay

    init() {
        let controller = CoFleetAppController()
        self.controller = controller
        _watchRelay = StateObject(wrappedValue: CoFleetPhoneRelay(controller: controller))
    }

    var body: some Scene {
        WindowGroup {
            CoFleetAppSceneView(controller: controller)
                .task { await watchRelay.resumeAndPublish() }
                .onChange(of: controller.fleetStore.selectedProjectID) {
                    Task { await watchRelay.publishSnapshot() }
                }
                .onChange(of: controller.threadStore.selectedSessionID) {
                    Task { await watchRelay.publishSnapshot() }
                }
                .onChange(of: scenePhase) {
                    guard scenePhase == .active else { return }
                    Task { await watchRelay.resumeAndPublish() }
                }
        }
    }
}
