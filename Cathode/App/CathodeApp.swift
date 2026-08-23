import SwiftUI

@main
struct CathodeApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
                .tint(.good)
                .task { await model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Polling the dish once a second is wasteful while backgrounded, and
            // iOS will suspend the task anyway. Stop cleanly and resume on return.
            switch phase {
            case .active:
                Task { await model.start() }
                UIApplication.shared.isIdleTimerDisabled = model.settings.keepScreenAwake
            case .background, .inactive:
                model.stop()
                UIApplication.shared.isIdleTimerDisabled = false
            @unknown default:
                break
            }
        }
    }
}
