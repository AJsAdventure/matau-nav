import SwiftUI

@main
struct MatauNavWatchApp: App {
    @State private var pi = WatchPiClient()

    init() {
        // Wire WatchConnectivity callbacks BEFORE activating the session so
        // we don't miss the cached applicationContext that fires on first
        // delegate callback.
        WatchSessionBridge.shared.onState = { [pi] dict in
            Task { @MainActor in pi.apply(dict) }
        }
        WatchSessionBridge.shared.onReachability = { [pi] r in
            Task { @MainActor in pi.setReachable(r) }
        }
        WatchSessionBridge.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            AutopilotWatchView()
                .environment(pi)
                .preferredColorScheme(.dark)
        }
    }
}
