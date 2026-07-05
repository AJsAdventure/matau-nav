import SwiftUI

struct ContentView: View {
    @Environment(AppSettings.self)  private var settings
    @Environment(\.colorScheme)     private var colorScheme

    var body: some View {
        content
            .tint(settings.nightMode ? Color(red: 1.0, green: 0.18, blue: 0.18) : .accentCyan)
            // Night mode: multiply all pixels by bright red → white text becomes red, backgrounds stay dark
            .colorMultiply(settings.nightMode
                ? Color(red: 1.0, green: 0.22, blue: 0.22)
                : .white)
            #if os(iOS)
            // Sync night mode with system color scheme on each app launch.
            // (On macOS the system appearance is a global Light/Dark preference,
            // not a day/night sailing signal, so night mode is driven manually.)
            .onAppear {
                settings.nightMode = (colorScheme == .dark)
                settings.persist()
            }
            #endif
    }

    @ViewBuilder private var content: some View {
        #if os(macOS)
        MacRootView()
        #else
        TabView {
            Tab("Autopilot", systemImage: "safari.fill") {
                AutopilotView()
            }
            Tab("Chart", systemImage: "map.fill") {
                ChartView()
            }
            Tab("Instruments", systemImage: "gauge.medium") {
                InstrumentsView()
            }
            Tab("Setup", systemImage: "gearshape.fill") {
                SetupView()
            }
        }
        #endif
    }
}
