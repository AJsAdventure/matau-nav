import Foundation
import CoreLocation
import UserNotifications
import Observation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Data types

extension AnchorWatchService {

    struct TrackPoint: Codable, Equatable, Sendable {
        let lat, lon: Double
        let time: Date
    }

    enum AlarmType: String, CaseIterable, Hashable, Sendable {
        case radius     = "Anchor Dragging"
        case windSpeed  = "Wind Too Strong"
        case windShift  = "Wind Shift"
        case depth      = "Depth Change"
        case gpsLoss    = "GPS Signal Lost"
        case lowBattery = "Phone Battery Low"
    }

    /// Whether an alarm is loud enough to wake a sleeping crew. Loud alarms
    /// drive the mute-bypassing AlarmPlayer; the rest are notification-only so
    /// a wind gust doesn't blast a siren at 3 a.m.
    static let loudAlarmTypes: Set<AlarmType> = [.radius, .gpsLoss]

    struct AlarmEvent: Identifiable, Sendable {
        let id     = UUID()
        let type:   AlarmType
        let time:   Date
        let detail: String
    }

    /// High-level holding state shown in the anchor console.
    enum HoldState: Sendable {
        case idle       // not anchored
        case holding    // inside the warning ring — all good
        case warning    // between warning ring and alarm radius
        case dragging   // outside the alarm radius
    }

    /// Best available position fix, picking the freshest of the boat's SignalK
    /// feed and the phone's own GPS. (Used only on the main actor.)
    struct Fix {
        let coord: CLLocationCoordinate2D
        let time:  Date
        let source: String   // "boat" | "phone"
    }
}

// MARK: - Service

@Observable @MainActor
final class AnchorWatchService: NSObject {

    // Track (last 3 days, sampled every ~15 s)
    private(set) var track: [TrackPoint] = []
    private var lastTrackTime: Date = .distantPast

    // Alarm state
    private(set) var activeAlarms: Set<AlarmType> = []
    private(set) var alarmLog: [AlarmEvent] = []
    var snoozedUntil: Date? = nil

    // Depth baseline recorded when anchor is dropped
    var depthBaseline: Double? = nil

    // Live anchor metrics (metres / degrees)
    private(set) var liveDistance: Double = 0      // current distance from anchor
    private(set) var liveBearing:  Double = 0      // bearing anchor → vessel
    private(set) var maxSwing:     Double = 0      // largest distance seen since drop

    // Phone GPS — redundant watcher independent of the boat network
    private(set) var deviceCoord:    CLLocationCoordinate2D?
    private(set) var deviceFixTime:  Date = .distantPast
    private(set) var deviceAccuracy: Double = -1   // horizontal accuracy, m

    // Phone battery (0…1, -1 unknown)
    private(set) var batteryLevel: Double = -1

    // Location auth
    private(set) var locationAuth: CLAuthorizationStatus = .notDetermined

    // Debounce — when the vessel first went out of bounds (nil = inside)
    private var breachStart: Date?
    /// Most recent time ANY valid fix (boat or phone) was seen — drives the
    /// 45 s GPS-loss debounce. Reset to "now" when the watch (re)arms.
    private var lastFixSeenAt: Date = .distantPast
    private var loudActive = false                 // we own the AlarmPlayer

    private let locationManager = CLLocationManager()
    private var monitoredRegion: CLCircularRegion?
    /// True while the chart wants this device's GPS running as a backup for the
    /// boat feed (independent of an active anchor watch). Keeps `stopWatch` from
    /// killing location updates the chart still relies on.
    private var chartFallbackGPS = false

    /// A fresh device-GPS coordinate, or nil if the last fix is too old to trust.
    /// Used by the chart to back up the boat position feed.
    var freshDeviceCoord: CLLocationCoordinate2D? {
        guard let c = deviceCoord, Date().timeIntervalSince(deviceFixTime) < 30 else { return nil }
        return c
    }

    // References captured at drop so the background location callback can run
    // the radius alarm even while the SwiftUI task loop is suspended.
    private weak var settingsRef: AppSettings?
    private weak var signalKRef:  SignalKService?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 3
        locationAuth = locationManager.authorizationStatus
        UNUserNotificationCenter.current().delegate = self
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        loadTrack()
    }

    // MARK: - Anchor lifecycle

    /// Where the anchor actually lands when dropping at the current position:
    /// the bow roller, projected ahead of the GPS antenna along heading.
    func dropPosition(signalK: SignalKService, settings: AppSettings) -> CLLocationCoordinate2D {
        let gps = CLLocationCoordinate2D(latitude: signalK.latitude, longitude: signalK.longitude)
        guard settings.anchorBowOffset > 0, signalK.headingMagnetic >= 0 else { return gps }
        return NavMath.destination(from: gps,
                                   bearingDeg: signalK.headingMagnetic,
                                   distanceM: settings.anchorBowOffset)
    }

    func dropAnchor(settings: AppSettings, signalK: SignalKService) {
        settingsRef = settings
        signalKRef  = signalK
        settings.anchorInitialTWD = signalK.trueWindDirection
        settings.anchorDropTime   = Date().timeIntervalSince1970
        settings.anchorActive     = true
        depthBaseline = signalK.depth > 0 ? signalK.depth : nil
        breachStart   = nil
        maxSwing      = 0
        settings.persist()
        startWatch(settings: settings)
        requestPermissions()
        // Keep the Mac awake for the duration of the watch (no-op on iOS).
        AppActivity.shared.beginAnchorWatch()
        // Seed the track + live metrics so the swing trail appears immediately.
        track.append(TrackPoint(lat: signalK.latitude, lon: signalK.longitude, time: Date()))
        lastTrackTime = Date()
        updateLiveMetrics(from: .init(latitude: signalK.latitude, longitude: signalK.longitude),
                          settings: settings)
        saveTrack()
    }

    func raiseAnchor(settings: AppSettings) {
        settings.anchorActive = false
        settings.persist()
        stopWatch()
        activeAlarms = []
        depthBaseline = nil
        breachStart   = nil
        maxSwing      = 0
        liveDistance  = 0
        if loudActive { AlarmSiren.shared.release("anchor-watch"); loudActive = false }
        // Release the sleep-prevention assertion (no-op on iOS).
        AppActivity.shared.endAnchorWatch()
    }

    // MARK: - Holding state

    func holdState(settings: AppSettings) -> HoldState {
        guard settings.anchorActive else { return .idle }
        if liveDistance > settings.anchorRadius        { return .dragging }
        if liveDistance > settings.effectiveWarnRadius { return .warning }
        return .holding
    }

    /// Horizontal distance from the bow to the anchor on the seabed, given rode
    /// paid out and water depth (Pythagoras on the catenary's straight-line
    /// approximation). Falls back to the rode length if depth is unknown.
    static func horizontalScope(rode: Double, depth: Double) -> Double {
        guard rode > 0 else { return 0 }
        let d = max(depth, 0)
        return (d > 0 && rode > d) ? (rode * rode - d * d).squareRoot() : rode
    }

    /// Plain-language read on whether the boat is swinging (good) or translating
    /// away from the anchor (bad) — derived from the recent track, advisory only.
    func swingDiagnosis(settings: AppSettings) -> String {
        guard settings.anchorActive else { return "" }
        // Fixed moorings (stern-to, two anchors, lines ashore) shouldn't move
        // much at all, so any drift is meaningful.
        if settings.anchorMooringType == "fixed" {
            if liveDistance > settings.anchorRadius { return "Moved off station — check lines" }
            if liveDistance > settings.effectiveWarnRadius { return "Drifting off station" }
            return "Held on station"
        }
        let recent = track.suffix(40)
        guard recent.count >= 6 else { return "Gathering swing data…" }
        let anchor = CLLocationCoordinate2D(latitude: settings.anchorLat, longitude: settings.anchorLon)
        // Centroid of the recent track; if it has translated well off the anchor
        // while distances stay high, that looks like a drag rather than a swing.
        let cLat = recent.map(\.lat).reduce(0, +) / Double(recent.count)
        let cLon = recent.map(\.lon).reduce(0, +) / Double(recent.count)
        let centroidOff = distanceMeters(anchor, .init(latitude: cLat, longitude: cLon))
        if liveDistance > settings.anchorRadius {
            return "Outside the circle — check the snubber"
        }
        if centroidOff > settings.anchorRadius * 0.6 {
            return "Sitting to one side — watch for drag"
        }
        return "Swinging on the hook"
    }

    // MARK: - Alarm checking  (call ~every 2 s from the app task)

    func checkAlarms(signalK: SignalKService, settings: AppSettings) {
        guard settings.anchorActive else { return }
        settingsRef = settings
        signalKRef  = signalK
        // Re-arm the geofence + background GPS if we relaunched while anchored.
        if monitoredRegion == nil { startWatch(settings: settings) }

        // Refresh battery + live metrics from the best available fix.
        #if os(iOS)
        batteryLevel = Double(UIDevice.current.batteryLevel)
        #else
        batteryLevel = -1   // no device battery to watch on a Mac nav station
        #endif
        if let fix = bestFix(signalK: signalK) {
            updateLiveMetrics(from: fix.coord, settings: settings)
        }

        if let snooze = snoozedUntil {
            if Date() < snooze { reconcileLoudAlarm(settings: settings); return }
            snoozedUntil = nil
        }

        // Position / drag (debounced) + GPS-loss
        evaluatePosition(signalK: signalK, settings: settings)

        // Wind speed (disabled / "Off" when at slider max of 60)
        if settings.anchorWindMax < 60 {
            fire(.windSpeed, active: signalK.trueWindSpeed > settings.anchorWindMax,
                 detail: String(format: "TWS %.1f kts (limit %.0f kts)", signalK.trueWindSpeed, settings.anchorWindMax))
        } else { activeAlarms.remove(.windSpeed) }

        // Wind shift (disabled / "Off" when at slider max of 90)
        let shift = angularDiff(signalK.trueWindDirection, settings.anchorInitialTWD)
        if settings.anchorWindShift < 90 {
            fire(.windShift, active: abs(shift) > settings.anchorWindShift,
                 detail: String(format: "TWD shifted %.0f° (limit %.0f°)", abs(shift), settings.anchorWindShift))
        } else { activeAlarms.remove(.windShift) }

        // Depth outside the configured safe range
        if signalK.depth > 0 {
            let active = signalK.depth < settings.anchorDepthMin || signalK.depth > settings.anchorDepthMax
            fire(.depth, active: active,
                 detail: String(format: "Depth %.1f m (safe %.1f–%.1f m)",
                                signalK.depth, settings.anchorDepthMin, settings.anchorDepthMax))
        }

        // Low phone battery (iOS only — a desktop has no relevant battery)
        #if os(iOS)
        if settings.anchorLowBatteryAlarm, batteryLevel >= 0 {
            let pct = batteryLevel * 100
            let unplugged = UIDevice.current.batteryState == .unplugged
            fire(.lowBattery, active: unplugged && pct <= settings.anchorLowBatteryPct,
                 detail: String(format: "Battery %.0f%% — plug in to keep the watch alive", pct))
        } else { activeAlarms.remove(.lowBattery) }
        #else
        activeAlarms.remove(.lowBattery)
        #endif

        reconcileLoudAlarm(settings: settings)
    }

    /// Radius (debounced) + GPS-loss. Runs from both the foreground task and the
    /// background location callback so the drag alarm fires even when asleep.
    private func evaluatePosition(signalK: SignalKService, settings: AppSettings) {
        guard settings.anchorActive else { return }
        let fix = bestFix(signalK: signalK)

        // GPS-loss: no fresh fix from either source for 45 s. Debounce via
        // lastFixSeenAt — boat fixes are stamped "now", so testing fix.time
        // alone would fire the LOUD alarm the instant the boat feed drops
        // (8 s liveness window) instead of after the advertised 45 s. A brief
        // Wi-Fi blip at anchor must not blast the siren; a real outage still
        // alarms within a minute.
        if let fix { lastFixSeenAt = max(lastFixSeenAt, fix.time) }
        if settings.anchorGPSLossAlarm {
            let stale = Date().timeIntervalSince(lastFixSeenAt) > 45
            fire(.gpsLoss, active: stale, detail: "No GPS fix for 45 s — position unknown")
            if fix == nil { return }   // can't judge the circle without a position
        } else {
            activeAlarms.remove(.gpsLoss)
        }

        guard let fix else { return }
        let distM = distanceMeters(.init(latitude: settings.anchorLat, longitude: settings.anchorLon), fix.coord)

        if distM > settings.anchorRadius {
            if breachStart == nil { breachStart = Date() }
            let elapsed = Date().timeIntervalSince(breachStart ?? Date())
            let confirmed = elapsed >= settings.anchorAlarmDelay
            fire(.radius, active: confirmed,
                 detail: String(format: "%.0f m from anchor (limit %.0f m) · %@",
                                distM, settings.anchorRadius, fix.source == "phone" ? "phone GPS" : "boat GPS"))
        } else {
            breachStart = nil
            activeAlarms.remove(.radius)
        }
    }

    /// Start/stop the loud mute-bypassing alarm based on whether any loud alarm
    /// is active and not snoozed.
    private func reconcileLoudAlarm(settings: AppSettings) {
        let snoozed = (snoozedUntil.map { Date() < $0 }) ?? false
        let wantLoud = !snoozed && !activeAlarms.isDisjoint(with: Self.loudAlarmTypes)
        if wantLoud {
            // Refcounted via AlarmSiren: a Pi-daemon alarm clearing can never
            // silence a live drag alarm, and re-acquiring every ~2 s doubles
            // as the self-heal after an audio-session interruption.
            AlarmSiren.shared.acquire("anchor-watch")
            loudActive = true
        } else if loudActive {
            AlarmSiren.shared.release("anchor-watch")
            loudActive = false
        }
    }

    func snooze(minutes: Int = 15) {
        snoozedUntil = Date().addingTimeInterval(Double(minutes) * 60)
        activeAlarms = []
        breachStart  = nil
        if loudActive { AlarmSiren.shared.release("anchor-watch"); loudActive = false }
    }

    func clearLog() { alarmLog = [] }

    // MARK: - Position helpers

    /// Pick the freshest trustworthy fix. The phone GPS keeps working in the
    /// background (and when the boat Wi-Fi drops), so it's preferred when fresh.
    private func bestFix(signalK: SignalKService) -> Fix? {
        let now = Date()
        var phone: Fix?
        if let c = deviceCoord, now.timeIntervalSince(deviceFixTime) < 20 {
            phone = Fix(coord: c, time: deviceFixTime, source: "phone")
        }
        var boat: Fix?
        // boatPositionIsLive, not state.isConnected: right after the boat
        // network drops, the connection state can still read "connected" while
        // latitude/longitude are frozen at the last fix. Treating that as a
        // valid fix would blind the drag alarm exactly when it matters —
        // better to fall through to the phone GPS / GPS-loss alarm.
        if signalK.boatPositionIsLive, signalK.latitude != 0 || signalK.longitude != 0 {
            boat = Fix(coord: .init(latitude: signalK.latitude, longitude: signalK.longitude),
                       time: now, source: "boat")
        }
        if settingsRef?.anchorUseDeviceGPS == false { return boat ?? phone }
        // Prefer phone when fresh; otherwise the boat feed.
        return phone ?? boat
    }

    private func updateLiveMetrics(from coord: CLLocationCoordinate2D, settings: AppSettings) {
        let anchor = CLLocationCoordinate2D(latitude: settings.anchorLat, longitude: settings.anchorLon)
        liveDistance = distanceMeters(anchor, coord)
        liveBearing  = NavMath.bearingDeg(anchor, coord)
        if liveDistance > maxSwing { maxSwing = liveDistance }
    }

    // MARK: - Track recording

    func recordPosition(lat: Double, lon: Double) {
        // (0,0) is "no fix yet", not a position — recording it would put
        // null-island points into the swing breadcrumb and drag stats.
        guard lat != 0 || lon != 0 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTrackTime) >= 15 else { return }
        lastTrackTime = now
        track.append(TrackPoint(lat: lat, lon: lon, time: now))
        let cutoff = now.addingTimeInterval(-3 * 24 * 3600)
        if (track.first?.time ?? now) < cutoff {
            track.removeAll { $0.time < cutoff }
        }
        saveTrack()
    }

    func clearTrack() { track = []; saveTrack(); maxSwing = liveDistance }

    // MARK: - Auto-learned swing circle

    /// Largest distance from the anchor observed over the recording window, plus
    /// a safety buffer. Used to propose a right-sized radius once the boat has
    /// settled and shown its true swing.
    func observedSwingRadius(settings: AppSettings, buffer: Double = 10) -> Double? {
        guard settings.anchorActive else { return nil }
        let anchor = CLLocationCoordinate2D(latitude: settings.anchorLat, longitude: settings.anchorLon)
        let dists = track.map { distanceMeters(anchor, .init(latitude: $0.lat, longitude: $0.lon)) }
        guard let maxD = dists.max(), maxD > 0 else { return nil }
        return (maxD + buffer).rounded()
    }

    /// Minutes of swing data gathered since the anchor was dropped.
    func minutesWatched(settings: AppSettings) -> Int {
        guard settings.anchorDropTime > 0 else { return 0 }
        return Int((Date().timeIntervalSince1970 - settings.anchorDropTime) / 60)
    }

    // MARK: - Helpers

    func currentDistance(to settings: AppSettings, signalK: SignalKService) -> Double {
        signalK.distanceTo(lat: settings.anchorLat, lon: settings.anchorLon) * 1852.0
    }

    func windShift(settings: AppSettings, signalK: SignalKService) -> Double {
        angularDiff(signalK.trueWindDirection, settings.anchorInitialTWD)
    }

    private func angularDiff(_ a: Double, _ b: Double) -> Double {
        var d = a - b
        while d >  180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    private func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let R  = 6_371_000.0
        let φ1 = a.latitude  * .pi / 180, φ2 = b.latitude  * .pi / 180
        let dφ = (b.latitude  - a.latitude)  * .pi / 180
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let aa = sin(dφ/2)*sin(dφ/2) + cos(φ1)*cos(φ2)*sin(dλ/2)*sin(dλ/2)
        return R * 2 * atan2(sqrt(aa), sqrt(1 - aa))
    }

    private func fire(_ type: AlarmType, active: Bool, detail: String) {
        if active, !activeAlarms.contains(type) {
            activeAlarms.insert(type)
            let event = AlarmEvent(type: type, time: Date(), detail: detail)
            alarmLog.insert(event, at: 0)
            if alarmLog.count > 100 { alarmLog.removeLast() }
            sendNotification(type: type, detail: detail)
        } else if !active {
            activeAlarms.remove(type)
        }
    }

    // MARK: - Watch (geofence + continuous background GPS)

    private func startWatch(settings: AppSettings) {
        // Fresh GPS-loss grace window: arming (or re-arming after relaunch)
        // while the feeds are still coming up must not instantly alarm.
        lastFixSeenAt = Date()
        if let prev = monitoredRegion { locationManager.stopMonitoring(for: prev) }
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: settings.anchorLat, longitude: settings.anchorLon),
            radius: max(settings.anchorRadius, 50),
            identifier: "matau_anchor"
        )
        region.notifyOnExit  = true
        region.notifyOnEntry = true
        monitoredRegion = region
        locationManager.requestAlwaysAuthorization()
        locationManager.startMonitoring(for: region)

        // Continuous GPS so the phone is a live, independent watcher even with
        // the screen off and the boat network down.
        if settings.anchorUseDeviceGPS {
            #if os(iOS)
            if locationManager.authorizationStatus == .authorizedAlways {
                locationManager.allowsBackgroundLocationUpdates = true
            }
            locationManager.pausesLocationUpdatesAutomatically = false
            #endif
            locationManager.startUpdatingLocation()
        }

        #if os(macOS)
        // AVAudioPlayer cannot bypass a muted output device on macOS. Warn at
        // arming time — a silent drag alarm discovered at 3 a.m. is too late.
        if SystemAudio.outputEffectivelySilent {
            let event = AlarmEvent(type: .radius, time: Date(),
                                   detail: "Mac audio is muted or at zero volume — the drag alarm will be SILENT. Turn the volume up.")
            alarmLog.insert(event, at: 0)
            let content = UNMutableNotificationContent()
            content.title             = "⚓ Anchor alarm may be silent"
            content.body              = "This Mac's output is muted or at zero volume. Turn it up so the drag alarm can be heard."
            content.sound             = .defaultCritical
            content.interruptionLevel = .timeSensitive
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "anchor_mute_warning", content: content, trigger: nil))
        }
        #endif
    }

    private func stopWatch() {
        if let r = monitoredRegion { locationManager.stopMonitoring(for: r); monitoredRegion = nil }
        // Keep GPS running if the chart still wants it as a position backup.
        if !chartFallbackGPS { locationManager.stopUpdatingLocation() }
        #if os(iOS)
        locationManager.allowsBackgroundLocationUpdates = false
        #endif
    }

    // MARK: - Chart position backup

    /// Keep this device's GPS running while the chart is on screen so it can back
    /// up the boat feed even when no anchor watch is active — this is what lets
    /// the vessel marker keep moving after the boat's chartplotter / network is
    /// switched off. Foreground only; safe to call repeatedly.
    func startChartFallbackGPS() {
        chartFallbackGPS = true
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    /// Stop the chart's GPS backup. Leaves updates running if an anchor watch is
    /// still active (that path owns them independently).
    func stopChartFallbackGPS() {
        chartFallbackGPS = false
        if monitoredRegion == nil { locationManager.stopUpdatingLocation() }
    }

    // MARK: - Notifications

    func requestPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        locationManager.requestAlwaysAuthorization()
    }

    private func sendNotification(type: AlarmType, detail: String) {
        let content = UNMutableNotificationContent()
        content.title             = "⚓ \(type.rawValue)"
        content.body              = detail
        content.sound             = Self.loudAlarmTypes.contains(type) ? .defaultCritical : .default
        content.interruptionLevel = .timeSensitive
        let req = UNNotificationRequest(
            identifier: "anchor_\(type.rawValue)_\(Date().timeIntervalSince1970)",
            content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Track persistence

    private var trackURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("anchor_track.json")
    }

    private func saveTrack() {
        // Encode + write off the main actor: a 3-day track is ~17k points and
        // this runs every 15 s during an anchor watch — doing it inline was a
        // periodic hitch on the chart. Last-write-wins is fine here.
        let snapshot = track
        let url = trackURL
        Task.detached(priority: .utility) {
            try? JSONEncoder().encode(snapshot).write(to: url)
        }
    }

    private func loadTrack() {
        guard let data = try? Data(contentsOf: trackURL),
              let pts  = try? JSONDecoder().decode([TrackPoint].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-3 * 24 * 3600)
        track = pts.filter { $0.time >= cutoff }
    }
}

// MARK: - CLLocationManagerDelegate

extension AnchorWatchService: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.locationAuth = status
            // Enable background updates once Always is granted while watching.
            if status == .authorizedAlways, self.monitoredRegion != nil,
               self.settingsRef?.anchorUseDeviceGPS == true {
                #if os(iOS)
                self.locationManager.allowsBackgroundLocationUpdates = true
                #endif
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        // Capture primitives (Sendable) rather than the CLLocationCoordinate2D.
        let lat = loc.coordinate.latitude
        let lon = loc.coordinate.longitude
        let acc = loc.horizontalAccuracy
        let time = loc.timestamp
        Task { @MainActor in
            // Reject obviously bad fixes (negative accuracy = invalid).
            guard acc >= 0, acc < 100 else { return }
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            self.deviceCoord    = coord
            self.deviceFixTime  = time
            self.deviceAccuracy = acc
            guard let settings = self.settingsRef, settings.anchorActive else { return }
            self.recordPosition(lat: lat, lon: lon)
            self.updateLiveMetrics(from: coord, settings: settings)
            // Run the position alarm off the GPS callback so it works in the
            // background, where the SwiftUI 2 s task is suspended.
            if let sk = self.signalKRef {
                self.evaluatePosition(signalK: sk, settings: settings)
                self.reconcileLoudAlarm(settings: settings)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == "matau_anchor" else { return }
        let content = UNMutableNotificationContent()
        content.title             = "⚓ Anchor Dragging"
        content.body              = "Vessel has left the anchor radius"
        content.sound             = .defaultCritical
        content.interruptionLevel = .timeSensitive
        let req = UNNotificationRequest(identifier: "anchor_exit_\(Date().timeIntervalSince1970)",
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
        Task { @MainActor in
            self.activeAlarms.insert(.radius)
            self.alarmLog.insert(AlarmEvent(type: .radius, time: Date(), detail: "Left anchor radius (geofence)"), at: 0)
            if let s = self.settingsRef { self.reconcileLoudAlarm(settings: s) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == "matau_anchor" else { return }
        Task { @MainActor in self.activeAlarms.remove(.radius) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     monitoringDidFailFor region: CLRegion?,
                                     withError error: Error) { }
}

// MARK: - UNUserNotificationCenterDelegate  (show banners + play sound while app is open)

extension AnchorWatchService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
