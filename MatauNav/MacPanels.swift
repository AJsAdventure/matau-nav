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

// MARK: - Anchor side panel (anchor-mode bottom-left card)

/// The anchor console as a floating card that grows from the BOTTOM up and
/// takes only the vertical space its content needs — the chart (and the
/// swing circle) stays visible behind it. Everything the iOS bottom console
/// shows, plus the recent alarm log and inline forecast/settings.
struct AnchorSidePanel: View {
    @Environment(AppSettings.self)        private var settings
    @Environment(SignalKService.self)     private var signalK
    @Environment(AnchorWatchService.self) private var anchorWatch
    @Environment(AnchorPiService.self)    private var piService
    @Environment(PredictWindService.self) private var predictWind
    @Environment(ChartBridge.self)        private var chartBridge
    @Environment(MacShellState.self)      private var shell

    @State private var showWizard         = false
    @State private var showSafeTonight    = false
    @State private var showAnchorSettings = false
    @State private var confirmRaise       = false
    /// Planned rode for the one-step drop (seeded from settings).
    @State private var rode: Double = 30

    var body: some View {
        VStack(spacing: 0) {
            header
            // Hug the content; fall back to scrolling only when the window
            // is genuinely too short for it.
            ViewThatFits(in: .vertical) {
                inner
                ScrollView(.vertical, showsIndicators: false) { inner }
            }
        }
        .frame(width: 372)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.bgPrimary.opacity(0.94))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.borderColor, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
        )
        .onAppear { rode = settings.anchorRodeLength > 0 ? settings.anchorRodeLength : 30 }
        .sheet(isPresented: $showWizard) {
            AnchorWizardSheet(settings: settings, signalK: signalK,
                              anchorWatch: anchorWatch) { coord in
                focusChart(on: coord)
                Task { await predictWind.armForecastForAnchor(settings: settings) }
            }
        }
        .sheet(isPresented: $showSafeTonight) {
            SafeTonightSheet(
                settings: settings, predictWind: predictWind,
                anchorLat: settings.anchorActive ? settings.anchorLat : signalK.latitude,
                anchorLon: settings.anchorActive ? settings.anchorLon : signalK.longitude)
        }
        .sheet(isPresented: $showAnchorSettings) {
            AnchorSettingsSheetWithForecast(
                settings: settings, anchorWatch: anchorWatch,
                piService: piService, predictWind: predictWind, signalK: signalK)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AnchorMark()
                .frame(width: 14, height: 14)
                .foregroundStyle(Color.textSecondary)
            Text("ANCHOR")
                .font(.footnote.weight(.semibold)).tracking(0.8)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Button {
                withAnimation(.spring(duration: 0.3)) { shell.leftCollapsed = true }
            } label: {
                Image(systemName: "chevron.down.2")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Collapse panel (⌘1)")
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 2)
    }

    private var inner: some View {
        VStack(spacing: 12) {
            if settings.anchorActive {
                if !anchorWatch.activeAlarms.isEmpty { alarmBar }
                statusCard
                metrics
                watchFooter
                actions
                if !anchorWatch.alarmLog.isEmpty { logCard }
            } else {
                planning
            }
        }
        .padding(14)
    }

    private var state: AnchorWatchService.HoldState { anchorWatch.holdState(settings: settings) }
    private var hasLiveFix: Bool {
        signalK.boatPositionIsLive || anchorWatch.freshDeviceCoord != nil
    }

    // MARK: Status

    private var stateStyle: (label: String, color: Color) {
        switch state {
        case .idle:     ("NOT ANCHORED", .textTertiary)
        case .holding:  ("HOLDING",      .statusGreen)
        case .warning:  ("WARNING",      .statusOrange)
        case .dragging: ("DRAGGING",     .statusRed)
        }
    }

    private var statusCard: some View {
        let s = stateStyle
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                AnchorMark()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(s.color)
                Text(s.label)
                    .font(.headline.weight(.bold)).tracking(1.2)
                    .foregroundStyle(s.color)
                Spacer()
            }
            Text(anchorWatch.swingDiagnosis(settings: settings))
                .font(.caption).foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(s.color.opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(state == .dragging || state == .warning ? s.color : .clear, lineWidth: 1.5))
    }

    private var alarmBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
            Text(anchorWatch.activeAlarms.map(\.rawValue).joined(separator: " · "))
                .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .lineLimit(2).minimumScaleFactor(0.8)
            Spacer()
            Button("Snooze") { anchorWatch.snooze(minutes: 15) }
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.white, in: Capsule())
                .buttonStyle(.plain)
                .pointerCursor()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.statusRed, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Metrics

    private var metrics: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.0f", anchorWatch.liveDistance))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(state == .dragging ? Color.statusRed
                                     : state == .warning ? Color.statusOrange : Color.textPrimary)
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

            row("Bearing to anchor", String(format: "%03.0f°", anchorWatch.liveBearing))
            row("Alarm radius",
                String(format: "%.0f m · max swing %.0f m", settings.anchorRadius, anchorWatch.maxSwing))
            row("Depth", depthLabel)
            row("Wind", windLabel, valueColor: windOverLimit ? .statusRed : .textPrimary)
            row("Scope", scopeLabel)
            row("Position source",
                signalK.boatPositionIsLive ? "Boat GPS"
                : anchorWatch.freshDeviceCoord != nil ? "Mac GPS (backup)" : "NO FIX",
                valueColor: signalK.boatPositionIsLive ? .textPrimary
                : anchorWatch.freshDeviceCoord != nil ? .statusOrange : .statusRed)
            if let b = SystemPower.battery() {
                row("Mac battery",
                    String(format: "%.0f%% · %@", b.level * 100, b.onAC ? "on power" : "ON BATTERY"),
                    valueColor: b.onAC ? .textPrimary : .statusOrange)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var depthLabel: String {
        guard signalK.depth > 0 else { return "—" }
        var s = String(format: "%.1f m", signalK.depth)
        if let base = anchorWatch.depthBaseline {
            let d = signalK.depth - base
            if d >  0.3 { s += String(format: "  ↑ %.1f", abs(d)) }
            else if d < -0.3 { s += String(format: "  ↓ %.1f", abs(d)) }
            else { s += "  steady" }
        }
        return s
    }

    private var windLabel: String {
        guard signalK.trueWindSpeed > 0 else { return "—" }
        let shift = anchorWatch.windShift(settings: settings, signalK: signalK)
        return String(format: "%.0f kt  %03.0f° · shift %+.0f°",
                      signalK.trueWindSpeed, signalK.trueWindDirection, shift)
    }

    private var windOverLimit: Bool {
        settings.anchorWindMax < 60 && signalK.trueWindSpeed > settings.anchorWindMax
    }

    private var scopeLabel: String {
        guard settings.anchorRodeLength > 0, signalK.depth > 0.3 else { return "—" }
        return String(format: "%.1f:1  (%.0f m rode)",
                      settings.anchorRodeLength / signalK.depth, settings.anchorRodeLength)
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

    // MARK: Footer + actions

    private var watchFooter: some View {
        HStack(spacing: 10) {
            if settings.anchorDropTime > 0 {
                let since = Date(timeIntervalSince1970: settings.anchorDropTime)
                Text("Since \(since.formatted(date: .omitted, time: .shortened)) · \(anchorWatch.minutesWatched(settings: settings)) min")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
            // Auto-learned swing: once the boat has shown its true swing for a
            // while, offer to shrink the alarm circle to what was observed.
            if let suggested = anchorWatch.observedSwingRadius(settings: settings),
               anchorWatch.minutesWatched(settings: settings) >= 20,
               suggested + 3 < settings.anchorRadius {
                Button {
                    settings.anchorRadius = max(5, min(200, suggested))
                    settings.persist()
                    Task { await piService.syncConfig(settings: settings) }
                } label: {
                    Label("Tighten to \(Int(suggested)) m", systemImage: "scope")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.accentCyan, in: Capsule())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Shrink the alarm radius to the swing actually observed")
            }
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
            .buttonStyle(.borderedProminent).tint(Color.statusRed)
            .pointerCursor()
        }
        sheetButtons
        Button {
            confirmRaise = true
        } label: {
            Label("Raise anchor", systemImage: "arrow.up.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .pointerCursor()
        .confirmationDialog("Raise the anchor?", isPresented: $confirmRaise,
                            titleVisibility: .visible) {
            Button("Raise Anchor — stop the watch", role: .destructive) {
                anchorWatch.raiseAnchor(settings: settings)
            }
            Button("Keep Watching", role: .cancel) {}
        } message: {
            Text("This stops the anchor watch and all its alarms.")
        }
    }

    private var sheetButtons: some View {
        HStack(spacing: 8) {
            Button {
                anchorWatch.recenterAnchor(settings: settings, signalK: signalK)
                focusChart(on: .init(latitude: settings.anchorLat, longitude: settings.anchorLon))
            } label: {
                Label("Re-centre", systemImage: "scope").frame(maxWidth: .infinity)
            }
            .disabled(settings.anchorRodeLength <= 0 || !hasLiveFix)
            .help("Settled back on the chain? Shift the anchor up-rode from where the boat lies now — the accurate centre.")
            Button {
                showSafeTonight = true
            } label: {
                Label("Tonight", systemImage: "moon.stars.fill").frame(maxWidth: .infinity)
            }
            .help("Tonight's wind forecast verdict for this anchorage")
            Button {
                showAnchorSettings = true
            } label: {
                Label("Alarms", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
            }
            .help("Anchor + forecast alarm settings")
        }
        .buttonStyle(.bordered)
        .pointerCursor()
    }

    // MARK: Recent events

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT EVENTS")
                .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(Color.textTertiary)
            ForEach(anchorWatch.alarmLog.prefix(6)) { event in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(event.time.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.textTertiary)
                    Text(event.detail)
                        .font(.caption).foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Planning (pre-drop) — the whole swinging-anchor "wizard" inline:
    // set the rode, see the circle, one click to drop. Re-centre afterwards
    // replaces the old walk-through's fall-back/recompute steps.

    private var planning: some View {
        VStack(spacing: 12) {
            // Live conditions + tonight's verdict, mirroring the iOS console.
            HStack(spacing: 8) {
                planStat("DEPTH", signalK.depth > 0 ? String(format: "%.1f m", signalK.depth) : "—")
                planStat("WIND", String(format: "%.0f kt", signalK.trueWindSpeed),
                         sub: String(format: "%03.0f°", signalK.trueWindDirection))
                Button { showSafeTonight = true } label: {
                    let v = AnchorForecast.verdict(forecast: predictWind.forecast, settings: settings)
                    planStat("TONIGHT", v.word, valueColor: v.color)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Tonight's wind forecast verdict — click for details")
            }

            VStack(spacing: 6) {
                HStack {
                    Text("Rode to pay out").font(.caption).foregroundStyle(Color.textSecondary)
                    Spacer()
                    Text(String(format: "%.0f m", rode))
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                }
                Slider(value: $rode, in: 5...120, step: 5).tint(Color.statusOrange)
                HStack {
                    Text(scopePreview).font(.caption).foregroundStyle(Color.textTertiary)
                    Spacer()
                    Text("Watch radius \(Int(plannedRadius)) m")
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.statusOrange)
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button { dropNow() } label: {
                HStack(spacing: 7) {
                    AnchorMark().frame(width: 18, height: 18)
                    Text("Drop Anchor")
                }
                .font(.headline).foregroundStyle(.black)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(hasLiveFix ? Color.statusOrange : Color.statusOrange.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(!hasLiveFix)
            .help("Arm the watch right here — swing circle sized from rode + depth")

            if !hasLiveFix {
                Label("Waiting for a GPS fix (boat feed or this Mac).",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Color.statusOrange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Settle back on the chain, then hit Re-centre to shift the anchor up-rode. Right-click the chart for Set Anchor Here.")
                .font(.caption2).foregroundStyle(Color.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button { showWizard = true } label: {
                    Label("Fixed mooring", systemImage: "arrow.left.and.right.circle")
                        .frame(maxWidth: .infinity)
                }
                .help("Stern-to, two anchors, lines ashore — tight watch box, no swing circle")
                Button { showAnchorSettings = true } label: {
                    Label("Alarms", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .help("Anchor + forecast alarm settings")
            }
            .buttonStyle(.bordered)
            .pointerCursor()
        }
    }

    private var plannedRadius: Double {
        let scope = AnchorWatchService.horizontalScope(rode: rode, depth: signalK.depth)
        return max(5, min(100, (scope + settings.anchorBowOffset + 6).rounded()))
    }

    private var scopePreview: String {
        signalK.depth > 0.3
            ? String(format: "Scope %.1f:1 at %.1f m depth", rode / signalK.depth, signalK.depth)
            : "Depth unknown — radius from rode alone"
    }

    private func dropNow() {
        settings.anchorRodeLength  = rode
        settings.anchorWarnRadius  = 0            // auto (75 %)
        settings.anchorRadius      = plannedRadius
        guard let pos = anchorWatch.dropAnchorAtCurrentPosition(settings: settings,
                                                                signalK: signalK) else { return }
        focusChart(on: pos)
        Task { await predictWind.armForecastForAnchor(settings: settings) }
    }

    private func planStat(_ label: String, _ value: String, sub: String? = nil,
                          valueColor: Color = .textPrimary) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold)).tracking(0.6)
                .foregroundStyle(Color.textTertiary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(valueColor)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let sub {
                Text(sub)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Drop plumbing

    private func focusChart(on coord: CLLocationCoordinate2D) {
        let span = MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
        chartBridge.zoomProxy?.mapView?.setRegion(.init(center: coord, span: span),
                                                  animated: true)
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
