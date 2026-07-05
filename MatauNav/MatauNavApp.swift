import SwiftUI

@main
struct MatauNavApp: App {
    // All services + the long-lived monitoring loops live here so the macOS
    // menu-bar agent keeps the anchor watch running even with no window open.
    @State private var monitor = AppMonitor()

    #if os(macOS)
    @State private var router = AppRouter()
    @State private var chartBridge = ChartBridge()
    @NSApplicationDelegateAdaptor(MatauAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        Window("Matau Nav", id: "main") {
            rootView
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)        // edge-to-edge chart; unified dark chrome
        .commands { MatauCommands(router: router, monitor: monitor, chartBridge: chartBridge) }

        // Menu-bar agent: a live "glance" panel with boat status + actions. Stays
        // present after the main window closes, keeping the process (and the
        // anchor watch) alive.
        MenuBarExtra {
            MenuBarContentView()
                .environment(monitor.settings)
                .environment(monitor.signalK)
                .environment(monitor.anchorWatch)
        } label: {
            MenuBarLabel()
                .environment(monitor.settings)
                .environment(monitor.anchorWatch)
        }
        .menuBarExtraStyle(.window)
        #else
        WindowGroup {
            rootView
        }
        #endif
    }

    @ViewBuilder private var rootView: some View {
        ContentView()
            .environment(monitor.settings)
            .environment(monitor.signalK)
            .environment(monitor.anchorWatch)
            .environment(monitor.piService)
            .environment(monitor.piState)
            .environment(monitor.tracks)
            .environment(monitor.bathymetry)
            .environment(monitor.contours)
            .environment(monitor.predictWind)
            #if os(macOS)
            .environment(router)
            .environment(chartBridge)
            #endif
            .preferredColorScheme(.dark)
            .task { monitor.start() }
    }
}
