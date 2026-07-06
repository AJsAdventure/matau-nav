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

/// Floating glass card that hosts a panel; collapses to a slim handle so the
/// chart can take the full window when wanted.
struct SidePanel<Content: View>: View {
    let title: String
    let symbol: String
    let edge: HorizontalEdge
    @Binding var collapsed: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if collapsed {
                collapsedHandle
            } else {
                VStack(spacing: 0) {
                    header
                    content()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .frame(width: 372)
                .background(panelBackground)
            }
        }
        .padding(.vertical, 10)
        .padding(edge == .leading ? .leading : .trailing, 10)
        .animation(.spring(duration: 0.3), value: collapsed)
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
        .padding(.vertical, 8)
    }

    private var collapseButton: some View {
        Button {
            collapsed = true
        } label: {
            Image(systemName: edge == .leading ? "chevron.left.2" : "chevron.right.2")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.textTertiary)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Collapse panel")
    }

    private var collapsedHandle: some View {
        Button {
            collapsed = false
        } label: {
            VStack(spacing: 10) {
                Image(systemName: edge == .leading ? "chevron.right.2" : "chevron.left.2")
                    .font(.caption.weight(.bold))
                Image(systemName: symbol)
                    .font(.footnote)
            }
            .foregroundStyle(Color.textSecondary)
            .frame(width: 26)
            .frame(maxHeight: .infinity)
            .background(panelBackground)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Expand \(title)")
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.bgPrimary.opacity(0.92))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.borderColor, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
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
