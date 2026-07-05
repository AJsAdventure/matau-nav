import SwiftUI
import MapKit
import UniformTypeIdentifiers
import CoreLocation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - ChartView
//
// Full-screen chartplotter style map:
//   • OSM base + OpenSeaMap seamark overlay (toggleable)
//   • Vessel icon rotated to magnetic heading
//   • COG arrow extending from bow, length scaled to SOG
//   • Wind triangle (true wind) drawn at the vessel
//   • Tap-to-set waypoint with "Go to" / clear actions
//   • Distance measurement tool (tap two points)
//   • AIS targets from aisstream.io with vessel-type icons and tap-to-inspect
//   • Historic tracks: Pi-recorded + GPX-imported + live local trail
//   • Settings sheet: layers, downloads, AIS key, tracks, cache

struct ChartView: View {
    @Environment(AppSettings.self)        private var settings
    @Environment(SignalKService.self)     private var signalK
    @Environment(PiStateService.self)     private var piState
    @Environment(TrackService.self)       private var tracks
    @Environment(BathymetryService.self)  private var bathymetry
    @Environment(ContourService.self)     private var contours
    @Environment(PredictWindService.self) private var predictWind
    @Environment(AnchorWatchService.self) private var anchorWatch
    @Environment(AnchorPiService.self)    private var piService
    #if os(macOS)
    @Environment(ChartBridge.self)        private var chartBridge
    #endif

    @State private var zoomProxy = MapZoomProxy()
    @State private var showSettings = false
    @State private var selectedAIS: AISTarget?
    @State private var measureMode = false
    /// Last viewport we reacted to. macOS MKMapView fires regionDidChange
    /// repeatedly during overlay/layout passes; without deduping, each callback
    /// writes @State → re-render → syncMap → another regionDidChange, a cycle
    /// that pegs the CPU. We only act when the viewport actually moved.
    @State private var lastViewportKey: String = ""
    @State private var measureFromCoord: CLLocationCoordinate2D?
    @State private var measureToCoord:   CLLocationCoordinate2D?
    @State private var longPressCoord: CLLocationCoordinate2D?
    @State private var showLongPressMenu = false
    @State private var probedDepth: Double?
    @State private var probedDepthCoord: CLLocationCoordinate2D?
    /// Smoothed true-wind angle (rolling 3-s mean) used by the chart wind triangle.
    @State private var showNavionicsWeb = false
    @State private var smoothedTrueWindAngle: Double = 0
    private struct TwaSample { let t: Date; let twa: Double }
    @State private var twaBuf: [TwaSample] = []
    // Anchor integration
    @State private var anchorFlash        = false
    @State private var showAnchorSettings = false
    @State private var showSafeTonight    = false
    @State private var showAnchorWizard   = false

    var body: some View {
        ZStack {
            // Chart fills the window; controls float on top.
            chartCanvas
                .ignoresSafeArea()
                #if os(macOS)
                .onAppear { chartBridge.zoomProxy = zoomProxy }
                #endif
                // Keep this device's GPS warm while the chart is open so it can
                // back up the boat feed the instant it drops.
                .onAppear  { anchorWatch.startChartFallbackGPS() }
                .onDisappear { anchorWatch.stopChartFallbackGPS() }

            if settings.chartShowWindRibbon && !settings.isAnchorMode {
                HStack {
                    Spacer()
                    WindRibbon(samples: signalK.windHistory,
                               currentTWD: signalK.trueWindDirection)
                        .frame(width: 44)
                        .padding(.trailing, 76)        // clear of the right rail
                        .padding(.vertical, 80)
                }
                .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                Spacer()
                bottomBar
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            }

            // Floating right rail — lifted above the taller anchor console.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    rightRail
                        .padding(.trailing, 12)
                        .padding(.bottom, rightRailBottomPadding)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            ChartSettingsSheet(zoomProxy: zoomProxy)
                .environment(settings)
                .environment(signalK)
                .environment(piState)
                .environment(tracks)
        }
        .sheet(item: $selectedAIS) { target in
            AISDetailSheet(target: target).environment(settings)
        }
        .sheet(isPresented: $showAnchorSettings) {
            AnchorSettingsSheetWithForecast(
                settings: settings, anchorWatch: anchorWatch,
                piService: piService, predictWind: predictWind, signalK: signalK)
        }
        .sheet(isPresented: $showSafeTonight) {
            SafeTonightSheet(
                settings: settings, predictWind: predictWind,
                anchorLat: settings.anchorActive ? settings.anchorLat : signalK.latitude,
                anchorLon: settings.anchorActive ? settings.anchorLon : signalK.longitude)
        }
        .sheet(isPresented: $showAnchorWizard) {
            AnchorWizardSheet(settings: settings, signalK: signalK, anchorWatch: anchorWatch) { coord in
                let span = MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
                zoomProxy.mapView?.setRegion(.init(center: coord, span: span), animated: true)
                Task { await triggerForecastForAnchor() }
            }
        }
        .sheet(isPresented: $showNavionicsWeb) {
            let coord: CLLocationCoordinate2D = (signalK.latitude != 0 || signalK.longitude != 0)
                ? CLLocationCoordinate2D(latitude: signalK.latitude, longitude: signalK.longitude)
                : (zoomProxy.mapView?.region.center ?? CLLocationCoordinate2D(latitude: 35.8893, longitude: 14.5122))
            let z: Int = {
                guard let span = zoomProxy.mapView?.region.span.longitudeDelta, span > 0
                else { return 12 }
                return max(3, min(17, Int(log2(360.0 / span).rounded())))
            }()
            NavionicsWebSheet(center: coord, zoom: z)
        }
        // Long-press position sheet — slides up from bottom
        .overlay(alignment: .bottom) {
            if showLongPressMenu, let coord = longPressCoord {
                ZStack(alignment: .bottom) {
                    // Dim backdrop
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(.spring(duration: 0.3)) { showLongPressMenu = false } }
                    // Sheet panel
                    positionSheet(coord: coord)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .ignoresSafeArea()
                .animation(.spring(duration: 0.35), value: showLongPressMenu)
            }
        }
        .onChange(of: settings.chartBathymetry) { _, _ in
            // Toggling depth shading should refresh immediately, not wait
            // for the next pan to produce a region-change callback.
            if let r = zoomProxy.mapView?.region {
                updateContourPolygons(for: r)
            }
        }
        .onChange(of: settings.chartSatellite) { _, _ in
            // Satellite toggle changes whether land is drawn over the imagery.
            if let r = zoomProxy.mapView?.region {
                updateContourPolygons(for: r)
            }
        }
        .onChange(of: contours.revision) { _, _ in
            // A background contour parse finished — pull its polygons in.
            if let r = zoomProxy.mapView?.region {
                updateContourPolygons(for: r)
            }
        }
        .task {
            // Pull Pi-recorded GPS tracks on open, then again every 60 s so
            // newly-recorded points show up while sailing.
            while !Task.isCancelled {
                await tracks.fetchPiTracks(baseURL: signalK.baseURL)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .task {
            // PredictWind AIS — refresh every 5 minutes for the vessel's
            // approximate visible area (±0.5° lat/lon at typical chart zoom).
            while !Task.isCancelled {
                if settings.chartShowPredictWindAIS {
                    let lat = signalK.latitude  != 0 ? signalK.latitude  : 35.89
                    let lon = signalK.longitude != 0 ? signalK.longitude : 14.51
                    let delta = 1.0   // ~60nm box
                    predictWind.configure(piURL: settings.predictWindPiURL)
                    await predictWind.fetchAIS(
                        south: lat - delta, west: lon - delta,
                        north: lat + delta, east: lon + delta
                    )
                }
                try? await Task.sleep(for: .seconds(300))
            }
        }
        .onChange(of: anchorWatch.activeAlarms) { _, alarms in
            guard !alarms.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.15).repeatCount(6, autoreverses: true)) { anchorFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { anchorFlash = false }
        }
        .onChange(of: signalK.trueWindAngle) { _, v in
            let now = Date()
            twaBuf.append(.init(t: now, twa: v))
            twaBuf.removeAll { now.timeIntervalSince($0.t) > 3 }
            // Circular mean — averaging raw degrees breaks at the 0/360 wrap.
            let rads = twaBuf.map { $0.twa * .pi / 180 }
            let sx = rads.reduce(0) { $0 + sin($1) } / Double(rads.count)
            let cx = rads.reduce(0) { $0 + cos($1) } / Double(rads.count)
            smoothedTrueWindAngle = atan2(sx, cx) * 180 / .pi
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        ZStack {
            // Action chips pinned to the right; layers/zoom live on the rail.
            HStack(spacing: 10) {
                Spacer()
                if settings.isAnchorMode {
                    anchorTopChips
                } else {
                    sailTopChips
                }
            }
            // Mode switch, absolutely centred at the top.
            modeToggle
        }
    }

    private var sailTopChips: some View {
        // Navionics webapp — opens in the in-app slide-over browser.
        chip(icon: "globe.americas.fill") { showNavionicsWeb = true }
    }

    private var anchorTopChips: some View {
        HStack(spacing: 10) {
            // Tonight's wind verdict.
            chip(icon: "moon.stars.fill", active: showSafeTonight) { showSafeTonight = true }
            // Anchor + forecast alarm settings.
            chip(icon: "slider.horizontal.3") { showAnchorSettings = true }
        }
    }

    /// Sail ⇄ Anchor segmented control. The whole chart re-skins around this:
    /// sailing overlays vs. a calm anchor watch.
    private var modeToggle: some View {
        HStack(spacing: 3) {
            modeSegment(mode: "sail",   label: "Sail",   tint: .accentCyan, anchorGlyph: false)
            modeSegment(mode: "anchor", label: "Anchor", tint: .statusOrange, anchorGlyph: true)
        }
        .padding(4)
        // Same glass/dark treatment as the round chips so the toggle doesn't
        // read darker than the buttons beside it.
        .glassBackground(active: false, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
    }

    // Both segments ALWAYS show their icon + label. The anchor uses the custom
    // AnchorMark glyph (there is no "anchor" SF Symbol); sail uses sailboat.fill.
    private func modeSegment(mode: String, label: String, tint: Color, anchorGlyph: Bool) -> some View {
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
    }

    private func setChartMode(_ mode: String) {
        guard settings.chartMode != mode else { return }
        withAnimation(.spring(duration: 0.3)) {
            settings.chartMode = mode
            settings.persist()
        }
        // Entering anchor mode: focus the map on the anchor (or vessel) so the
        // swing circle is front and centre.
        if mode == "anchor" {
            let center = settings.anchorActive
                ? CLLocationCoordinate2D(latitude: settings.anchorLat, longitude: settings.anchorLon)
                : CLLocationCoordinate2D(latitude: signalK.latitude, longitude: signalK.longitude)
            if center.latitude != 0 || center.longitude != 0 {
                let span = MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
                zoomProxy.mapView?.setRegion(.init(center: center, span: span), animated: true)
            }
        }
    }

    /// Lift the zoom/recenter rail clear of the anchor console, which is taller
    /// than the sail-mode bottom bar.
    private var rightRailBottomPadding: CGFloat {
        guard settings.isAnchorMode else { return 100 }
        return settings.anchorActive ? 270 : 200
    }

    // MARK: - Right rail (zoom + recenter)

    private var rightRail: some View {
        VStack(spacing: 12) {
            // Layers / chart settings — top of the rail.
            chip(icon: "square.3.layers.3d.down.right") { showSettings = true }
            // Distance measuring — between layers and the zoom controls.
            chip(icon: "ruler", active: measureMode) {
                measureMode.toggle()
                if !measureMode { measureFromCoord = nil; measureToCoord = nil }
            }
            chip(icon: "plus")  { zoomProxy.zoomIn() }
            chip(icon: "minus") { zoomProxy.zoomOut() }
            // Center-on-vessel. Toggles Follow on; tapping again toggles off.
            chip(icon: "location.fill", active: settings.chartFollowVessel) {
                settings.chartFollowVessel.toggle()
                settings.persist()
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if settings.mobActive { mobBanner }
            if let cpa = topDanger { cpaBanner(cpa) }
            if positionSource != .boat { positionSourceBanner }
            if settings.chartShowPredictWindAIS, predictWind.aisIsStale { staleAISBanner }
            // Transient readouts (distance measure / waypoint / depth probe)
            // sit ABOVE the anchor console so the measurement popup is never
            // hidden behind the taller anchor panel — from the top it reads
            // measure popup first, then the anchor overlay.
            if let from = measureFromCoord, let to = measureToCoord {
                measureReadout(from: from, to: to)
            } else if let wp = activeWaypoint, settings.activeRoute == nil {
                waypointReadout(wp: wp)
            } else if measureMode {
                Text("Tap two points to measure distance")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            if let pd = probedDepth, let pc = probedDepthCoord {
                probedDepthChip(depth: pd, coord: pc)
            }
            if settings.isAnchorMode { anchorConsole }
            if !settings.isAnchorMode, let route = settings.activeRoute, let leg = route.activeWaypoint {
                routeProgressBar(route: route, leg: leg)
            }
            HStack(spacing: 8) {
                if settings.chartShowSetDrift, !settings.isAnchorMode, let sd = setDriftReadout {
                    Text(sd)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                // Depth chip — hidden in anchor mode (depth is in the console).
                if !settings.isAnchorMode, let d = bathymetry.vesselDepth {
                    HStack(spacing: 4) {
                        Image(systemName: "water.waves.and.arrow.down")
                            .font(.caption2)
                        Text(String(format: "%.0f m", abs(d)))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
        }
    }

    // MARK: - Anchor console

    /// The bottom panel shown in anchor mode. Two faces: a planning panel
    /// before the hook is down, and a glanceable watch console once anchored.
    @ViewBuilder
    private var anchorConsole: some View {
        if settings.anchorActive {
            anchorWatchConsole
        } else {
            anchorPlanningPanel
        }
    }

    // Pre-drop: live depth/wind + a big Drop button + tonight's verdict.
    private var anchorPlanningPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                consoleStat(label: "DEPTH",
                            value: signalK.depth > 0 ? String(format: "%.1f m", signalK.depth) : "—")
                consoleStat(label: "WIND",
                            value: String(format: "%.0f kt", signalK.trueWindSpeed),
                            sub: String(format: "%03.0f°", signalK.trueWindDirection))
                consoleStat(label: "TONIGHT", value: safeTonightChipLabel.0,
                            valueColor: safeTonightChipLabel.1)
            }
            HStack(spacing: 10) {
                Button { startAnchorWizard() } label: {
                    HStack(spacing: 7) {
                        AnchorMark().frame(width: 18, height: 18)
                        Text("Drop Anchor")
                    }
                    .font(.headline).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color.statusOrange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                Button { dropAnchorNow() } label: {
                    Text("Quick")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.statusOrange)
                        .frame(width: 64, height: 50)
                        .background(Color.statusOrange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.statusOrange.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // Anchored: status pill + metric grid + actions.
    private var anchorWatchConsole: some View {
        let state   = anchorWatch.holdState(settings: settings)
        let alarms  = anchorWatch.activeAlarms
        let shift   = anchorWatch.windShift(settings: settings, signalK: signalK)
        let depthTrend = depthTrendArrow
        return VStack(spacing: 10) {
            if !alarms.isEmpty { anchorAlarmBar(alarms) }

            // Status row
            HStack(spacing: 10) {
                anchorStatusPill(state)
                Text(anchorWatch.swingDiagnosis(settings: settings))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
            }

            // Metric grid
            HStack(spacing: 8) {
                consoleStat(label: "DISTANCE",
                            value: fmtDist(anchorWatch.liveDistance),
                            sub: "max \(fmtDist(anchorWatch.maxSwing)) / \(fmtDist(settings.anchorRadius))",
                            valueColor: state == .dragging ? .statusRed : (state == .warning ? .statusOrange : .white))
                consoleStat(label: "BEARING",
                            value: String(format: "%03.0f°", anchorWatch.liveBearing))
                consoleStat(label: "DEPTH",
                            value: signalK.depth > 0 ? String(format: "%.1f m", signalK.depth) : "—",
                            sub: depthTrend)
            }
            HStack(spacing: 8) {
                consoleStat(label: "WIND",
                            value: String(format: "%.0f kt", signalK.trueWindSpeed),
                            sub: String(format: "%03.0f° · %+.0f°", signalK.trueWindDirection, shift),
                            valueColor: (settings.anchorWindMax < 60 && signalK.trueWindSpeed > settings.anchorWindMax) ? .statusRed : .white)
                consoleStat(label: "SCOPE", value: scopeLabel)
                consoleStat(label: "GPS", value: gpsSourceLabel, sub: batteryLabel)
            }

            // Footer: watching-since + actions
            HStack(spacing: 12) {
                if settings.anchorDropTime > 0 {
                    let since = Date(timeIntervalSince1970: settings.anchorDropTime)
                    Text("Since \(since.formatted(date: .omitted, time: .shortened)) · \(anchorWatch.minutesWatched(settings: settings))m")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                if let suggested = anchorWatch.observedSwingRadius(settings: settings),
                   anchorWatch.minutesWatched(settings: settings) >= 20,
                   suggested + 3 < settings.anchorRadius {
                    Button { applyObservedSwing(suggested) } label: {
                        Label("Tighten \(Int(suggested))m", systemImage: "scope")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.accentCyan, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button { anchorWatch.raiseAnchor(settings: settings); settings.persist() } label: {
                    Label("Raise", systemImage: "arrow.up.square.fill")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.statusRed, in: Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(anchorConsoleBorder(state), lineWidth: alarms.isEmpty ? 0.5 : 1.5)
        )
    }

    private func anchorStatusPill(_ state: AnchorWatchService.HoldState) -> some View {
        let (label, color): (String, Color) = switch state {
        case .idle:     ("IDLE", .textTertiary)
        case .holding:  ("HOLDING", .statusGreen)
        case .warning:  ("WARNING", .statusOrange)
        case .dragging: ("DRAGGING", .statusRed)
        }
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
                .symbolEffect(.pulse, isActive: state == .dragging)
            Text(label).font(.system(size: 12, weight: .bold)).foregroundStyle(color)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.15), in: Capsule())
    }

    private func anchorConsoleBorder(_ state: AnchorWatchService.HoldState) -> Color {
        switch state {
        case .dragging: .statusRed
        case .warning:  .statusOrange
        default:        .white.opacity(0.12)
        }
    }

    private func anchorAlarmBar(_ alarms: Set<AnchorWatchService.AlarmType>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
            Text(alarms.map(\.rawValue).joined(separator: " · "))
                .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer()
            Button("Snooze") { anchorWatch.snooze(minutes: 15) }
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.white, in: Capsule())
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.statusRed, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func consoleStat(label: String, value: String, sub: String? = nil,
                             valueColor: Color = .white) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundStyle(valueColor)
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.7)
            if let sub {
                Text(sub)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Anchor console helpers

    private func fmtDist(_ m: Double) -> String {
        m < 1000 ? String(format: "%.0fm", m) : String(format: "%.2fnm", m / 1852)
    }

    private var depthTrendArrow: String {
        guard let base = anchorWatch.depthBaseline, signalK.depth > 0 else { return "" }
        let d = signalK.depth - base
        if d >  0.3 { return String(format: "↑ %.1f", abs(d)) }
        if d < -0.3 { return String(format: "↓ %.1f", abs(d)) }
        return "steady"
    }

    private var scopeLabel: String {
        guard settings.anchorRodeLength > 0, signalK.depth > 0.3 else { return "—" }
        return String(format: "%.1f:1", settings.anchorRodeLength / signalK.depth)
    }

    private var gpsSourceLabel: String {
        if anchorWatch.deviceCoord != nil,
           Date().timeIntervalSince(anchorWatch.deviceFixTime) < 20 { return "phone" }
        return signalK.state.isConnected ? "boat" : "—"
    }

    private var batteryLabel: String {
        guard anchorWatch.batteryLevel >= 0 else { return "" }
        return String(format: "%.0f%%", anchorWatch.batteryLevel * 100)
    }

    /// A short tonight-verdict word + color for the planning panel (computed
    /// from the last fetched PredictWind forecast).
    private var safeTonightChipLabel: (String, Color) {
        let v = AnchorForecast.verdict(forecast: predictWind.forecast, settings: settings)
        return (v.word, v.color)
    }

    private func startAnchorWizard() { showAnchorWizard = true }

    /// One-tap drop at the current bow position — a quick swinging anchor for
    /// when there's no time for the wizard.
    private func dropAnchorNow() {
        let pos = anchorWatch.dropPosition(signalK: signalK, settings: settings)
        guard pos.latitude != 0 || pos.longitude != 0 else { return }
        settings.anchorMooringType = "swinging"
        settings.anchorLat = pos.latitude
        settings.anchorLon = pos.longitude
        if settings.anchorRadius <= 0 { settings.anchorRadius = 30 }
        anchorWatch.dropAnchor(settings: settings, signalK: signalK)
        settings.persist()
        let span = MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
        zoomProxy.mapView?.setRegion(.init(center: pos, span: span), animated: true)
        Task { await triggerForecastForAnchor() }
    }

    private func applyObservedSwing(_ radius: Double) {
        withAnimation { settings.anchorRadius = max(5, min(200, radius)) }
        settings.persist()
        Task { await piService.syncConfig(settings: settings) }
    }

    /// Banner shown after a "Depth here" long-press lookup completes.
    private func probedDepthChip(depth: Double, coord: CLLocationCoordinate2D) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "water.waves.and.arrow.down")
                .font(.body)
                .foregroundStyle(Color.accentCyan)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "Depth %.0f m", abs(depth)))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(String(format: "%.4f° %.4f°  ·  EMODnet", coord.latitude, coord.longitude))
                    .font(.caption2).monospaced()
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button {
                probedDepth = nil; probedDepthCoord = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3).foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Set & drift

    private var setDriftReadout: String? {
        guard signalK.boatSpeed > 0.2, signalK.speedOverGround > 0.2 else { return nil }
        let r = NavMath.setDrift(
            headingDeg: signalK.headingMagnetic, stwKn: signalK.boatSpeed,
            cogDeg: signalK.courseOverGround,    sogKn: signalK.speedOverGround
        )
        guard r.driftKn > 0.1 else { return nil }
        return String(format: "Set %03.0f°  Drift %.1fkn", r.setDeg, r.driftKn)
    }

    // MARK: MOB

    private var mobBanner: some View {
        let mob = CLLocationCoordinate2D(latitude: settings.mobLat, longitude: settings.mobLon)
        let here = CLLocationCoordinate2D(latitude: signalK.latitude, longitude: signalK.longitude)
        let nm  = NavMath.distanceNm(here, mob)
        let brg = NavMath.bearingDeg(here, mob)
        let elapsed = max(0, Int(Date().timeIntervalSince1970 - settings.mobTime))
        let timeStr = elapsed >= 60 ? "\(elapsed / 60)m \(elapsed % 60)s" : "\(elapsed)s"
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.title3)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text("MAN OVERBOARD")
                    .font(.caption).fontWeight(.bold)
                    .foregroundStyle(.white)
                Text(String(format: "%.2f nm · %03.0f° · %@", nm, brg, timeStr))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            Spacer()
            Button {
                Task { await piState.clearMOB() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.statusRed, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: CPA alarm banner

    private struct CPAInfo { let target: AISTarget; let cpaNm: Double; let tcpaMin: Double }

    private var topDanger: CPAInfo? {
        guard settings.aisCPAAlarmEnabled else { return nil }
        // Pi pre-computes cpaNm + tcpaMin + danger; we just pick the soonest
        // unacknowledged one.
        var best: CPAInfo?
        for mmsi in piState.dangerousMMSIs
            where !settings.aisAcknowledgedMMSIs.contains(mmsi) {
            guard let t = piState.targets[mmsi],
                  let cpaNm = t.cpaNm, let tcpaMin = t.tcpaMin else { continue }
            if best == nil || tcpaMin < best!.tcpaMin {
                best = .init(target: t, cpaNm: cpaNm, tcpaMin: tcpaMin)
            }
        }
        return best
    }

    private func cpaBanner(_ info: CPAInfo) -> some View {
        let name = info.target.name ?? "MMSI \(info.target.mmsi)"
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text("COLLISION RISK · \(name)")
                    .font(.caption).fontWeight(.bold).foregroundStyle(.white)
                Text(String(format: "CPA %.2f nm in %.0f min", info.cpaNm, info.tcpaMin))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            Spacer()
            Button {
                settings.aisAcknowledgedMMSIs.insert(info.target.mmsi)
            } label: {
                Text("ACK").font(.caption).fontWeight(.bold).foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white, in: Capsule())
            }
            Button {
                selectedAIS = info.target
            } label: {
                Image(systemName: "info.circle.fill").font(.title3).foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.statusRed, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Position source banner

    /// Shown whenever the live boat GPS feed is unavailable: tells the user the
    /// chart is either running on this device's own GPS or has no fix at all, so
    /// a frozen boat feed is never mistaken for a live position.
    private var positionSourceBanner: some View {
        let device = positionSource == .device
        return HStack(spacing: 10) {
            Image(systemName: device ? "location.fill" : "location.slash.fill")
                .font(.callout).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text(device ? "USING DEVICE GPS" : "NO GPS FIX")
                    .font(.caption).fontWeight(.bold).foregroundStyle(.white)
                Text(device ? "Boat GPS feed lost — showing this device's position"
                            : "Boat GPS feed lost — position is frozen")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(device ? Color.statusOrange : Color.statusRed,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Shown when the PredictWind AIS overlay hasn't refreshed for a while, so
    /// a dead overlay can't be mistaken for empty waters. Targets are cleared
    /// automatically after ~15 min unreachable (PredictWindService.fetchAIS).
    private var staleAISBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.callout).foregroundStyle(.white)
            Text(predictWind.pwAIS.isEmpty
                 ? "AIS OVERLAY OFFLINE — no data from the Pi"
                 : "AIS OVERLAY STALE — targets may have moved")
                .font(.caption).fontWeight(.bold).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.statusOrange,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Route progress

    private func routeProgressBar(route: Route, leg: RouteWaypoint) -> some View {
        let here = CLLocationCoordinate2D(latitude: signalK.latitude, longitude: signalK.longitude)
        let to   = CLLocationCoordinate2D(latitude: leg.lat, longitude: leg.lon)
        let nm   = NavMath.distanceNm(here, to)
        let brg  = NavMath.bearingDeg(here, to)
        // Total remaining nm = current leg + all subsequent legs
        var total = nm
        var prev = to
        for wp in route.waypoints.dropFirst(route.legIndex + 1) {
            let next = CLLocationCoordinate2D(latitude: wp.lat, longitude: wp.lon)
            total += NavMath.distanceNm(prev, next)
            prev = next
        }
        let etaStr: String = {
            guard signalK.speedOverGround > 0.1 else { return "—" }
            let hrs = total / signalK.speedOverGround
            let mins = Int((hrs * 60).rounded())
            if mins >= 60 { return String(format: "%dh %02dm", mins / 60, mins % 60) }
            return "\(mins) min"
        }()
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Leg \(route.legIndex + 1)/\(route.waypoints.count) · \(leg.name)")
                    .font(.caption).foregroundStyle(.white.opacity(0.75))
                Text(String(format: "%.2f nm · %03.0f°T  ·  total %.1f nm  ·  %@", nm, brg, total, etaStr))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            Spacer()
            Button {
                Task { await piState.advanceRoute() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.callout).foregroundStyle(.white)
            }
            Button {
                Task { await piState.clearRoute() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3).foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        // Auto-advance is handled on the Pi (state_server.py route_advance_loop).
    }

    // MARK: Long-press menu

    private func handleLongPress(coord: CLLocationCoordinate2D) {
        longPressCoord = coord
        showLongPressMenu = true
    }

    private func setWaypoint(_ coord: CLLocationCoordinate2D) {
        settings.waypointActive = true
        settings.waypointLat = coord.latitude
        settings.waypointLon = coord.longitude
        if settings.waypointName.isEmpty { settings.waypointName = "Waypoint" }
        settings.persist()
    }

    private func startRoute(_ coord: CLLocationCoordinate2D) {
        var r = Route(name: "Route")
        r.waypoints.append(RouteWaypoint(name: "1", lat: coord.latitude, lon: coord.longitude))
        Task { await piState.setRoute(r) }
    }

    private func appendToRoute(_ coord: CLLocationCoordinate2D) {
        guard var r = settings.activeRoute else { return startRoute(coord) }
        let n = r.waypoints.count + 1
        r.waypoints.append(RouteWaypoint(name: "\(n)", lat: coord.latitude, lon: coord.longitude))
        Task { await piState.setRoute(r) }
    }

    private var activeWaypoint: (lat: Double, lon: Double, name: String)? {
        guard settings.waypointActive else { return nil }
        return (settings.waypointLat, settings.waypointLon, settings.waypointName)
    }

    /// Polygons currently rendered. Driven by `ChartMapView`'s region-
    /// change delegate via `updateContourPolygons(for:)` rather than
    /// computed from `zoomProxy.mapView?.region` — MapKit's region isn't
    /// SwiftUI-observable, so a computed-property approach evaluates once
    /// with mapView == nil and never re-runs.
    @State private var visibleContourPolygons: [ContourPolygon] = []

    private func updateContourPolygons(for region: MKCoordinateRegion) {
        guard settings.chartBathymetry,
              region.span.longitudeDelta <= 3.0 else {
            if !visibleContourPolygons.isEmpty { visibleContourPolygons = [] }
            return
        }
        let polys = contours.polygonsFor(region: region)
        // With satellite on, skip the opaque tan land fill so the real imagery
        // shows through; depth shading on the water still applies.
        visibleContourPolygons = settings.chartSatellite
            ? polys.filter { if case .land = $0.band { return false } else { return true } }
            : polys
    }

    // MARK: - Vessel position source

    enum PositionSource { case boat, device, stale }

    /// Where the displayed vessel position is coming from right now: the live
    /// boat feed, this device's own GPS backup, or neither (stale — holding the
    /// last known fix).
    private var positionSource: PositionSource {
        if signalK.boatPositionIsLive, signalK.latitude != 0 || signalK.longitude != 0 { return .boat }
        if anchorWatch.freshDeviceCoord != nil { return .device }
        return .stale
    }

    /// Vessel position for the chart: the live boat feed when available,
    /// otherwise this device's own GPS (so the marker keeps moving when the Pi /
    /// boat network is unreachable — e.g. the chartplotter was switched off),
    /// otherwise the last known boat position rather than jumping to 0,0.
    private var effectiveVessel: CLLocationCoordinate2D {
        if positionSource == .device, let d = anchorWatch.freshDeviceCoord { return d }
        return CLLocationCoordinate2D(latitude: signalK.latitude, longitude: signalK.longitude)
    }

    // MARK: - Map canvas

    private var chartCanvas: some View {
        ChartMapView(
            initialCenter: CLLocationCoordinate2D(
                latitude:  signalK.latitude  != 0 ? signalK.latitude  : 35.8893,
                longitude: signalK.longitude != 0 ? signalK.longitude : 14.5122
            ),
            vesselLat:        effectiveVessel.latitude,
            vesselLon:        effectiveVessel.longitude,
            heading:          signalK.headingMagnetic,
            cog:              signalK.courseOverGround,
            sog:              signalK.speedOverGround,
            trueWindAngle:    smoothedTrueWindAngle,
            trueWindSpeed:    signalK.trueWindSpeed,
            satellite:        settings.chartSatellite,
            seamark:          settings.chartOpenSeaMap,
            // The chartBathymetry toggle now drives the bundled polygon
            // layer (richer + offline). The EMODnet WMTS tile overlay is
            // kept available in OSMTileOverlay but not added to the map.
            bathymetry:       false,
            contourPolygons:  visibleContourPolygons,
            follow:           settings.chartFollowVessel,
            northUp:          settings.chartNorthUp,
            showAIS:          settings.chartShowAIS,
            aisTargets:       Array(piState.targets.values),
            aisFriends:       Dictionary(uniqueKeysWithValues: settings.aisFriends.map { ($0.mmsi, $0) }),
            tracks:           settings.chartShowTracks
                                ? tracks.tracks.filter { $0.visible } + [tracks.liveTrack]
                                : [],
            waypoint:         activeWaypoint.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) },
            mobCoord:         settings.mobActive
                                ? CLLocationCoordinate2D(latitude: settings.mobLat, longitude: settings.mobLon)
                                : nil,
            // Sailing tactical overlays are suppressed in anchor mode so the
            // chart reads as a calm anchor watch, not a moving-boat display.
            predictorMinutes:   settings.isAnchorMode ? 0 : (settings.chartShowPredictor ? settings.chartPredictorMin : 0),
            laylineWaypoint:    settings.isAnchorMode ? nil : laylineDestination,
            trueWindDirection:  signalK.trueWindDirection,
            tackAngleDeg:       settings.chartTackAngleDeg,
            route:              settings.isAnchorMode ? nil : settings.activeRoute,
            guardZoneRadiusNm:  settings.aisGuardZoneEnabled ? settings.aisGuardZoneRadiusNm : 0,
            dangerousMMSIs:     piState.dangerousMMSIs,
            showPredictWindAIS: settings.chartShowPredictWindAIS,
            pwAISTargets:       predictWind.pwAIS,
            anchorMode:       settings.isAnchorMode,
            anchorActive:     settings.anchorActive,
            anchorLat:        settings.anchorLat,
            anchorLon:        settings.anchorLon,
            anchorRadius:     settings.anchorRadius,
            anchorFlash:      anchorFlash,
            anchorInitialTWD: settings.anchorInitialTWD,
            anchorWindShift:  settings.anchorWindShift,
            anchorWarnRadius: settings.anchorActive ? settings.effectiveWarnRadius : 0,
            anchorSwingTrack: anchorSwingCoords,
            anchorSwinging:   settings.anchorMooringType != "fixed",
            onAnchorMoved:    { coord in
                settings.anchorLat = coord.latitude
                settings.anchorLon = coord.longitude
                settings.persist()
            },
            onAnnotationLongPress: handleLongPress,
            onUserGesture:    {
                if settings.chartFollowVessel {
                    settings.chartFollowVessel = false
                    settings.persist()
                }
            },
            onRegionChange:   { region in
                // Ignore duplicate region callbacks (macOS fires these during
                // overlay/layout updates) — reacting to them creates a
                // render⇄region feedback loop that pegs the CPU.
                let key = String(format: "%.5f,%.5f,%.5f",
                                 region.center.latitude, region.center.longitude,
                                 region.span.longitudeDelta)
                guard key != lastViewportKey else { return }
                lastViewportKey = key
                updateContourPolygons(for: region)
            },
            measureMode:      measureMode,
            measureFrom:      $measureFromCoord,
            measureTo:        $measureToCoord,
            onMapTap:         handleTap,
            onAISTap:         { selectedAIS = $0 },
            zoomProxy:        zoomProxy
        )
    }

    /// Recent swing breadcrumb (last 2 h) drawn as a fan in anchor mode.
    private var anchorSwingCoords: [CLLocationCoordinate2D] {
        guard settings.isAnchorMode, settings.anchorActive else { return [] }
        let cutoff = Date().addingTimeInterval(-2 * 3600)
        return anchorWatch.track
            .filter { $0.time >= cutoff }
            .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    /// Used by the layline overlay. If a route is active, target the current
    /// leg's waypoint; otherwise fall back to the single user waypoint.
    private var laylineDestination: CLLocationCoordinate2D? {
        guard settings.chartShowLaylines, signalK.trueWindSpeed > 0.5 else { return nil }
        if let wp = settings.activeRoute?.activeWaypoint {
            return .init(latitude: wp.lat, longitude: wp.lon)
        }
        if settings.waypointActive {
            return .init(latitude: settings.waypointLat, longitude: settings.waypointLon)
        }
        return nil
    }

    // MARK: - Interactions

    private func handleTap(coord: CLLocationCoordinate2D) {
        // Anchor placing mode — tap sets the pending anchor position
        // anchor pin is dragged directly on the map — no tap-to-place mode needed
        // Tap is reserved for the measurement tool. Waypoints / routes / MOB
        // all come from the long-press menu — that way a stray tap on a glass
        // button overlay can't drop a waypoint behind it.
        guard measureMode else { return }
        if measureFromCoord == nil {
            measureFromCoord = coord
        } else if measureToCoord == nil {
            measureToCoord = coord
        } else {
            // Third tap restarts the measurement
            measureFromCoord = coord
            measureToCoord = nil
        }
    }

    // MARK: - Readouts

    private func measureReadout(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> some View {
        let nm = Geo.distanceNm(lat1: from.latitude, lon1: from.longitude,
                                lat2: to.latitude, lon2: to.longitude)
        let brg = Geo.bearing(lat1: from.latitude, lon1: from.longitude,
                              lat2: to.latitude, lon2: to.longitude)
        return HStack(spacing: 14) {
            statBlock(title: "Distance", value: String(format: "%.2f nm", nm))
            statBlock(title: "Bearing",  value: String(format: "%03.0f°T", brg))
            Button {
                measureFromCoord = nil; measureToCoord = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func waypointReadout(wp: (lat: Double, lon: Double, name: String)) -> some View {
        let nm = signalK.distanceTo(lat: wp.lat, lon: wp.lon)
        let brg = signalK.bearing(toLat: wp.lat, lon2: wp.lon)
        let ttg: String = {
            guard signalK.speedOverGround > 0.1 else { return "—" }
            let hrs = nm / signalK.speedOverGround
            let mins = Int((hrs * 60).rounded())
            if mins >= 60 { return String(format: "%dh %02dm", mins / 60, mins % 60) }
            return "\(mins) min"
        }()
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(wp.name).font(.caption).foregroundStyle(.white.opacity(0.75))
                Text(String(format: "%.2f nm · %03.0f°T · ETA %@", nm, brg, ttg))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            Spacer()
            Button {
                settings.waypointActive = false
                settings.persist()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func statBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.white.opacity(0.6))
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
    }

    /// Icon-only chart chip. All chips are white icons on a glass background;
    /// the "active" state tints the glass with accent cyan. No `.interactive()`
    /// modifier — we let SwiftUI's `Button` own the gesture so taps don't get
    /// swallowed by the glass effect.
    private func chip(icon: String, active: Bool = false, badge: String? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .glassBackground(active: active)
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.statusRed, in: Capsule())
                            .offset(x: 4, y: -4)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Long-press position sheet

    private func positionSheet(coord: CLLocationCoordinate2D) -> some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color.textTertiary.opacity(0.5))
                .frame(width: 40, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 16)

            // Coordinate header
            VStack(spacing: 4) {
                Text("Position")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)
                Text(formattedCoord(coord))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(.bottom, 20)

            // Action buttons grid
            VStack(spacing: 12) {
                // Anchor-mode shortcut: drop / move the anchor to this spot.
                if settings.isAnchorMode {
                    positionAction(icon: "anchor",
                                   label: settings.anchorActive ? "Move Anchor Here" : "Set Anchor Here",
                                   color: .systemOrange, fullWidth: true, anchorGlyph: true) {
                        settings.anchorLat = coord.latitude
                        settings.anchorLon = coord.longitude
                        if settings.anchorRadius <= 0 { settings.anchorRadius = 30 }
                        anchorWatch.dropAnchor(settings: settings, signalK: signalK)
                        settings.persist()
                        Task { await triggerForecastForAnchor() }
                        withAnimation { showLongPressMenu = false }
                    }
                }
                HStack(spacing: 12) {
                    positionAction(icon: "flag.fill",      label: "Set Waypoint",   color: .systemYellow) {
                        setWaypoint(coord)
                        withAnimation { showLongPressMenu = false }
                    }
                    positionAction(icon: "arrow.triangle.turn.up.right.diamond.fill",
                                   label: settings.activeRoute != nil ? "Add to Route" : "Start Route",
                                   color: .systemPurple) {
                        if settings.activeRoute != nil { appendToRoute(coord) } else { startRoute(coord) }
                        withAnimation { showLongPressMenu = false }
                    }
                }
                HStack(spacing: 12) {
                    positionAction(icon: "ruler",          label: "Measure",        color: .systemCyan) {
                        measureMode = true
                        measureFromCoord = coord; measureToCoord = nil
                        withAnimation { showLongPressMenu = false }
                    }
                    positionAction(icon: "arrow.down.to.line", label: "Depth Here", color: .systemTeal) {
                        probedDepthCoord = coord; probedDepth = nil
                        Task {
                            if let d = await BathymetryService.depth(at: coord) { probedDepth = d }
                        }
                        withAnimation { showLongPressMenu = false }
                    }
                }
                positionAction(icon: "exclamationmark.circle.fill", label: "Mark as MOB",
                               color: .systemRed, fullWidth: true) {
                    Task { await piState.setMOB(lat: coord.latitude, lon: coord.longitude) }
                    withAnimation { showLongPressMenu = false }
                }
            }
            .padding(.horizontal, 20)

            // Cancel
            Button("Cancel") { withAnimation(.spring(duration: 0.3)) { showLongPressMenu = false } }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.textSecondary)
                .padding(.top, 16)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
        .background(Color.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: -4)
    }

    @ViewBuilder
    private func positionAction(icon: String, label: String, color: PlatformColor,
                                fullWidth: Bool = false, anchorGlyph: Bool = false,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if anchorGlyph {
                        AnchorMark().frame(width: 22, height: 22).foregroundStyle(Color(color))
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color(color))
                    }
                }
                .frame(width: 28)
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                if fullWidth { Spacer() }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(minWidth: 0, maxWidth: fullWidth ? .infinity : nil)
            .background(Color.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.borderColor, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        if !fullWidth { Spacer(minLength: 0) }  // fill remaining HStack space
    }

    private func formattedCoord(_ c: CLLocationCoordinate2D) -> String {
        let latDir = c.latitude  >= 0 ? "N" : "S"
        let lonDir = c.longitude >= 0 ? "E" : "W"
        return String(format: "%.4f° %@   %.4f° %@",
                      abs(c.latitude), latDir, abs(c.longitude), lonDir)
    }

    // MARK: - Forecast trigger

    private func triggerForecastForAnchor() async {
        let piURL = settings.predictWindPiURL.isEmpty
            ? settings.anchorPiURL
                .replacingOccurrences(of: ":10112", with: ":10115")
                .replacingOccurrences(of: ":10114", with: ":10115")
            : settings.predictWindPiURL
        guard !piURL.isEmpty else { return }
        predictWind.configure(piURL: piURL)
        let locId = await predictWind.setForecastLocation(lat: settings.anchorLat, lon: settings.anchorLon)
        if settings.forecastAlarmEnabled, let lid = locId {
            await predictWind.setForecastAlarm(enabled: true, locationId: lid, settings: settings)
        }
    }
}

// MARK: - Glass background helper

extension View {
    /// Applies an iOS 26 Liquid Glass background where available, falling back
    /// to a tinted ultra-thin material elsewhere. `active` paints the chip with
    /// the accent color so it reads as "on".
    @ViewBuilder
    func glassBackground(active: Bool) -> some View {
        self.glassBackground(active: active, in: Circle())
    }

    /// Shape-generic variant so EVERY floating chart control — the round chips
    /// AND the Sail/Anchor mode capsule — shares one identical background
    /// treatment. Previously the chips used this glass/0.45 dark wash while the
    /// mode toggle used a separate `Color.black.opacity(0.6)` capsule, so the
    /// toggle read noticeably darker than the chips next to it ("some of the
    /// buttons are darker than the rest"). Routing both through here guarantees
    /// they render with the same darkness.
    @ViewBuilder
    func glassBackground<S: Shape>(active: Bool, in shape: S) -> some View {
        // The chart underneath can be anything from dark blue (deep water) to
        // near-white (sand, dry land at high zoom). To guarantee the white
        // icon stays readable, the glass is tinted with a dark wash unless
        // it's the accent-cyan active state.
        //
        // We also explicitly don't use `.interactive()` — that modifier
        // hijacks the gesture before the wrapping Button can claim it.
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(active ? .regular.tint(.accentCyan)
                                    : .regular.tint(Color.black.opacity(0.45)),
                             in: shape)
        } else {
            self.background(
                active ? AnyShapeStyle(Color.accentCyan.opacity(0.85))
                       : AnyShapeStyle(Color.black.opacity(0.45)),
                in: shape
            )
        }
    }
}

// MARK: - Geo helpers

enum Geo {
    static func distanceNm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let R  = 3440.065
        let φ1 = lat1 * .pi / 180, φ2 = lat2 * .pi / 180
        let Δφ = (lat2 - lat1) * .pi / 180
        let Δλ = (lon2 - lon1) * .pi / 180
        let a  = sin(Δφ/2)*sin(Δφ/2) + cos(φ1)*cos(φ2)*sin(Δλ/2)*sin(Δλ/2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    static func bearing(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let φ1 = lat1 * .pi / 180, φ2 = lat2 * .pi / 180
        let Δλ = (lon2 - lon1) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}

// MARK: - AIS detail sheet

private struct AISDetailSheet: View {
    let target: AISTarget
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var showFriendForm = false
    @State private var friendName = ""
    @State private var friendPhone = ""
    @State private var friendNotes = ""
    @State private var showContactPicker = false

    private var friend: AISFriend? {
        settings.aisFriends.first { $0.mmsi == target.mmsi }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: friend != nil ? "heart.fill" : "ferry.fill")
                            .font(.title)
                            .foregroundStyle(friend != nil ? Color.pink : Color.accentCyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(friend?.name ?? target.name ?? "Unknown")
                                .font(.title3).fontWeight(.semibold)
                                .foregroundStyle(Color.textPrimary)
                            Text("\(target.shipTypeLabel)  ·  MMSI \(target.mmsi)")
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }

                    if let f = friend {
                        friendCard(f)
                    } else {
                        Button { startAddFriend() } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "heart")
                                Text("Add as friend").fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(Color.pink.opacity(0.15))
                            .foregroundStyle(Color.pink)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                    VStack(spacing: 0) {
                        kv("Position", String(format: "%.5f°  %.5f°", target.latitude, target.longitude))
                        Divider().background(Color.borderColor).padding(.vertical, 8)
                        kv("SOG", String(format: "%.1f kn", target.sog))
                        Divider().background(Color.borderColor).padding(.vertical, 8)
                        kv("COG", String(format: "%03.0f°T", target.cog))
                        if let h = target.heading {
                            Divider().background(Color.borderColor).padding(.vertical, 8)
                            kv("Heading", String(format: "%03.0f°T", h))
                        }
                        if let c = target.callSign, !c.isEmpty {
                            Divider().background(Color.borderColor).padding(.vertical, 8)
                            kv("Call sign", c)
                        }
                        if let d = target.destination, !d.isEmpty {
                            Divider().background(Color.borderColor).padding(.vertical, 8)
                            kv("Destination", d)
                        }
                        if let l = target.length, l > 0 {
                            Divider().background(Color.borderColor).padding(.vertical, 8)
                            kv("Length", String(format: "%.0f m", l))
                        }
                        if let b = target.beam, b > 0 {
                            Divider().background(Color.borderColor).padding(.vertical, 8)
                            kv("Beam", String(format: "%.0f m", b))
                        }
                        if let d = target.draft, d > 0 {
                            Divider().background(Color.borderColor).padding(.vertical, 8)
                            kv("Draft", String(format: "%.1f m", d))
                        }
                    }
                    .cardStyle()

                    Text("Last update \(target.lastUpdate.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }
                .padding(16)
            }
            .background(Color.bgPrimary)
            .navigationTitle("AIS Target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Color.accentCyan)
                }
            }
        }
        .presentationBackground(Color.bgPrimary)
        .sheet(isPresented: $showFriendForm) { friendForm }
    }

    // MARK: Friend card

    @ViewBuilder
    private func friendCard(_ f: AISFriend) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Friend", systemImage: "heart.fill")
                    .font(.headline)
                    .foregroundStyle(Color.pink)
                Spacer()
                Button("Edit") { startEditFriend(f) }
                    .font(.caption).foregroundStyle(Color.accentCyan)
                Button {
                    settings.aisFriends.removeAll { $0.mmsi == f.mmsi }
                    settings.persist()
                } label: {
                    Image(systemName: "trash").foregroundStyle(Color.statusRed)
                }
                .buttonStyle(.plain)
            }
            if !f.phone.isEmpty {
                kv("Phone", f.phone)
            }
            if !f.notes.isEmpty {
                Text(f.notes).font(.caption).foregroundStyle(Color.textSecondary)
            }
            if let url = f.whatsappURL {
                Link(destination: url) {
                    HStack(spacing: 8) {
                        Image(systemName: "message.fill")
                        Text("Open WhatsApp").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(Color(red: 0.149, green: 0.827, blue: 0.396))
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            } else {
                Text("Add a phone number to enable WhatsApp")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .cardStyle()
    }

    // MARK: Add/edit form

    private var friendForm: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("MMSI \(target.mmsi)")
                        .font(.caption).foregroundStyle(Color.textSecondary)

                    Button { showContactPicker = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.crop.circle.badge.plus")
                            Text("Pick from Contacts")
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.accentCyan.opacity(0.15))
                        .foregroundStyle(Color.accentCyan)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    formField("Name", text: $friendName, placeholder: target.name ?? "Friend")
                    formField("Phone", text: $friendPhone, placeholder: "+356 12 345 678",
                              keyboard: .phonePad)
                    formField("Notes", text: $friendNotes, placeholder: "")

                    Button {
                        var copy = settings.aisFriends.filter { $0.mmsi != target.mmsi }
                        let resolved = friendName.trimmingCharacters(in: .whitespaces).isEmpty
                            ? (target.name ?? "MMSI \(target.mmsi)")
                            : friendName
                        copy.append(.init(
                            mmsi: target.mmsi,
                            name: resolved,
                            phone: friendPhone.trimmingCharacters(in: .whitespaces),
                            notes: friendNotes
                        ))
                        settings.aisFriends = copy
                        settings.persist()
                        showFriendForm = false
                    } label: {
                        Text("Save friend")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.pink)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
            .background(Color.bgPrimary)
            .navigationTitle(friend == nil ? "Add Friend" : "Edit Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showFriendForm = false }
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
        .presentationBackground(Color.bgPrimary)
        .sheetDetents([.medium, .large])
        .sheet(isPresented: $showContactPicker) {
            ContactPicker { name, phone in
                if !name.isEmpty  { friendName  = name }
                if !phone.isEmpty { friendPhone = phone }
                showContactPicker = false
            } onCancel: { showContactPicker = false }
        }
    }

    private func startAddFriend() {
        friendName  = target.name ?? ""
        friendPhone = ""
        friendNotes = ""
        showFriendForm = true
    }

    private func startEditFriend(_ f: AISFriend) {
        friendName  = f.name
        friendPhone = f.phone
        friendNotes = f.notes
        showFriendForm = true
    }

    private func formField(_ label: String, text: Binding<String>,
                           placeholder: String,
                           keyboard: PlatformKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Color.textSecondary)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.bgElevated)
                .foregroundStyle(Color.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.subheadline).foregroundStyle(Color.textSecondary)
            Spacer()
            Text(v).font(.subheadline).fontWeight(.medium).foregroundStyle(Color.textPrimary)
        }
    }
}
