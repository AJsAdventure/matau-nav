//  MacPanels.swift
//  macOS chart-centric shell furniture: the two side panels that float over
//  the chart (autopilot / anchor on the left, instruments on the right), the
//  status strip, and the floating settings button.
//
//  Design intent: ONE space. The chart is the app; everything else is glass
//  furniture on top of it, switched by the existing Sail ⇄ Anchor mode. The
//  panels reuse the phone-sized AutopilotView / InstrumentsView unchanged —
//  they were designed for ~380 pt widths, which is exactly a side panel.

#if os(macOS)
import SwiftUI
import MapKit
import CoreLocation

// MARK: - Shell state

@Observable @MainActor
final class MacShellState {
    var showSettings = false
    var leftCollapsed: Bool {
        didSet { UserDefaults.standard.set(leftCollapsed, forKey: "macLeftCollapsed") }
    }
    var rightCollapsed: Bool {
        didSet { UserDefaults.standard.set(rightCollapsed, forKey: "macRightCollapsed") }
    }
    init() {
        leftCollapsed  = UserDefaults.standard.bool(forKey: "macLeftCollapsed")
        rightCollapsed = UserDefaults.standard.bool(forKey: "macRightCollapsed")
    }
}

// MARK: - Panel chrome

/// Full-height docked glass column hosting a panel. Runs all the way to the
/// top of the window (under the transparent title bar); only the inner edge
/// is rounded. Collapse is handled by the shell (round edge buttons).
struct SidePanel<Content: View>: View {
    let title: String
    let symbol: String
    let edge: HorizontalEdge
    @Binding var collapsed: Bool
    @ViewBuilder var content: () -> Content

    private var innerCorners: RectangleCornerRadii {
        edge == .leading
            ? .init(topLeading: 0, bottomLeading: 0, bottomTrailing: 14, topTrailing: 14)
            : .init(topLeading: 14, bottomLeading: 14, bottomTrailing: 0, topTrailing: 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 372)
        .frame(maxHeight: .infinity)
        .background(
            UnevenRoundedRectangle(cornerRadii: innerCorners, style: .continuous)
                .fill(Color.bgPrimary.opacity(0.94))
                .overlay(UnevenRoundedRectangle(cornerRadii: innerCorners, style: .continuous)
                    .stroke(Color.borderColor, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 0)
        )
        .clipShape(UnevenRoundedRectangle(cornerRadii: innerCorners, style: .continuous))
        .ignoresSafeArea(edges: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if edge == .trailing { collapseButton }
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
                .textCase(.uppercase).tracking(0.8)
            Spacer(minLength: 0)
            if edge == .leading { collapseButton }
        }
        .padding(.horizontal, 12)
        // The left column sits under the traffic lights — clear them.
        .padding(.top, edge == .leading ? 34 : 12)
        .padding(.bottom, 8)
    }

    private var collapseButton: some View {
        Button {
            withAnimation(.spring(duration: 0.3)) { collapsed = true }
        } label: {
            Image(systemName: edge == .leading ? "chevron.left.2" : "chevron.right.2")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.textTertiary)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Collapse panel")
    }
}

/// Round edge button shown at the vertical centre of the window edge while a
/// panel is collapsed — click to bring the panel back.
struct PanelToggleFAB<Icon: View>: View {
    let edge: HorizontalEdge
    let help: String
    let action: () -> Void
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        Button(action: action) {
            icon()
                .foregroundStyle(Color.textPrimary)
                .frame(width: 46, height: 46)
                .background(Color.bgPrimary.opacity(0.9), in: Circle())
                .overlay(Circle().stroke(Color.borderColor, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 2)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
        .padding(edge == .leading ? .leading : .trailing, 12)
    }
}

// MARK: - Window top bar: MOB + Sail⇄Anchor switch
//
// Lives as a window-level overlay so it stays dead-centre no matter which
// panels are expanded (safe-area insets would drift a chart-hosted switch).

struct MacTopBar: View {
    @Environment(AppSettings.self)    private var settings
    @Environment(SignalKService.self) private var signalK
    @Environment(PiStateService.self) private var piState
    @Environment(ChartBridge.self)    private var chartBridge
    @State private var confirmClearMOB = false

    var body: some View {
        HStack(spacing: 10) {
            mobButton
            modeSwitch
        }
        .padding(.top, 10)
    }

    // MARK: MOB — instant to SET (an emergency button must not ask
    // questions), confirmed to CLEAR (clearing by accident loses the spot).
    private var mobButton: some View {
        Button {
            if settings.mobActive {
                confirmClearMOB = true
            } else {
                let lat = signalK.latitude, lon = signalK.longitude
                guard lat != 0 || lon != 0 else { return }
                Task { await piState.setMOB(lat: lat, lon: lon) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "figure.fall")
                    .font(.system(size: 14, weight: .bold))
                Text("MOB").font(.system(size: 13, weight: .heavy)).tracking(0.5)
            }
            .foregroundStyle(settings.mobActive ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(settings.mobActive ? Color.statusRed : Color.statusRed.opacity(0.55),
                        in: Capsule())
            .overlay(Capsule().stroke(Color.statusRed, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(settings.mobActive ? "Clear man-overboard mark" : "Mark man overboard at current position")
        .confirmationDialog("Clear the man-overboard mark?",
                            isPresented: $confirmClearMOB, titleVisibility: .visible) {
            Button("Clear MOB", role: .destructive) { Task { await piState.clearMOB() } }
            Button("Keep", role: .cancel) {}
        }
    }

    // MARK: Sail ⇄ Anchor (same behaviour as ChartView's own toggle,
    // including the map refocus on entering anchor mode via ChartBridge)
    private var modeSwitch: some View {
        HStack(spacing: 3) {
            segment(mode: "sail",   label: "Sail",   tint: .accentCyan, anchorGlyph: false)
            segment(mode: "anchor", label: "Anchor", tint: .statusOrange, anchorGlyph: true)
        }
        .padding(4)
        .glassBackground(active: false, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
    }

    private func segment(mode: String, label: String, tint: Color, anchorGlyph: Bool) -> some View {
        let on = settings.chartMode == mode
        return Button { setChartMode(mode) } label: {
            HStack(spacing: 5) {
                if anchorGlyph {
                    AnchorMark().frame(width: 15, height: 15)
                } else {
                    Image(systemName: "sailboat.fill").font(.system(size: 14, weight: .bold))
                }
                Text(label).font(.system(size: 13, weight: .bold)).fixedSize()
            }
            .foregroundStyle(on ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(on ? tint : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func setChartMode(_ mode: String) {
        guard settings.chartMode != mode else { return }
        withAnimation(.spring(duration: 0.3)) {
            settings.chartMode = mode
            settings.persist()
        }
        if mode == "anchor" {
            let center = settings.anchorActive
                ? CLLocationCoordinate2D(latitude: settings.anchorLat, longitude: settings.anchorLon)
                : CLLocationCoordinate2D(latitude: signalK.latitude, longitude: signalK.longitude)
            if center.latitude != 0 || center.longitude != 0 {
                let span = MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
                chartBridge.zoomProxy?.mapView?.setRegion(.init(center: center, span: span),
                                                          animated: true)
            }
        }
    }
}

// MARK: - Anchor side panel (anchor-mode left panel)

/// Compact anchor console for the left panel — the glanceable numbers plus
/// the two actions that matter. Detailed setup (wizard, forecast, rode
/// geometry) stays with the chart's own anchor-mode UI.
struct AnchorSidePanel: View {
    @Environment(AppSettings.self)        private var settings
    @Environment(SignalKService.self)     private var signalK
    @Environment(AnchorWatchService.self) private var anchorWatch

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                statusPill
                if settings.anchorActive {
                    metrics
                    if !anchorWatch.activeAlarms.isEmpty { alarmList }
                    actions
                } else {
                    planning
                }
            }
            .padding(14)
        }
        .background(Color.bgPrimary)
    }

    private var state: AnchorWatchService.HoldState { anchorWatch.holdState(settings: settings) }

    private var statusPill: some View {
        let (label, color): (String, Color) = switch state {
        case .idle:     ("NOT ANCHORED", .textTertiary)
        case .holding:  ("HOLDING",      .statusGreen)
        case .warning:  ("WARNING",      .statusOrange)
        case .dragging: ("DRAGGING",     .statusRed)
        }
        return HStack(spacing: 8) {
            AnchorMark()
                .frame(width: 16, height: 16)
                .foregroundStyle(color)
            Text(label)
                .font(.headline.weight(.bold)).tracking(1.2)
                .foregroundStyle(color)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(color.opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var metrics: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.0f", anchorWatch.liveDistance))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.textPrimary)
                    .contentTransition(.numericText())
                Text("m from anchor")
                    .font(.subheadline).foregroundStyle(Color.textSecondary)
                Spacer()
            }
            // Distance vs alarm radius at a glance.
            GeometryReader { geo in
                let frac = min(1, anchorWatch.liveDistance / max(1, settings.anchorRadius))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.borderColor.opacity(0.6))
                    Capsule()
                        .fill(state == .dragging ? Color.statusRed
                              : state == .warning ? Color.statusOrange : Color.statusGreen)
                        .frame(width: max(6, geo.size.width * frac))
                }
            }
            .frame(height: 6)

            row("Bearing to anchor", String(format: "%.0f°", anchorWatch.liveBearing))
            row("Alarm radius",      String(format: "%.0f m", settings.anchorRadius))
            row("Max swing",         String(format: "%.0f m", anchorWatch.maxSwing))
            row("Depth", signalK.depth > 0 ? String(format: "%.1f m", signalK.depth) : "—")
            row("Wind", signalK.trueWindSpeed > 0
                ? String(format: "%.1f kn  %.0f°", signalK.trueWindSpeed, signalK.trueWindDirection)
                : "—")
            row("Position source",
                signalK.boatPositionIsLive ? "Boat GPS"
                : anchorWatch.freshDeviceCoord != nil ? "Device GPS" : "NO FIX",
                valueColor: signalK.boatPositionIsLive ? .textPrimary
                : anchorWatch.freshDeviceCoord != nil ? .statusOrange : .statusRed)
            Text(anchorWatch.swingDiagnosis(settings: settings))
                .font(.caption).foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ label: String, _ value: String, valueColor: Color = .textPrimary) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(Color.textSecondary)
            Spacer()
            Text(value)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundStyle(valueColor)
        }
    }

    private var alarmList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(anchorWatch.activeAlarms), id: \.self) { alarm in
                Label(alarm.rawValue, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.statusRed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.statusRed.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var actions: some View {
        if !anchorWatch.activeAlarms.isEmpty || AlarmPlayer.shared.isPlaying {
            Button {
                anchorWatch.snooze(minutes: 15)
            } label: {
                Label("Silence alarm (15 min)", systemImage: "bell.slash.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Color.statusRed)
            .pointerCursor()
        }
        Button {
            anchorWatch.raiseAnchor(settings: settings)
        } label: {
            Label("Raise anchor", systemImage: "arrow.up.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .pointerCursor()
    }

    private var planning: some View {
        VStack(spacing: 12) {
            Text("Anchor mode: pick the spot on the chart, check the forecast, then drop.")
                .font(.callout).foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                anchorWatch.dropAnchor(settings: settings, signalK: signalK)
            } label: {
                HStack {
                    AnchorMark().frame(width: 16, height: 16)
                    Text("Drop Anchor Here")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .pointerCursor()
            .disabled(!signalK.boatPositionIsLive && anchorWatch.freshDeviceCoord == nil)
        }
        .padding(14)
        .background(Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Status strip + settings button (bottom-left of the chart)

struct MacStatusStrip: View {
    @Environment(SignalKService.self)     private var signalK
    @Environment(AppSettings.self)        private var settings
    @Environment(PiStateService.self)     private var piState
    @Environment(AnchorPiService.self)    private var piService
    @Environment(PredictWindService.self) private var predictWind

    var body: some View {
        let issues = SystemHealth.issues(signalK: signalK, piState: piState,
                                         piService: piService, predictWind: predictWind,
                                         settings: settings)
        HStack(spacing: 7) {
            Circle()
                .fill(issues.isEmpty ? Color.statusGreen : signalK.state.isConnected
                      ? Color.statusOrange : Color.statusRed)
                .frame(width: 7, height: 7)
            Text(issues.isEmpty ? signalK.state.label
                 : "\(issues[0].id): \(issues[0].detail)" + (issues.count > 1 ? "  +\(issues.count - 1)" : ""))
                .font(.caption).foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Color.bgPrimary.opacity(0.85), in: Capsule())
        .overlay(Capsule().stroke(Color.borderColor, lineWidth: 1))
    }
}

struct SettingsFAB: View {
    @Environment(MacShellState.self) private var shell

    var body: some View {
        Button {
            shell.showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .frame(width: 42, height: 42)
                .background(Color.bgPrimary.opacity(0.88), in: Circle())
                .overlay(Circle().stroke(Color.borderColor, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Settings (⌘,)")
        .keyboardShortcut(",", modifiers: .command)
    }
}
#endif
