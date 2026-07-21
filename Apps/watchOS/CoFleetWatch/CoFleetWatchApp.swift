import CoFleetUI
import SwiftUI

@main
struct CoFleetWatchApp: App {
    @StateObject private var relay = CoFleetWatchRelay()

    var body: some Scene {
        WindowGroup {
            CoFleetWatchRootView(
                snapshot: relay.snapshot,
                onSend: relay.send,
                onToggleTodo: relay.toggleTodo
            )
            .alert(
                "Couldn’t send",
                isPresented: Binding(
                    get: { relay.lastErrorMessage != nil },
                    set: { if !$0 { relay.dismissError() } }
                )
            ) {
                Button("OK") { relay.dismissError() }
            } message: {
                Text(relay.lastErrorMessage ?? "Try again from iPhone.")
            }
        }
    }
}
