//  MacShell.swift
//  macOS-only app shell: sidebar navigation, immersive dark chrome, the
//  menu-bar "glance" agent (live boat status + actions, survives window close),
//  menu-bar commands + keyboard shortcuts, and the app delegate that keeps the
//  process alive window-less.

#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Sections

enum AppSection: String, CaseIterable, Identifiable {
    case autopilot   = "Autopilot"
    case chart       = "Chart"
    case instruments = "Instruments"
    case setup       = "Setup"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .autopilot:   "safari.fill"
        case .chart:       "map.fill"
        case .instruments: "gauge.medium"
        case .setup:       "gearshape.fill"
        }
    }
    var shortcut: KeyEquivalent {
        switch self {
        case .autopilot:   "1"
        case .chart:       "2"
        case .instruments: "3"
        case .setup:       "4"
        }
    }
}

@Observable @MainActor
final class AppRouter {
    var section: AppSection {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: "macSection") }
    }
    init() {
        section = AppSection(rawValue: UserDefaults.standard.string(forKey: "macSection") ?? "")
            ?? .chart
    }
}

// MARK: - Window chrome
//
// Unify the window with the app's dark identity: a navy background behind the
// (translucent) sidebar kills the desktop-wallpaper bleed, the title bar goes
// transparent for an edge-to-edge chart, and the frame is remembered across
// launches.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titlebarAppearsTransparent = true
            w.backgroundColor = NSColor(Color.bgPrimary)
            w.setFrameAutosaveName("MatauNavMain")
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Sidebar root

struct MacRootView: View {
    @Environment(AppRouter.self) private var router
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var router = router
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: Binding(
                get: { router.section },
                set: { if let s = $0 { router.section = s } }
            )) {
                ForEach(AppSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.symbol)
                        .tag(section)
                        .pointerCursor()
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)   // show the navy window bg, not wallpaper
            .safeAreaInset(edge: .bottom) { SidebarStatusFooter() }
        } detail: {
            Group {
                switch router.section {
                case .autopilot:   AutopilotView()
                case .chart:       ChartView()
                case .instruments: InstrumentsView()
                case .setup:       SetupView()
                }
            }
            .frame(minWidth: 640, minHeight: 480)
        }
        .background(WindowConfigurator())
    }
}

/// At-a-glance boat status pinned to the bottom of the sidebar: SignalK
/// connection + (when anchored) the watch state. Keeps the sparse sidebar useful.
struct SidebarStatusFooter: View {
    @Environment(SignalKService.self)     private var signalK
    @Environment(AppSettings.self)        private var settings
    @Environment(AnchorWatchService.self) private var anchorWatch
    @Environment(PiStateService.self)     private var piState
    @Environment(AnchorPiService.self)    private var piService
    @Environment(PredictWindService.self) private var predictWind

    var body: some View {
        let issues = SystemHealth.issues(signalK: signalK, piState: piState,
                                         piService: piService, predictWind: predictWind,
                                         settings: settings)
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Color.borderColor)
            HStack(spacing: 7) {
                Circle().fill(signalK.state.color).frame(width: 7, height: 7)
                Text(signalK.state.label)
                    .font(.caption).foregroundStyle(Color.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            // Anything ELSE degraded shows here — a green SignalK chip used
            // to hide a dead AIS/CPA feed or anchor daemon entirely.
            ForEach(issues.filter { $0.id != "SignalK" }) { issue in
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(Color.statusOrange)
                    Text("\(issue.id): \(issue.detail)")
                        .font(.caption2).foregroundStyle(Color.statusOrange)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
            }
            if settings.anchorActive {
                let ok = anchorWatch.activeAlarms.isEmpty
                HStack(spacing: 7) {
                    Image(systemName: ok ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(ok ? Color.statusGreen : Color.statusRed)
                    Text(ok ? String(format: "Anchor · %.0f m", anchorWatch.liveDistance) : "Anchor alarm")
                        .font(.caption)
                        .foregroundStyle(ok ? Color.textSecondary : Color.statusRed)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

// MARK: - Menu-bar agent

struct MenuBarLabel: View {
    @Environment(AppSettings.self)        private var settings
    @Environment(AnchorWatchService.self) private var anchorWatch

    var body: some View {
        if settings.anchorActive {
            Image(systemName: anchorWatch.activeAlarms.isEmpty
                  ? "smallcircle.filled.circle"
                  : "exclamationmark.triangle.fill")
        } else {
            Image(systemName: "location.north.circle")
        }
    }
}

/// The menu-bar "glance" panel — live boat status + quick actions, styled in the
/// app's card language. Lets the skipper read the boat from any app.
struct MenuBarContentView: View {
    @Environment(AppSettings.self)        private var settings
    @Environment(SignalKService.self)     private var signalK
    @Environment(AnchorWatchService.self) private var anchorWatch
    @Environment(\.openWindow)            private var openWindow

    private var hasFix: Bool { signalK.latitude != 0 || signalK.longitude != 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if settings.anchorActive { anchorBanner }
            statsGrid
            Divider().overlay(Color.borderColor)
            actions
        }
        .padding(16)
        .frame(width: 320)
        .background(Color.bgPrimary)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("Matau Nav").font(.headline).foregroundStyle(Color.textPrimary)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(signalK.state.color).frame(width: 7, height: 7)
                Text(signalK.state.label).font(.caption).foregroundStyle(Color.textSecondary)
            }
        }
    }

    private var anchorBanner: some View {
        let ok = anchorWatch.activeAlarms.isEmpty
        return HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.statusGreen : Color.statusRed)
            VStack(alignment: .leading, spacing: 1) {
                Text("Anchor watch on").font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(ok
                     ? String(format: "%.0f m from anchor", anchorWatch.liveDistance)
                     : anchorWatch.activeAlarms.map(\.rawValue).joined(separator: ", "))
                    .font(.caption).foregroundStyle(ok ? Color.textSecondary : Color.statusRed)
            }
            Spacer()
        }
        .padding(10)
        .background((ok ? Color.statusGreen : Color.statusRed).opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var statsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            stat("Position", hasFix
                 ? Instrument.formatDDM(lat: signalK.latitude, lon: signalK.longitude, compact: true)
                 : "No GPS fix",
                 color: hasFix ? .textPrimary : .textTertiary)
            HStack(spacing: 0) {
                stat("SOG", String(format: "%.1f kn", signalK.speedOverGround)).frame(maxWidth: .infinity, alignment: .leading)
                stat("COG", String(format: "%.0f°T", signalK.courseOverGround)).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 0) {
                stat("Depth", signalK.depth > 0 ? String(format: "%.1f m", signalK.depth) : "—")
                    .frame(maxWidth: .infinity, alignment: .leading)
                stat("Wind", signalK.trueWindSpeed > 0
                     ? String(format: "%.1f kn  %+.0f°", signalK.trueWindSpeed, signalK.trueWindAngle)
                     : "—")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func stat(_ label: String, _ value: String, color: Color = .textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(Color.textSecondary)
                .textCase(.uppercase).tracking(0.6)
            Text(value).font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(color)
        }
    }

    @ViewBuilder private var actions: some View {
        if !anchorWatch.activeAlarms.isEmpty || AlarmPlayer.shared.isPlaying {
            Button {
                anchorWatch.snooze(minutes: 15)
            } label: {
                Label("Silence alarm (15 min)", systemImage: "bell.slash.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.statusRed)
            .pointerCursor()
        }

        Button {
            if settings.anchorActive {
                anchorWatch.raiseAnchor(settings: settings)
            } else {
                anchorWatch.dropAnchor(settings: settings, signalK: signalK)
            }
        } label: {
            Label(settings.anchorActive ? "Raise anchor" : "Drop anchor",
                  systemImage: "anchor")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .pointerCursor()

        HStack {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            } label: { Text("Show window").frame(maxWidth: .infinity) }
            .pointerCursor()

            Button("Quit") { NSApp.terminate(nil) }
                .pointerCursor()
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Menu bar commands

struct MatauCommands: Commands {
    let router:  AppRouter
    let monitor: AppMonitor
    let chartBridge: ChartBridge

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}   // single-instance app

        // Chart view controls, added into the standard View menu.
        CommandGroup(after: .sidebar) {
            Button("Zoom In")  { chartBridge.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { chartBridge.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Divider()
            Button(monitor.settings.chartFollowVessel ? "Stop Following Vessel" : "Follow Vessel") {
                monitor.settings.chartFollowVessel.toggle()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }

        CommandMenu("Go") {
            ForEach(AppSection.allCases) { section in
                Button(section.rawValue) { router.section = section }
                    .keyboardShortcut(section.shortcut, modifiers: .command)
            }
        }

        CommandMenu("Anchor") {
            Button(monitor.settings.anchorActive ? "Raise Anchor" : "Drop Anchor") {
                if monitor.settings.anchorActive {
                    monitor.anchorWatch.raiseAnchor(settings: monitor.settings)
                } else {
                    monitor.anchorWatch.dropAnchor(settings: monitor.settings,
                                                   signalK: monitor.signalK)
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("Silence Alarm") { monitor.anchorWatch.snooze(minutes: 15) }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(monitor.anchorWatch.activeAlarms.isEmpty && !AlarmPlayer.shared.isPlaying)
        }
    }
}

// MARK: - App delegate

/// Keeps the process (and the anchor-watch loop in AppMonitor) alive after the
/// main window closes — the menu-bar item remains, like a real agent.
final class MatauAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
#endif
