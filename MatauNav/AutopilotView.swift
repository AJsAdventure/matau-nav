import SwiftUI

// MARK: - Main view

struct AutopilotView: View {
    @Environment(SignalKService.self)  private var signalK
    @Environment(AppSettings.self)    private var settings
    @Environment(AnchorPiService.self) private var piService
    @Environment(PiStateService.self)  private var piState

    /// User's local pending mode pick. When the autopilot is engaged this is
    /// kept in sync with the Pi's reported mode via `.onChange(piState.autopilotMode)`.
    @State private var autopilotMode: AutopilotMode = .compass

    /// Mode to display in the switcher. Engaged → Pi truth. Standby → user pick.
    private var displayedMode: AutopilotMode {
        guard signalK.autopilotEngaged else { return autopilotMode }
        switch piState.autopilotMode {
        case "wind":     return .wind
        case "waypoint": return .waypoint
        default:         return .compass
        }
    }
    @State private var editingCorner: CornerSlot?
    @State private var apCommandPending = false
    @State private var apErrorMessage: String? = nil
    /// Rolling buffer of raw TWA samples — smoothed over 3 s (6 × 500 ms polls)
    @State private var twaBuffer: [Double] = []
    /// AWA locked when autopilot engaged in WIND mode
    @State private var lockedWindAngle: Double? = nil

    /// Circular mean of twaBuffer — handles ±180° wraparound cleanly
    private var smoothedTWA: Double {
        guard !twaBuffer.isEmpty else { return signalK.trueWindAngle }
        let sinSum = twaBuffer.map { sin($0 * .pi / 180) }.reduce(0, +)
        let cosSum = twaBuffer.map { cos($0 * .pi / 180) }.reduce(0, +)
        return atan2(sinSum, cosSum) * 180 / .pi
    }

    enum AutopilotMode: String, CaseIterable {
        case compass  = "COMPASS"
        case wind     = "WIND"
        case waypoint = "WAYPOINT"
    }

    enum CornerSlot: String, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgPrimary.ignoresSafeArea()
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    roseSection
                    Spacer(minLength: 0)
                    autopilotControls
                }
            }
            .navigationTitle("Autopilot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        let lat = signalK.latitude, lon = signalK.longitude
                        Task { await piState.setMOB(lat: lat, lon: lon) }
                    } label: {
                        Text("MOB")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(settings.mobActive ? Color.statusRed : Color.statusRed.opacity(0.55))
                    }
                    .contextMenu {
                        if settings.mobActive {
                            Button(role: .destructive) {
                                Task { await piState.clearMOB() }
                            } label: {
                                Label("Cancel MOB", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editingCorner) { slot in
            InstrumentPickerSheet(slot: slot, settings: settings)
        }
        .onChange(of: signalK.trueWindAngle) { _, newVal in
            twaBuffer.append(newVal)
            if twaBuffer.count > 6 { twaBuffer.removeFirst() }  // 6 × 0.5 s = 3 s
        }
        .task {
            // Pull canonical autopilot state from the Pi the moment the view
            // appears so we don't briefly render "Standby" while the next
            // 2-second poll is still pending.
            await piState.refreshNow()
            syncLocalModeFromPi()
        }
        .onChange(of: piState.autopilotMode) { _, _ in syncLocalModeFromPi() }
        .onChange(of: piState.autopilotLockedWindAngle ?? .nan) { _, v in
            if !v.isNaN { lockedWindAngle = v }
        }
    }

    private func syncLocalModeFromPi() {
        switch piState.autopilotMode {
        case "wind":
            autopilotMode = .wind
            if lockedWindAngle == nil { lockedWindAngle = signalK.apparentWindAngle }
        case "compass":  autopilotMode = .compass
        case "waypoint": autopilotMode = .waypoint
        default:         break    // standby — keep user's pending pick
        }
    }

    // MARK: - Rose section

    private var roseSection: some View {
        ZStack(alignment: .center) {
            // Corner data labels — top corners get extra top padding so rose sits lower
            VStack {
                HStack(alignment: .top) {
                    CornerLabel(
                        instrument: Instrument(rawValue: settings.cornerTopLeft) ?? .sog,
                        signalK: signalK,
                        settings: settings,
                        alignment: .leading
                    ) { editingCorner = .topLeft }
                    Spacer()
                    CornerLabel(
                        instrument: Instrument(rawValue: settings.cornerTopRight) ?? .twa,
                        signalK: signalK,
                        settings: settings,
                        alignment: .trailing
                    ) { editingCorner = .topRight }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    CornerLabel(
                        instrument: Instrument(rawValue: settings.cornerBottomLeft) ?? .twd,
                        signalK: signalK,
                        settings: settings,
                        alignment: .leading
                    ) { editingCorner = .bottomLeft }
                    Spacer()
                    CornerLabel(
                        instrument: Instrument(rawValue: settings.cornerBottomRight) ?? .tws,
                        signalK: signalK,
                        settings: settings,
                        alignment: .trailing
                    ) { editingCorner = .bottomRight }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 12)

            // Extra top padding shifts the rose downward, freeing space for corner labels
            WindRose(
                heading: signalK.headingMagnetic,
                trueWindAngle: smoothedTWA,
                apparentWindAngle: signalK.apparentWindAngle,
                rudderAngle: signalK.rudderAngle,
                targetHeading: signalK.autopilotEngaged ? signalK.targetHeading : nil,
                waypointBearing: settings.waypointActive
                    ? signalK.bearing(toLat: settings.waypointLat, lon2: settings.waypointLon)
                    : nil,

                mobBearing: settings.mobActive
                    ? signalK.bearing(toLat: settings.mobLat, lon2: settings.mobLon)
                    : nil,
                cogHistory: signalK.cogHistory
            )
            .padding(.horizontal, 28)
            .padding(.top, 46)    // pushes rose down — more space for top corner labels
            .padding(.bottom, 28)
            .allowsHitTesting(false)
        }
        .aspectRatio(1, contentMode: .fit)
        // Cap height so controls are never pushed off-screen on any phone size
        .frame(maxHeight: 370)
    }

    // MARK: - Target heading display (compass mode: degrees, wind mode: locked angle)

    /// Returns (display text, portCorrecting, starboardCorrecting)
    private var targetHeadingInfo: (text: String, port: Bool, stbd: Bool) {
        let threshold = 2.0
        if displayedMode == .wind {
            // Locked angle is known when this app commanded wind mode; when the
            // pilot was engaged at the physical unit we estimate with the
            // current apparent wind (the vane holds whatever it saw at engage).
            let locked = lockedWindAngle ?? signalK.apparentWindAngle
            let diff = locked - signalK.apparentWindAngle
            let text = "\(String(format: "%.0f°", abs(locked)))\(locked >= 0 ? "S" : "P")"
            return (text, diff < -threshold, diff > threshold)
        } else {
            let target = signalK.targetHeading
            var d = (target - signalK.headingMagnetic).truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 }
            if d < -180 { d += 360 }
            return (String(format: "%03.0f°", target), d < -threshold, d > threshold)
        }
    }

    // MARK: - Controls

    private var autopilotControls: some View {
        VStack(spacing: 10) {
            // MOB distance bar — always visible when active. Waypoint
            // navigation lives on the Chart tab; the Autopilot tab is for
            // pure steering, not goal tracking.
            if settings.mobActive {
                HStack(spacing: 16) {
                    Spacer()
                    if settings.mobActive {
                        let dist = signalK.distanceTo(lat: settings.mobLat, lon: settings.mobLon)
                        HStack(spacing: 5) {
                            MOBIcon(color: .statusRed, size: 13)
                            Text(dist < 1 ? String(format: "%.2f nm", dist) : String(format: "%.1f nm", dist))
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.statusRed)
                                .contentTransition(.numericText())
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .background(Color.bgElevated)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.borderColor, lineWidth: 0.5))
                .padding(.horizontal, 20)
            }

            // Row 1: COMPASS / WIND / WAYPOINT mode toggle.
            // WAYPOINT is only selectable when a route is active on the Pi.
            // While engaged, tapping a different mode switches the AP live.
            let hasRoute = settings.activeRoute != nil
            HStack {
                HStack(spacing: 0) {
                    ForEach(AutopilotMode.allCases, id: \.self) { mode in
                        let unavailable = mode == .waypoint && !hasRoute
                        Button {
                            guard !unavailable else { return }
                            withAnimation(.easeInOut(duration: 0.18)) { autopilotMode = mode }
                            if signalK.autopilotEngaged && displayedMode != mode {
                                Task {
                                    let cmd: String = switch mode {
                                    case .wind:     "wind_auto"
                                    case .waypoint: "waypoint_auto"
                                    case .compass:  "compass_auto"
                                    }
                                    await sendApCmd(cmd)
                                }
                            }
                        } label: {
                            Text(mode.rawValue)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(
                                    unavailable ? Color.textTertiary.opacity(0.4) :
                                    displayedMode == mode ? .black : Color.textSecondary
                                )
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(displayedMode == mode && !unavailable
                                            ? Color.accentCyan : Color.clear)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(Color.bgElevated)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.borderColor, lineWidth: 0.5))
                Spacer()
            }
            .padding(.horizontal, 20)

            // Row 2: Target heading — always visible. Shows "STBY" when disengaged.
            let engaged = signalK.autopilotEngaged
            let info    = targetHeadingInfo
            HStack(spacing: 16) {
                Spacer()
                if engaged {
                    Image(systemName: "arrowtriangle.left.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(info.port ? Color.statusRed : Color.textTertiary.opacity(0.25))
                        .animation(.easeInOut(duration: 0.2), value: info.port)
                }
                Text(engaged ? info.text : "STBY")
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundStyle(engaged ? Color.textPrimary : Color.textTertiary)
                    .contentTransition(.numericText())
                if engaged {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(info.stbd ? Color.statusGreen : Color.textTertiary.opacity(0.25))
                        .animation(.easeInOut(duration: 0.2), value: info.stbd)
                }
                Spacer()
            }
            .padding(.horizontal, 20)

            // Row 3: Control buttons — flexible widths so they never overflow on any screen
            // In WAYPOINT mode the Pi owns the heading; +/- are disabled.
            let headingButtonsDisabled = !signalK.autopilotEngaged || apCommandPending
                                      || displayedMode == .waypoint
            HStack(spacing: 6) {
                HeadingButton(label: "<<", sublabel: "10°", tint: .statusRed,
                              disabled: headingButtonsDisabled) {
                    Task { await sendApCmd("minus10") }
                }
                HeadingButton(label: "<", sublabel: "1°", tint: .statusRed,
                              disabled: headingButtonsDisabled) {
                    Task { await sendApCmd("minus1") }
                }

                Button {
                    Task {
                        guard !apCommandPending else { return }
                        if signalK.autopilotEngaged {
                            await sendApCmd("standby")
                        } else {
                            signalK.targetHeading = signalK.headingMagnetic
                            let engageCmd: String = switch autopilotMode {
                            case .wind:     "wind_auto"
                            case .waypoint: "waypoint_auto"
                            case .compass:  "compass_auto"
                            }
                            await sendApCmd(engageCmd)
                        }
                    }
                } label: {
                    ZStack {
                        if apCommandPending {
                            ProgressView().tint(signalK.autopilotEngaged ? Color.statusGreen : Color.textSecondary)
                        } else {
                            VStack(spacing: 4) {
                                Text(signalK.autopilotEngaged ? "STBY" : "AUTO")
                                    .font(.system(size: 13, weight: .bold))
                                Circle()
                                    .fill(signalK.autopilotEngaged ? Color.statusGreen : Color.textTertiary)
                                    .frame(width: 7, height: 7)
                            }
                        }
                    }
                    .frame(width: 62, height: 48)
                    .background(
                        signalK.autopilotEngaged
                            ? Color.statusGreen.opacity(0.15)
                            : Color.bgElevated
                    )
                    .foregroundStyle(signalK.autopilotEngaged ? Color.statusGreen : Color.textSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                signalK.autopilotEngaged
                                    ? Color.statusGreen.opacity(0.4)
                                    : Color.borderColor,
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(apCommandPending)

                HeadingButton(label: ">", sublabel: "1°", tint: .statusGreen,
                              disabled: headingButtonsDisabled) {
                    Task { await sendApCmd("plus1") }
                }
                HeadingButton(label: ">>", sublabel: "10°", tint: .statusGreen,
                              disabled: headingButtonsDisabled) {
                    Task { await sendApCmd("plus10") }
                }
            }
            .padding(.horizontal, 12)

            // Row 3.5: vane reset — the remote equivalent of pressing
            // Standby+Auto together on the ST8002. Acknowledges the pilot's
            // own WINDSHIFT alarm and re-trims the vane to the current wind,
            // so nobody has to physically walk to the helm unit.
            if displayedMode == .wind && signalK.autopilotEngaged {
                Button {
                    Task { await resetVane() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wind.circle")
                            .font(.system(size: 15, weight: .bold))
                        Text("RESET VANE")
                            .font(.system(size: 12, weight: .bold)).tracking(0.6)
                    }
                    .foregroundStyle(Color.statusOrange)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(Color.statusOrange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.statusOrange.opacity(0.4), lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(apCommandPending)
                .pointerCursor()
                .help("Acknowledge WINDSHIFT and re-trim the vane (same as pressing Standby+Auto on the pilot)")
                .padding(.horizontal, 12)
            }

            // Row 4: Pi connection status + error
            HStack(spacing: 6) {
                Circle()
                    .fill(piStatusColor)
                    .frame(width: 6, height: 6)
                Text(piStatusLabel)
                    .font(.caption2)
                    .foregroundStyle(Color.textTertiary)
            }
            .padding(.horizontal, 20)

            if let err = apErrorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Color.statusRed)
                    .padding(.horizontal, 20)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 28)
        .padding(.top, 6)
    }

    private var piStatusColor: Color {
        switch piService.connectionState {
        case .connected:    .statusGreen
        case .disconnected: .statusRed
        case .unknown:      .textTertiary
        }
    }

    private var piStatusLabel: String {
        switch piService.connectionState {
        case .connected:    piService.onTailscale ? "Pi · Tailscale" : "Pi · Connected"
        case .disconnected: "Pi · Unreachable — check Setup"
        case .unknown:      settings.effectiveAnchorPiURL.isEmpty ? "Pi · Not configured — go to Setup" : "Pi · Connecting…"
        }
    }

    // MARK: - Autopilot command helper

    @MainActor
    private func sendApCmd(_ cmd: String) async {
        apCommandPending = true
        apErrorMessage   = nil
        defer { apCommandPending = false }

        // Apply heading/wind-angle delta BEFORE the async round-trip so the
        // user sees an immediate response. The Pi returns a stale snapshot in
        // its command response (before the AP has processed the SeaTalk press),
        // and the Pi's /state poll may also lag by 1-2 s — suppressing poll
        // overwrites for a few seconds prevents the value from jumping back.
        switch cmd {
        case "plus1", "plus10", "minus1", "minus10":
            let delta: Double = cmd.contains("10") ? 10 : 1
            let sign:  Double = cmd.hasPrefix("plus") ? 1 : -1
            withAnimation {
                if displayedMode == .wind {
                    // Signed AWA convention: +starboard / −port. Turning to
                    // STARBOARD (plus keys) rotates the apparent wind toward
                    // port, i.e. the signed angle DECREASES — on starboard
                    // tack 34°S drops to 24°S, on port tack 34°P grows to
                    // 44°P. The old `+ sign*delta` ran the readout backwards.
                    lockedWindAngle = max(-180, min(180,
                        (lockedWindAngle ?? signalK.apparentWindAngle) - sign * delta))
                } else {
                    signalK.targetHeading = (signalK.targetHeading + sign * delta + 360)
                        .truncatingRemainder(dividingBy: 360)
                    piState.suppressHeadingUpdates()
                }
            }
        default: break
        }

        let ok = await piState.sendAutopilotCommand(cmd)
        if ok {
            withAnimation {
                switch cmd {
                case "auto", "compass_auto", "waypoint_auto":
                    signalK.autopilotEngaged = true
                    lockedWindAngle = nil
                case "wind_auto":
                    signalK.autopilotEngaged = true
                    lockedWindAngle = signalK.apparentWindAngle
                case "standby":
                    signalK.autopilotEngaged = false
                    lockedWindAngle = nil
                default: break
                }
            }
        } else {
            withAnimation { apErrorMessage = piService.connectionState == .disconnected
                ? "Pi unreachable — check Setup"
                : settings.anchorPiURL.isEmpty
                    ? "Pi URL not set — go to Setup → Pi Alarm Daemon"
                    : "Command failed — Pi may be busy"
            }
            try? await Task.sleep(for: .seconds(4))
            withAnimation { apErrorMessage = nil }
        }
    }

    /// Sends the Standby+Auto key combo (SeaTalk keycode 0x23) straight to the
    /// daemon — the physical gesture that acknowledges the ST8002's WINDSHIFT
    /// alarm and restarts wind-vane steering on the current wind. Goes via the
    /// daemon directly (not the state broker) so it works regardless of the
    /// broker's allowed-command list.
    @MainActor
    private func resetVane() async {
        apCommandPending = true
        apErrorMessage   = nil
        defer { apCommandPending = false }
        let ok = await piService.sendAutopilotCommand("wind_mode", settings: settings)
        if ok {
            // The pilot re-trims to the wind it sees NOW — mirror that locally.
            withAnimation { lockedWindAngle = signalK.apparentWindAngle }
        } else {
            withAnimation { apErrorMessage = piService.connectionState == .disconnected
                ? "Pi unreachable — check Setup"
                : "Vane reset failed — Pi may be busy"
            }
            try? await Task.sleep(for: .seconds(4))
            withAnimation { apErrorMessage = nil }
        }
    }
}

// MARK: - Wind Rose

private struct WindRose: View {
    let heading: Double
    let trueWindAngle: Double
    let apparentWindAngle: Double
    let rudderAngle: Double
    let targetHeading: Double?
    var waypointBearing: Double? = nil
    var mobBearing: Double? = nil
    var cogHistory: [Double] = []

    var body: some View {
        ZStack {
            // 1. Rotating ring geometry (no text)
            Canvas { ctx, size in
                var c = ctx
                drawCompassRing(ctx: &c, size: size)
            }
            .rotationEffect(.degrees(-heading))
            .animation(.easeOut(duration: 0.35), value: heading)

            // 2. Labels: positioned by heading, rotate radially
            CompassLabels(heading: heading)

            // 3. True wind "T" — inward blue triangle
            TrueWindMarker(trueWindAngle: trueWindAngle, heading: heading)

            // 4. Apparent wind — always shown
            ApparentWindMarker(apparentWindAngle: apparentWindAngle)

            // 4b. Waypoint marker — additional point when a waypoint is active
            if let bearing = waypointBearing {
                COGTrail(cogHistory: cogHistory, heading: heading)
                WaypointBearingMarker(bearing: bearing, heading: heading)
            }

            // 4c. MOB marker — always shown on top when active (independent of waypoint)
            if let bearing = mobBearing {
                MOBBearingMarker(bearing: bearing, heading: heading)
            }

            // 5. Fixed: boat V-lines + rudder bar
            let rud = rudderAngle
            Canvas { ctx, size in
                var c = ctx
                drawBoatAndRudder(ctx: &c, size: size, rudderAngle: rud)
            }

            // 6. Centre heading pill — the boat's magnetic compass, always.
            Text(String(format: "%03.0f°", heading))
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
                .contentTransition(.numericText())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.bgCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.borderColor, lineWidth: 0.5)
                        )
                )
                .offset(y: -8)
        }
    }

    // MARK: Compass ring geometry (no labels)
    private func drawCompassRing(ctx: inout GraphicsContext, size: CGSize) {
        let cx = size.width / 2, cy = size.height / 2
        let r       = min(cx, cy)
        let outerR  = r * 0.98
        let innerR  = r * 0.70
        let ringW   = outerR - innerR

        // Ring fill
        var ring = Path()
        ring.addArc(center: .init(x: cx, y: cy), radius: outerR, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
        ring.addArc(center: .init(x: cx, y: cy), radius: innerR, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: true)
        ctx.fill(ring, with: .color(Color(white: 0.14)))

        // No-go zone: ±45° from TWD solid red, fading to transparent at ±55°
        // Canvas is rotated by -heading, so TWD canvas angle = heading + trueWindAngle - 90
        let twdDeg = heading + trueWindAngle - 90
        let nogoInner = innerR + ringW * 0.05
        let nogoOuter = innerR + ringW * 0.22

        var nogo = Path()
        nogo.addArc(center: .init(x: cx, y: cy), radius: nogoOuter,
                    startAngle: .degrees(twdDeg - 45), endAngle: .degrees(twdDeg + 45), clockwise: false)
        nogo.addArc(center: .init(x: cx, y: cy), radius: nogoInner,
                    startAngle: .degrees(twdDeg + 45), endAngle: .degrees(twdDeg - 45), clockwise: true)
        nogo.closeSubpath()
        ctx.fill(nogo, with: .color(Color.statusRed.opacity(0.40)))

        // Fade zones: ±45° → ±55° (4 slices per side)
        let fadeSteps = 4
        for side in [-1.0, 1.0] {
            for i in 0..<fadeSteps {
                let t0 = 45.0 + Double(i)     * 10.0 / Double(fadeSteps)
                let t1 = 45.0 + Double(i + 1) * 10.0 / Double(fadeSteps)
                let opacity = 0.40 * (1.0 - Double(i + 1) / Double(fadeSteps))
                let a0 = side > 0 ? twdDeg + t0 : twdDeg - t1
                let a1 = side > 0 ? twdDeg + t1 : twdDeg - t0
                var fade = Path()
                fade.addArc(center: .init(x: cx, y: cy), radius: nogoOuter,
                            startAngle: .degrees(a0), endAngle: .degrees(a1), clockwise: false)
                fade.addArc(center: .init(x: cx, y: cy), radius: nogoInner,
                            startAngle: .degrees(a1), endAngle: .degrees(a0), clockwise: true)
                fade.closeSubpath()
                ctx.fill(fade, with: .color(Color.statusRed.opacity(opacity)))
            }
        }

        // Borders
        for (rad, w) in [(outerR, 1.0), (innerR, 0.5)] {
            var c = Path()
            c.addArc(center: .init(x: cx, y: cy), radius: rad, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
            ctx.stroke(c, with: .color(Color(white: 0.25)), lineWidth: w)
        }

        // Tick marks — uniform length, major ticks cyan-highlighted
        let tLen = ringW * 0.30
        for i in 0..<36 {
            let deg   = Double(i * 10)
            let rad   = (deg - 90) * .pi / 180
            let major = i % 3 == 0
            let op    = CGPoint(x: cx + (outerR - 3) * cos(rad), y: cy + (outerR - 3) * sin(rad))
            let ip    = CGPoint(x: cx + (outerR - tLen) * cos(rad), y: cy + (outerR - tLen) * sin(rad))
            var tick  = Path(); tick.move(to: op); tick.addLine(to: ip)
            ctx.stroke(tick, with: .color(major ? Color.accentCyan.opacity(0.70) : Color(white: 0.30)),
                       lineWidth: major ? 1.5 : 0.8)
        }
    }

    // MARK: Boat V-lines + rudder indicator (fixed)
    private func drawBoatAndRudder(ctx: inout GraphicsContext, size: CGSize, rudderAngle: Double) {
        let cx = size.width / 2, cy = size.height / 2
        let r      = min(cx, cy)
        let innerR = r * 0.70

        let bowY   = cy - innerR * 0.44
        let spread = innerR * 0.36
        let armY   = cy + innerR * 0.35

        var port = Path()
        port.move(to: .init(x: cx, y: bowY))
        port.addQuadCurve(to:      .init(x: cx - spread, y: armY),
                          control: .init(x: cx - spread * 0.85, y: bowY + (armY - bowY) * 0.12))
        ctx.stroke(port, with: .linearGradient(
            Gradient(colors: [Color.statusRed, Color.statusRed.opacity(0.06)]),
            startPoint: .init(x: cx, y: bowY), endPoint: .init(x: cx - spread, y: armY)
        ), lineWidth: 2.5)

        var sb = Path()
        sb.move(to: .init(x: cx, y: bowY))
        sb.addQuadCurve(to:      .init(x: cx + spread, y: armY),
                        control: .init(x: cx + spread * 0.85, y: bowY + (armY - bowY) * 0.12))
        ctx.stroke(sb, with: .linearGradient(
            Gradient(colors: [Color.statusGreen, Color.statusGreen.opacity(0.06)]),
            startPoint: .init(x: cx, y: bowY), endPoint: .init(x: cx + spread, y: armY)
        ), lineWidth: 2.5)

        var bow = Path()
        bow.addEllipse(in: CGRect(x: cx - 3.5, y: bowY - 3.5, width: 7, height: 7))
        ctx.fill(bow, with: .color(Color.white.opacity(0.85)))

        // Rudder bar — between V bottom and centre pill
        let barCY    = cy + innerR * 0.56
        let barHW    = innerR * 0.28
        let barH: CGFloat = 5.5
        let maxAng   = 35.0

        var bg = Path()
        bg.addRoundedRect(in: CGRect(x: cx - barHW, y: barCY - barH / 2, width: barHW * 2, height: barH),
                          cornerSize: CGSize(width: 2, height: 2))
        ctx.fill(bg, with: .color(Color(white: 0.16)))

        let clamped = max(-maxAng, min(maxAng, rudderAngle))
        let fillW   = barHW * CGFloat(abs(clamped) / maxAng)
        if fillW > 0.5 {
            let color = clamped > 0 ? Color.statusGreen : Color.statusRed
            let fillX = clamped > 0 ? cx : cx - fillW
            var fill  = Path()
            fill.addRect(CGRect(x: fillX, y: barCY - barH / 2, width: fillW, height: barH))
            ctx.fill(fill, with: .color(color.opacity(0.9)))
        }

        var notch = Path()
        notch.move(to: CGPoint(x: cx, y: barCY - barH - 1))
        notch.addLine(to: CGPoint(x: cx, y: barCY + barH + 1))
        ctx.stroke(notch, with: .color(Color(white: 0.52)), lineWidth: 1)

        if abs(rudderAngle) > 0.5 {
            let lbl = Text(String(format: "%.0f°", rudderAngle))
                .font(.system(size: innerR * 0.13, weight: .semibold, design: .monospaced))
                .foregroundStyle((rudderAngle > 0 ? Color.statusGreen : Color.statusRed).opacity(0.65))
            ctx.draw(lbl, at: CGPoint(x: cx, y: barCY + barH + 8), anchor: .center)
        }
    }
}

// MARK: - Compass labels (upright — counter-rotate to cancel ring spin)

private struct CompassLabels: View {
    let heading: Double

    var body: some View {
        GeometryReader { geo in
            let cx     = geo.size.width  / 2
            let cy     = geo.size.height / 2
            let r      = min(cx, cy)
            let outerR = r * 0.98
            let innerR = r * 0.70
            let labelR = outerR - (outerR - innerR) * 0.60

            ForEach(0..<12, id: \.self) { i in
                let compassDeg  = Double(i * 30)
                // Screen angle: ring has rotated –heading, so this label is at compassDeg–heading from North
                let screenAngle = (compassDeg - heading - 90) * .pi / 180
                let lx = cx + labelR * cos(screenAngle)
                let ly = cy + labelR * sin(screenAngle)

                let isCardinal = i % 3 == 0
                let label: String = {
                    switch i {
                    case 0:  "N"
                    case 3:  "E"
                    case 6:  "S"
                    case 9:  "W"
                    default: String(format: "%03d", i * 30)
                    }
                }()

                Text(label)
                    .font(.system(size: r * 0.095, weight: isCardinal ? .bold : .regular))
                    .foregroundStyle(Color(white: isCardinal ? 0.94 : 0.62))
                    .rotationEffect(.degrees(screenAngle * 180 / .pi + 90))
                    .position(x: lx, y: ly)
            }
        }
        .animation(.easeOut(duration: 0.35), value: heading)
    }
}

// MARK: - True wind "T" marker

private struct TrueWindMarker: View {
    let trueWindAngle: Double
    let heading: Double

    var body: some View {
        GeometryReader { geo in
            let size   = min(geo.size.width, geo.size.height)
            let r      = size / 2
            let outerR = r * 0.98
            let innerR = r * 0.70
            let mR     = outerR - (outerR - innerR) * 0.48

            let twd       = (heading + trueWindAngle + 360).truncatingRemainder(dividingBy: 360)
            let screenDeg = twd - heading
            let screenRad = (screenDeg - 90) * Double.pi / 180
            let mx = geo.size.width  / 2 + mR * cos(screenRad)
            let my = geo.size.height / 2 + mR * sin(screenRad)

            ZStack {
                TriangleShape()
                    .fill(Color(red: 0.18, green: 0.38, blue: 0.92))
                    .frame(width: size * 0.09, height: size * 0.09)
                    .rotationEffect(.degrees(screenDeg + 180))  // +180 = tip points INWARD
                    .position(x: mx, y: my)
                Text("T")
                    .font(.system(size: size * 0.04, weight: .black))
                    .foregroundStyle(.white)
                    .position(x: mx, y: my)
            }
        }
    }
}

// MARK: - Waypoint bearing marker (orange flag on the ring)

private struct WaypointBearingMarker: View {
    let bearing: Double   // absolute compass degrees
    let heading: Double

    var body: some View {
        GeometryReader { geo in
            let size   = min(geo.size.width, geo.size.height)
            let r      = size / 2
            let outerR = r * 0.98
            let innerR = r * 0.70
            let mR     = outerR - (outerR - innerR) * 0.13

            let screenDeg = bearing - heading
            let screenRad = (screenDeg - 90) * Double.pi / 180
            let mx = geo.size.width  / 2 + mR * CGFloat(cos(screenRad))
            let my = geo.size.height / 2 + mR * CGFloat(sin(screenRad))

            ZStack {
                TriangleShape()
                    .fill(Color.statusOrange)
                    .frame(width: size * 0.09, height: size * 0.09)
                    .rotationEffect(.degrees(screenDeg + 180))
                    .position(x: mx, y: my)
                Text("W")
                    .font(.system(size: size * 0.04, weight: .black))
                    .foregroundStyle(.white)
                    .position(x: mx, y: my)
            }
        }
    }
}

// MARK: - MOB marker (red triangle with "M" label — always on top when active)

private struct MOBBearingMarker: View {
    let bearing: Double   // absolute compass degrees
    let heading: Double

    var body: some View {
        GeometryReader { geo in
            let size   = min(geo.size.width, geo.size.height)
            let r      = size / 2
            let outerR = r * 0.98
            let innerR = r * 0.70
            // Place slightly inside the waypoint marker so they don't overlap perfectly
            let mR     = outerR - (outerR - innerR) * 0.30

            let screenDeg = bearing - heading
            let screenRad = (screenDeg - 90) * Double.pi / 180
            let mx = geo.size.width  / 2 + mR * CGFloat(cos(screenRad))
            let my = geo.size.height / 2 + mR * CGFloat(sin(screenRad))

            ZStack {
                // Pulsing halo
                Circle()
                    .fill(Color.statusRed.opacity(0.25))
                    .frame(width: size * 0.14, height: size * 0.14)
                    .position(x: mx, y: my)
                TriangleShape()
                    .fill(Color.statusRed)
                    .frame(width: size * 0.10, height: size * 0.10)
                    .rotationEffect(.degrees(screenDeg + 180))
                    .position(x: mx, y: my)
                Text("M")
                    .font(.system(size: size * 0.045, weight: .black))
                    .foregroundStyle(.white)
                    .position(x: mx, y: my)
            }
        }
    }
}

// MARK: - COG trail (30-second track on the ring)

private struct COGTrail: View {
    let cogHistory: [Double]
    let heading: Double

    var body: some View {
        GeometryReader { geo in
            let size   = min(geo.size.width, geo.size.height)
            let r      = size / 2
            let outerR = r * 0.98
            let innerR = r * 0.70
            let trailR = outerR - (outerR - innerR) * 0.13  // same radius as waypoint marker
            let cx = geo.size.width  / 2
            let cy = geo.size.height / 2

            Canvas { ctx, _ in
                guard cogHistory.count >= 2 else { return }
                let samples = cogHistory.suffix(60)
                let count   = samples.count

                for (i, cog) in samples.enumerated() {
                    let alpha = CGFloat(i) / CGFloat(count)
                    let screenRad = (cog - heading - 90) * Double.pi / 180
                    let px = cx + trailR * CGFloat(cos(screenRad))
                    let py = cy + trailR * CGFloat(sin(screenRad))
                    var dot = Path()
                    let dotR: CGFloat = alpha > 0.8 ? 3.0 : 2.0
                    dot.addEllipse(in: CGRect(x: px - dotR, y: py - dotR, width: dotR * 2, height: dotR * 2))
                    ctx.fill(dot, with: .color(Color.statusOrange.opacity(Double(alpha) * 0.75)))
                }
            }
        }
    }
}

// MARK: - Apparent wind marker

private struct ApparentWindMarker: View {
    let apparentWindAngle: Double

    var body: some View {
        GeometryReader { geo in
            let size   = min(geo.size.width, geo.size.height)
            let r      = size / 2
            let outerR = r * 0.98
            let innerR = r * 0.70
            let mR     = outerR - (outerR - innerR) * 0.13
            let rad    = (apparentWindAngle - 90) * Double.pi / 180
            let mx = geo.size.width  / 2 + mR * cos(rad)
            let my = geo.size.height / 2 + mR * sin(rad)

            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: size * 0.056))
                .foregroundStyle(Color.statusOrange)
                .rotationEffect(.degrees(apparentWindAngle))
                .position(x: mx, y: my)
        }
    }
}

// MARK: - Corner data label with long-press picker

private struct CornerLabel: View {
    let instrument: Instrument
    let signalK: SignalKService
    let settings: AppSettings
    let alignment: HorizontalAlignment
    let onLongPress: () -> Void

    @State private var pressing = false

    var body: some View {
        // Direct position access so SwiftUI tracks it — ensures DTW/CTW re-render live with GPS
        let _ = (instrument == .dtw || instrument == .ctw) ? signalK.latitude + signalK.longitude : 0.0
        let displayValue = instrument.formattedValue(from: signalK, settings: settings)
        VStack(alignment: alignment, spacing: 2) {
            Text(instrument.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
                .tracking(1.1)
            Text(displayValue)
                .font(.system(size: 26, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
                .contentTransition(.numericText())
            if !instrument.unit.isEmpty && !displayValue.hasSuffix(instrument.unit) {
                Text(instrument.unit)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .opacity(pressing ? 0.55 : 1.0)
        .animation(.easeOut(duration: 0.15), value: pressing)
        .onLongPressGesture(minimumDuration: 0.5,
            pressing: { active in withAnimation { pressing = active } },
            perform: { onLongPress() }
        )
    }
}

// MARK: - Instrument picker sheet

struct InstrumentPickerSheet: View {
    let slot: AutopilotView.CornerSlot
    let settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private var currentRaw: String {
        switch slot {
        case .topLeft:     settings.cornerTopLeft
        case .topRight:    settings.cornerTopRight
        case .bottomLeft:  settings.cornerBottomLeft
        case .bottomRight: settings.cornerBottomRight
        }
    }

    private func select(_ instrument: Instrument) {
        switch slot {
        case .topLeft:     settings.cornerTopLeft     = instrument.rawValue
        case .topRight:    settings.cornerTopRight    = instrument.rawValue
        case .bottomLeft:  settings.cornerBottomLeft  = instrument.rawValue
        case .bottomRight: settings.cornerBottomRight = instrument.rawValue
        }
        settings.persist()
        dismiss()
    }

    private var slotTitle: String {
        switch slot {
        case .topLeft:     "Top Left"
        case .topRight:    "Top Right"
        case .bottomLeft:  "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgPrimary.ignoresSafeArea()
                List {
                    ForEach(Instrument.grouped, id: \.0) { group, instruments in
                        Section {
                            ForEach(instruments.filter { $0.isCornerEligible }) { instrument in
                                Button { select(instrument) } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: instrument.icon)
                                            .font(.body)
                                            .foregroundStyle(Color.accentCyan)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(instrument.fullName)
                                                .font(.body)
                                                .foregroundStyle(Color.textPrimary)
                                            Text("\(instrument.displayName)  ·  \(instrument.unit.isEmpty ? "–" : instrument.unit)")
                                                .font(.caption)
                                                .foregroundStyle(Color.textSecondary)
                                        }
                                        Spacer()
                                        if instrument.rawValue == currentRaw {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(Color.accentCyan)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.bgCard)
                            }
                        } header: {
                            Text(group)
                                .sectionHeader()
                                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 4, trailing: 16))
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(slotTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.accentCyan)
                }
            }
        }
        .sheetDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.bgPrimary)
    }
}

// MARK: - Shared shapes

private struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

/// Per-button ButtonStyle — each button tracks its own isPressed independently,
/// which prevents the shared-gesture flash that affected all buttons simultaneously.
private struct HeadingButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(tint.opacity(configuration.isPressed ? 0.22 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(tint.opacity(0.35), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct HeadingButton: View {
    let label: String
    let sublabel: String
    let tint: Color
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        let effectiveTint = disabled ? Color.textTertiary : tint
        Button { action() } label: {
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(effectiveTint)
                Text(sublabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(effectiveTint.opacity(0.55))
            }
            // Flexible width — fills available space equally, never overflows screen
            .frame(maxWidth: .infinity, minHeight: 48, idealHeight: 48)
        }
        .buttonStyle(HeadingButtonStyle(tint: effectiveTint))
        .disabled(disabled)
    }
}

// MARK: - MOB Icon (Canvas, matches the person-in-water MOB symbol)

struct MOBIcon: View {
    var color: Color = .red
    var size: CGFloat = 22

    var body: some View {
        Canvas { ctx, sz in
            let w = sz.width, h = sz.height
            let lw = w * 0.088
            let s  = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)

            func stroke(_ p: Path) { ctx.stroke(p, with: .color(color), style: s) }

            // Head
            let hr = w * 0.105
            let hcx = w * 0.65, hcy = h * 0.215
            ctx.stroke(
                Path(ellipseIn: CGRect(x: hcx - hr, y: hcy - hr, width: hr * 2, height: hr * 2)),
                with: .color(color),
                style: StrokeStyle(lineWidth: lw, lineCap: .round)
            )

            // Torso (diagonal — person tilted floating)
            var p = Path()
            p.move(to:    CGPoint(x: w * 0.63, y: h * 0.33))
            p.addLine(to: CGPoint(x: w * 0.42, y: h * 0.55))
            stroke(p)

            // Raised right arm (up and slightly right)
            p = Path()
            p.move(to:    CGPoint(x: w * 0.60, y: h * 0.38))
            p.addLine(to: CGPoint(x: w * 0.78, y: h * 0.16))
            stroke(p)

            // Left arm (out to left, slightly down)
            p = Path()
            p.move(to:    CGPoint(x: w * 0.55, y: h * 0.44))
            p.addLine(to: CGPoint(x: w * 0.34, y: h * 0.42))
            stroke(p)

            // Right leg (back-left, lower)
            p = Path()
            p.move(to:    CGPoint(x: w * 0.42, y: h * 0.55))
            p.addLine(to: CGPoint(x: w * 0.22, y: h * 0.63))
            stroke(p)

            // Left leg (angled up-left)
            p = Path()
            p.move(to:    CGPoint(x: w * 0.42, y: h * 0.55))
            p.addLine(to: CGPoint(x: w * 0.29, y: h * 0.44))
            stroke(p)

            // Waves — three sinusoidal lines
            let waveYs: [CGFloat] = [h * 0.71, h * 0.82, h * 0.91]
            for wy in waveYs {
                var wave = Path()
                wave.move(to: CGPoint(x: w * 0.06, y: wy))
                wave.addCurve(to:       CGPoint(x: w * 0.40, y: wy),
                              control1: CGPoint(x: w * 0.17, y: wy - h * 0.055),
                              control2: CGPoint(x: w * 0.29, y: wy + h * 0.055))
                wave.addCurve(to:       CGPoint(x: w * 0.74, y: wy),
                              control1: CGPoint(x: w * 0.51, y: wy - h * 0.055),
                              control2: CGPoint(x: w * 0.63, y: wy + h * 0.055))
                wave.addCurve(to:       CGPoint(x: w * 0.94, y: wy),
                              control1: CGPoint(x: w * 0.82, y: wy - h * 0.035),
                              control2: CGPoint(x: w * 0.90, y: wy + h * 0.02))
                stroke(wave)
            }
        }
        .frame(width: size, height: size)
    }
}
