//  MacShell.swift
//  macOS-only app shell: sidebar navigation, immersive dark chrome, the
//  menu-bar "glance" agent (live boat status + actions, survives window close),
//  menu-bar commands + keyboard shortcuts, and the app delegate that keeps the
//  process alive window-less.

#if os(macOS)
import SwiftUI
import AppKit

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

// MARK: - Chart-centric root
//
// ONE space: the chart fills the window; the left panel is Autopilot (sail
// mode) or the anchor console (anchor mode); the right panel is Instruments.
// Panels are floating glass cards implemented as safe-area insets, so the
// chart's own chrome (top bar, rails, readouts) automatically avoids them
// while the map itself runs edge-to-edge underneath.

struct MacRootView: View {
    @Environment(AppSettings.self)   private var settings
    @Environment(MacShellState.self) private var shell

    var body: some View {
        @Bindable var shell = shell
        ChartView()
            .environment(\.macPanelShell, true)
            .safeAreaInset(edge: .leading, spacing: 0) {
                SidePanel(title: settings.isAnchorMode ? "Anchor" : "Autopilot",
                          symbol: settings.isAnchorMode ? "circle.dashed" : "safari.fill",
                          edge: .leading,
                          collapsed: $shell.leftCollapsed) {
                    if settings.isAnchorMode {
                        AnchorSidePanel()
                    } else {
                        AutopilotView()
                    }
                }
            }
            .safeAreaInset(edge: .trailing, spacing: 0) {
                SidePanel(title: "Instruments",
                          symbol: "gauge.medium",
                          edge: .trailing,
                          collapsed: $shell.rightCollapsed) {
                    InstrumentsView()
                }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    MacStatusStrip()
                    SettingsFAB()
                }
                .padding(.leading, 14)
                .padding(.bottom, 14)
            }
            .sheet(isPresented: $shell.showSettings) {
                MacSettingsSheet()
            }
            .frame(minWidth: 980, minHeight: 620)
            .background(Color.bgPrimary)
            .background(WindowConfigurator())
    }
}

/// SetupView wrapped for sheet presentation with an explicit Done control —
/// macOS sheets need a simple titled button, and Esc must always work.
struct MacSettingsSheet: View {
    @Environment(MacShellState.self) private var shell

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Setup").font(.headline).foregroundStyle(Color.textPrimary)
                Spacer()
                Button("Done") { shell.showSettings = false }
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.bgPrimary)
            Divider().overlay(Color.borderColor)
            SetupView()
        }
        .frame(width: 740, height: 660)
        .preferredColorScheme(.dark)
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
    let shell:   MacShellState
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

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { shell.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Panels") {
            Button(shell.leftCollapsed ? "Show Left Panel" : "Hide Left Panel") {
                shell.leftCollapsed.toggle()
            }
            .keyboardShortcut("1", modifiers: .command)
            Button(shell.rightCollapsed ? "Show Instruments" : "Hide Instruments") {
                shell.rightCollapsed.toggle()
            }
            .keyboardShortcut("2", modifiers: .command)
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
