import Foundation
import Observation

// MARK: - Per-instrument display & filtering config

struct InstrumentConfig: Codable, Equatable {
    /// Rolling-average window in samples (5 s each). 1 = raw/off.
    var dampingSamples: Int    = 1
    /// Outlier rejection threshold as σ multiplier. 0 = off.
    var outlierFactor:  Double = 0.0
    /// Show min/max labels on the sparkline.
    var showMinMax:     Bool   = true
    /// Overlay linear-regression trend line on the sparkline.
    var showTrend:      Bool   = false
}

@Observable
@MainActor
final class AppSettings {
    var signalKHost:   String = "matau.local"
    var signalKPort:   Int    = 3000
    var signalKUseTLS: Bool   = false
    /// Tailscale address of the boat Pi (IP or MagicDNS name). Automatic
    /// remote fallback for EVERYTHING on that machine — SignalK instruments
    /// and all the Pi services on their ports. Empty = fallback disabled.
    var tailscaleHost: String = "100.100.220.67"

    /// Public HTTPS remote bridge (Cloudflare Tunnel) — works from any
    /// network with no VPN app, so it coexists with NordVPN. Each Pi port is
    /// published as https://matau-<port>.<remoteDomain>, protected by a
    /// Cloudflare Access service token. Empty domain = bridge disabled.
    var remoteDomain:     String = ""    // e.g. "gleser.ai"
    var cfAccessClientId: String = ""    // Access service token ID (secret in Keychain)

    static let remoteHostPrefix = "matau-"

    /// Base URL of a Pi service over the public bridge, or nil when disabled.
    func remoteBase(port: Int) -> String? {
        let d = remoteDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { return nil }
        return "https://\(Self.remoteHostPrefix)\(port).\(d)"
    }

    /// Cloudflare Access service-token headers — required on every request to
    /// a remote-bridge hostname, deliberately withheld from cleartext LAN and
    /// Tailscale requests so the secret only ever travels inside TLS.
    func boatAuthHeaders(forBase base: String) -> [String: String] {
        let d = remoteDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty, base.contains(d),
              !cfAccessClientId.isEmpty,
              let secret = CFAccessKeychain.loadSecret(), !secret.isEmpty else { return [:] }
        return ["CF-Access-Client-Id":     cfAccessClientId,
                "CF-Access-Client-Secret": secret]
    }

    // Autopilot corner instruments (raw string values of Instrument enum)
    var cornerTopLeft:     String = "sog"
    var cornerTopRight:    String = "twa"
    var cornerBottomLeft:  String = "twd"
    var cornerBottomRight: String = "tws"

    var nightMode: Bool = false

    // Waypoint
    var waypointActive: Bool   = false
    var waypointLat:    Double = 0
    var waypointLon:    Double = 0
    var waypointName:   String = ""

    // Anchor Watch
    var anchorActive:     Bool   = false
    var anchorLat:        Double = 0
    var anchorLon:        Double = 0
    var anchorRadius:     Double = 50    // metres
    var anchorWindMax:    Double = 25    // knots
    var anchorWindShift:  Double = 45    // degrees from initial TWD
    var anchorInitialTWD: Double = 0     // TWD recorded when anchor dropped
    var anchorDropTime:   Double = 0     // Unix timestamp

    // Depth alarm range
    var anchorDepthMin:   Double = 2.0   // metres – alarm if shallower
    var anchorDepthMax:   Double = 10.0  // metres – alarm if deeper

    // Anchor geometry & robustness
    /// Horizontal distance from the GPS antenna to the bow roller (metres).
    /// The anchor is projected this far ahead of the GPS along heading at drop.
    var anchorBowOffset:   Double = 0
    /// Rode (chain/warp) deployed, metres. Used to suggest a swing radius.
    var anchorRodeLength:  Double = 0
    /// Inner warning ring radius (metres). 0 ⇒ auto = 0.75 × alarm radius.
    var anchorWarnRadius:  Double = 0
    /// Seconds the vessel must remain out-of-bounds before the drag alarm fires
    /// (debounce — rejects momentary GPS excursions). 0 = instant.
    var anchorAlarmDelay:  Double = 25
    /// Fire an alarm if the GPS fix is lost / goes stale while anchored.
    var anchorGPSLossAlarm: Bool  = true
    /// Fire an alarm when the phone battery drops below the threshold while anchored.
    var anchorLowBatteryAlarm: Bool = true
    var anchorLowBatteryPct:   Double = 20
    /// Use the phone's own GPS as a redundant watcher (independent of the boat
    /// SignalK feed) so the alarm still works if the boat network drops.
    var anchorUseDeviceGPS: Bool = true
    /// "swinging" = single bow anchor, free to weathervane (full swing circle).
    /// "fixed"    = stern anchor / stern-to / two anchors / lines ashore — the
    /// boat is held, so the watch is a tight box around the made-fast position.
    var anchorMooringType: String = "swinging"
    /// Saved anchorages the user can re-drop at.
    var savedAnchorages: [Anchorage] = []

    // Pi alarm daemon
    var anchorPiURL:            String = ""               // e.g. "http://matau.local:10112"
    var anchorPiTailscaleURL:   String = ""               // e.g. "http://100.100.220.67:10112"
    var anchorNtfyTopic:        String = ""               // ntfy topic name
    var anchorNtfyServer:       String = "https://ntfy.sh"

    // Per-instrument display config
    var instrumentConfigs: [String: InstrumentConfig] = [:]

    // GPS coordinate display format ("DDM" | "DD" | "DMS")
    var gpsCoordFormat: String = "DDM"

    // Man Overboard
    var mobActive: Bool   = false
    var mobLat:    Double = 0
    var mobLon:    Double = 0
    var mobTime:   Double = 0    // Unix timestamp when MOB was triggered

    // Chart
    var chartSatellite:        Bool   = false
    var chartOpenSeaMap:       Bool   = true
    var chartBathymetry:       Bool   = false   // EMODnet DTM 2024 depth shading
    var chartShowAIS:          Bool   = true
    var chartShowTracks:       Bool   = true
    var chartFollowVessel:     Bool   = true
    var chartNorthUp:          Bool   = true
    var chartTrailMinutes:     Int    = 60      // COG breadcrumb shown ahead of vessel
    var aisStreamAPIKey:       String = ""      // aisstream.io free WebSocket key
    var aisRangeNm:            Double = 20      // bbox radius around vessel for AIS subscription
    /// Cached downloaded regions for the Chart download manager.
    /// Stored as JSON because UserDefaults doesn't carry rich types.
    var chartDownloadedRegions: [ChartRegion] = []

    /// AIS targets the user has tagged as friends. Get a heart icon on the
    /// chart and a one-tap WhatsApp link if a phone number is set.
    var aisFriends: [AISFriend] = []

    // MARK: Chartplotter overlays
    var chartShowPredictor:   Bool   = true
    /// Predictor tick interval choices (minutes). Short marks for coastal
    /// hops, hours for passages — 24 h of ticks turns the line into a
    /// passage ruler.
    static let predictorTickChoices = [5, 10, 15, 30, 60, 180, 360, 720, 1440]
    static func predictorTickLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h"
    }
    var chartPredictorMin:    Int    = 6        // minutes ahead the predictor line extends
    var chartShowLaylines:    Bool   = true
    var chartTackAngleDeg:    Double = 45       // closed-hauled tacking half-angle
    var chartShowWindRibbon:  Bool   = true
    var chartShowSetDrift:    Bool   = true

    // MARK: AIS safety
    var aisCPAAlarmEnabled:   Bool   = true
    var aisCPAThresholdNm:    Double = 0.5      // closer than this triggers
    var aisTCPAThresholdMin:  Double = 10       // within this many minutes triggers
    var aisGuardZoneEnabled:  Bool   = false
    var aisGuardZoneRadiusNm: Double = 1.0
    /// MMSIs the user has acknowledged for the current alarm; cleared on app launch.
    var aisAcknowledgedMMSIs: Set<Int> = []

    // MARK: Active route (single, ordered list of legs from vessel)
    var activeRoute: Route? = nil

    // MARK: PredictWind
    var predictWindPiURL:        String = ""    // e.g. "http://matau.local:10115"
    var chartShowPredictWindAIS: Bool   = true  // overlay PW commercial AIS on chart

    // MARK: Chart mode
    var chartMode: String = "sail"   // "sail" | "anchor"

    // MARK: Forecast alarm
    var forecastAlarmEnabled:    Bool   = false
    var forecastAlarmMaxWindKn:  Double = 20
    var forecastAlarmMaxWaveM:   Double = 1.5
    var forecastAlarmHoursAhead: Int    = 24

    private enum Keys {
        static let host              = "signalKHost"
        static let port              = "signalKPort"
        static let useTLS            = "signalKUseTLS"
        static let tailscaleHost     = "tailscaleHost"
        static let remoteDomain      = "remoteDomain"
        static let cfAccessClientId  = "cfAccessClientId"
        static let cornerTopLeft     = "cornerTopLeft"
        static let cornerTopRight    = "cornerTopRight"
        static let cornerBotLeft     = "cornerBottomLeft"
        static let cornerBotRight    = "cornerBottomRight"
        static let nightMode         = "nightMode"
        static let waypointActive    = "waypointActive"
        static let waypointLat       = "waypointLat"
        static let waypointLon       = "waypointLon"
        static let waypointName      = "waypointName"
        static let anchorActive      = "anchorActive"
        static let anchorLat         = "anchorLat"
        static let anchorLon         = "anchorLon"
        static let anchorRadius      = "anchorRadius"
        static let anchorWindMax     = "anchorWindMax"
        static let anchorWindShift   = "anchorWindShift"
        static let anchorInitialTWD  = "anchorInitialTWD"
        static let anchorDropTime    = "anchorDropTime"
        static let anchorDepthMin    = "anchorDepthMin"
        static let anchorDepthMax    = "anchorDepthMax"
        static let anchorBowOffset       = "anchorBowOffset"
        static let anchorRodeLength      = "anchorRodeLength"
        static let anchorWarnRadius      = "anchorWarnRadius"
        static let anchorAlarmDelay      = "anchorAlarmDelay"
        static let anchorGPSLossAlarm    = "anchorGPSLossAlarm"
        static let anchorLowBatteryAlarm = "anchorLowBatteryAlarm"
        static let anchorLowBatteryPct   = "anchorLowBatteryPct"
        static let anchorUseDeviceGPS    = "anchorUseDeviceGPS"
        static let anchorMooringType     = "anchorMooringType"
        static let savedAnchorages       = "savedAnchorages"
        static let anchorPiURL            = "anchorPiURL"
        static let anchorPiTailscaleURL   = "anchorPiTailscaleURL"
        static let anchorNtfyTopic        = "anchorNtfyTopic"
        static let anchorNtfyServer       = "anchorNtfyServer"
        static let instrumentConfigs      = "instrumentConfigs"
        static let gpsCoordFormat         = "gpsCoordFormat"
        static let mobActive              = "mobActive"
        static let mobLat                 = "mobLat"
        static let mobLon                 = "mobLon"
        static let mobTime                = "mobTime"
        static let chartSatellite         = "chartSatellite"
        static let chartOpenSeaMap        = "chartOpenSeaMap"
        static let chartBathymetry        = "chartBathymetry"
        static let chartShowAIS           = "chartShowAIS"
        static let chartShowTracks        = "chartShowTracks"
        static let chartFollowVessel      = "chartFollowVessel"
        static let chartNorthUp           = "chartNorthUp"
        static let chartTrailMinutes      = "chartTrailMinutes"
        static let aisStreamAPIKey        = "aisStreamAPIKey"
        static let aisRangeNm             = "aisRangeNm"
        static let chartDownloadedRegions = "chartDownloadedRegions"
        static let aisFriends             = "aisFriends"
        static let chartShowPredictor     = "chartShowPredictor"
        static let chartPredictorMin      = "chartPredictorMin"
        static let chartShowLaylines      = "chartShowLaylines"
        static let chartTackAngleDeg      = "chartTackAngleDeg"
        static let chartShowWindRibbon    = "chartShowWindRibbon"
        static let chartShowSetDrift      = "chartShowSetDrift"
        static let aisCPAAlarmEnabled     = "aisCPAAlarmEnabled"
        static let aisCPAThresholdNm      = "aisCPAThresholdNm"
        static let aisTCPAThresholdMin    = "aisTCPAThresholdMin"
        static let aisGuardZoneEnabled    = "aisGuardZoneEnabled"
        static let aisGuardZoneRadiusNm   = "aisGuardZoneRadiusNm"
        static let activeRoute            = "activeRoute"
        static let predictWindPiURL       = "predictWindPiURL"
        static let chartShowPredictWindAIS = "chartShowPredictWindAIS"
        static let chartMode              = "chartMode"
        static let forecastAlarmEnabled   = "forecastAlarmEnabled"
        static let forecastAlarmMaxWindKn = "forecastAlarmMaxWindKn"
        static let forecastAlarmMaxWaveM  = "forecastAlarmMaxWaveM"
        static let forecastAlarmHoursAhead = "forecastAlarmHoursAhead"
    }

    init() {
        let ud = UserDefaults.standard
        if let h = ud.string(forKey: Keys.host), !h.isEmpty { signalKHost = h }
        let p = ud.integer(forKey: Keys.port); if p > 0 { signalKPort = p }
        signalKUseTLS = ud.bool(forKey: Keys.useTLS)
        if let t = ud.string(forKey: Keys.tailscaleHost) {
            tailscaleHost = t   // "" is a valid saved value: fallback disabled
        } else if let raw = ud.string(forKey: Keys.anchorPiTailscaleURL),
                  let comps = URLComponents(string: raw),
                  let h = comps.host, !h.isEmpty {
            tailscaleHost = h   // migrate: reuse the anchor daemon's Tailscale IP
        }
        remoteDomain     = ud.string(forKey: Keys.remoteDomain)     ?? ""
        cfAccessClientId = ud.string(forKey: Keys.cfAccessClientId) ?? ""
        if let v = ud.string(forKey: Keys.cornerTopLeft)  { cornerTopLeft   = v }
        if let v = ud.string(forKey: Keys.cornerTopRight) { cornerTopRight  = v }
        if let v = ud.string(forKey: Keys.cornerBotLeft)  { cornerBottomLeft  = v }
        if let v = ud.string(forKey: Keys.cornerBotRight) { cornerBottomRight = v }
        nightMode        = ud.bool(forKey: Keys.nightMode)
        waypointActive   = ud.bool(forKey: Keys.waypointActive)
        waypointLat      = ud.double(forKey: Keys.waypointLat)
        waypointLon      = ud.double(forKey: Keys.waypointLon)
        waypointName     = ud.string(forKey: Keys.waypointName) ?? ""
        anchorActive     = ud.bool(forKey: Keys.anchorActive)
        anchorLat        = ud.double(forKey: Keys.anchorLat)
        anchorLon        = ud.double(forKey: Keys.anchorLon)
        let r = ud.double(forKey: Keys.anchorRadius); anchorRadius = r > 0 ? r : 50
        let w = ud.double(forKey: Keys.anchorWindMax); anchorWindMax = w > 0 ? w : 25
        let s = ud.double(forKey: Keys.anchorWindShift); anchorWindShift = s > 0 ? s : 45
        anchorInitialTWD = ud.double(forKey: Keys.anchorInitialTWD)
        anchorDropTime   = ud.double(forKey: Keys.anchorDropTime)
        let dMin = ud.double(forKey: Keys.anchorDepthMin); anchorDepthMin = dMin > 0 ? dMin : 2.0
        let dMax = ud.double(forKey: Keys.anchorDepthMax); anchorDepthMax = dMax > 0 ? dMax : 10.0
        anchorBowOffset   = ud.double(forKey: Keys.anchorBowOffset)
        anchorRodeLength  = ud.double(forKey: Keys.anchorRodeLength)
        anchorWarnRadius  = ud.double(forKey: Keys.anchorWarnRadius)
        anchorAlarmDelay  = ud.object(forKey: Keys.anchorAlarmDelay) as? Double ?? 25
        anchorGPSLossAlarm    = ud.object(forKey: Keys.anchorGPSLossAlarm)    as? Bool ?? true
        anchorLowBatteryAlarm = ud.object(forKey: Keys.anchorLowBatteryAlarm) as? Bool ?? true
        let lbp = ud.double(forKey: Keys.anchorLowBatteryPct); anchorLowBatteryPct = lbp > 0 ? lbp : 20
        anchorUseDeviceGPS    = ud.object(forKey: Keys.anchorUseDeviceGPS)    as? Bool ?? true
        anchorMooringType     = ud.string(forKey: Keys.anchorMooringType) ?? "swinging"
        if let v = Self.loadBlob([Anchorage].self, key: Keys.savedAnchorages, ud: ud) {
            savedAnchorages = v
        }
        anchorPiURL            = ud.string(forKey: Keys.anchorPiURL)            ?? ""
        anchorPiTailscaleURL   = ud.string(forKey: Keys.anchorPiTailscaleURL)   ?? ""
        anchorNtfyTopic        = ud.string(forKey: Keys.anchorNtfyTopic)        ?? ""
        anchorNtfyServer       = ud.string(forKey: Keys.anchorNtfyServer)       ?? "https://ntfy.sh"
        if let v = Self.loadBlob([String: InstrumentConfig].self, key: Keys.instrumentConfigs, ud: ud) {
            instrumentConfigs = v
        }
        gpsCoordFormat         = ud.string(forKey: Keys.gpsCoordFormat) ?? "DDM"
        mobActive              = ud.bool(forKey: Keys.mobActive)
        mobLat                 = ud.double(forKey: Keys.mobLat)
        mobLon                 = ud.double(forKey: Keys.mobLon)
        mobTime                = ud.double(forKey: Keys.mobTime)

        chartSatellite    = ud.bool(forKey: Keys.chartSatellite)
        chartOpenSeaMap   = ud.object(forKey: Keys.chartOpenSeaMap) as? Bool ?? true
        chartBathymetry   = ud.object(forKey: Keys.chartBathymetry) as? Bool ?? false
        chartShowAIS      = ud.object(forKey: Keys.chartShowAIS)    as? Bool ?? true
        chartShowTracks   = ud.object(forKey: Keys.chartShowTracks) as? Bool ?? true
        chartFollowVessel = ud.object(forKey: Keys.chartFollowVessel) as? Bool ?? true
        chartNorthUp      = ud.object(forKey: Keys.chartNorthUp)    as? Bool ?? true
        let tm = ud.integer(forKey: Keys.chartTrailMinutes); chartTrailMinutes = tm > 0 ? tm : 60
        aisStreamAPIKey   = ud.string(forKey: Keys.aisStreamAPIKey) ?? ""
        let ar = ud.double(forKey: Keys.aisRangeNm); aisRangeNm = ar > 0 ? ar : 20
        if let v = Self.loadBlob([ChartRegion].self, key: Keys.chartDownloadedRegions, ud: ud) {
            chartDownloadedRegions = v
        }
        if let v = Self.loadBlob([AISFriend].self, key: Keys.aisFriends, ud: ud) {
            aisFriends = v
        }
        chartShowPredictor   = ud.object(forKey: Keys.chartShowPredictor)   as? Bool ?? true
        let pm = ud.integer(forKey: Keys.chartPredictorMin)
        // Migrate old slider values (1–20 continuous) to the discrete choices.
        chartPredictorMin = Self.predictorTickChoices.contains(pm)
            ? pm
            : (Self.predictorTickChoices.min(by: { abs($0 - pm) < abs($1 - pm) }) ?? 10)
        chartShowLaylines    = ud.object(forKey: Keys.chartShowLaylines)    as? Bool ?? true
        let ta = ud.double(forKey: Keys.chartTackAngleDeg);  chartTackAngleDeg  = ta > 0 ? ta : 45
        chartShowWindRibbon  = ud.object(forKey: Keys.chartShowWindRibbon)  as? Bool ?? true
        chartShowSetDrift    = ud.object(forKey: Keys.chartShowSetDrift)    as? Bool ?? true
        aisCPAAlarmEnabled   = ud.object(forKey: Keys.aisCPAAlarmEnabled)   as? Bool ?? true
        let cpaN = ud.double(forKey: Keys.aisCPAThresholdNm);     aisCPAThresholdNm    = cpaN > 0 ? cpaN : 0.5
        let cpaM = ud.double(forKey: Keys.aisTCPAThresholdMin);   aisTCPAThresholdMin  = cpaM > 0 ? cpaM : 10
        aisGuardZoneEnabled  = ud.bool(forKey: Keys.aisGuardZoneEnabled)
        let gz = ud.double(forKey: Keys.aisGuardZoneRadiusNm);    aisGuardZoneRadiusNm = gz > 0 ? gz : 1.0
        if let r = Self.loadBlob(Route.self, key: Keys.activeRoute, ud: ud) {
            activeRoute = r
        }
        predictWindPiURL        = ud.string(forKey: Keys.predictWindPiURL) ?? ""
        chartShowPredictWindAIS = ud.object(forKey: Keys.chartShowPredictWindAIS) as? Bool ?? true
        chartMode               = ud.string(forKey: Keys.chartMode) ?? "sail"
        forecastAlarmEnabled    = ud.bool(forKey: Keys.forecastAlarmEnabled)
        let fwk = ud.double(forKey: Keys.forecastAlarmMaxWindKn); forecastAlarmMaxWindKn = fwk > 0 ? fwk : 20
        let fwm = ud.double(forKey: Keys.forecastAlarmMaxWaveM);  forecastAlarmMaxWaveM  = fwm > 0 ? fwm : 1.5
        let fha = ud.integer(forKey: Keys.forecastAlarmHoursAhead); forecastAlarmHoursAhead = fha > 0 ? fha : 24
    }

    /// Inner warning-ring radius in metres. Falls back to 75 % of the alarm
    /// radius when the user hasn't set one explicitly, clamped below the alarm.
    var effectiveWarnRadius: Double {
        let w = anchorWarnRadius > 0 ? anchorWarnRadius : anchorRadius * 0.75
        return min(w, max(anchorRadius - 2, 1))
    }

    /// True when the chart is in dedicated anchor mode (planning or watching).
    var isAnchorMode: Bool {
        get { chartMode == "anchor" }
        set { chartMode = newValue ? "anchor" : "sail" }
    }

    // MARK: Derived Pi endpoints
    //
    // The Pi runs the anchor daemon (:10112) and PredictWind server (:10115) on
    // the SAME host as SignalK. Rather than make the user configure separate Pi
    // URLs, default them to the SignalK host; an explicit override still wins.
    /// Anchor/alarm daemon base — explicit override, else derived from signalKHost.
    var effectiveAnchorPiURL: String {
        let v = anchorPiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.isEmpty else { return v }
        let h = signalKHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return h.isEmpty ? "" : "http://\(h):10112"
    }
    /// PredictWind server base — explicit override, else derived from signalKHost.
    var effectivePredictWindPiURL: String {
        let v = predictWindPiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.isEmpty else { return v }
        let h = signalKHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return h.isEmpty ? "" : "http://\(h):10115"
    }
    /// Anchor daemon over the tailnet — explicit override, else derived from
    /// the shared tailscaleHost so one setting powers every remote fallback.
    var effectiveAnchorPiTailscaleURL: String {
        let v = anchorPiTailscaleURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.isEmpty else { return v }
        let h = tailscaleHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return h.isEmpty ? "" : "http://\(h):10112"
    }

    func persist() {
        let ud = UserDefaults.standard
        ud.set(signalKHost,         forKey: Keys.host)
        ud.set(signalKPort,         forKey: Keys.port)
        ud.set(signalKUseTLS,       forKey: Keys.useTLS)
        ud.set(tailscaleHost,       forKey: Keys.tailscaleHost)
        ud.set(remoteDomain,        forKey: Keys.remoteDomain)
        ud.set(cfAccessClientId,    forKey: Keys.cfAccessClientId)
        ud.set(cornerTopLeft,       forKey: Keys.cornerTopLeft)
        ud.set(cornerTopRight,      forKey: Keys.cornerTopRight)
        ud.set(cornerBottomLeft,    forKey: Keys.cornerBotLeft)
        ud.set(cornerBottomRight,   forKey: Keys.cornerBotRight)
        ud.set(nightMode,           forKey: Keys.nightMode)
        ud.set(waypointActive,      forKey: Keys.waypointActive)
        ud.set(waypointLat,         forKey: Keys.waypointLat)
        ud.set(waypointLon,         forKey: Keys.waypointLon)
        ud.set(waypointName,        forKey: Keys.waypointName)
        ud.set(anchorActive,        forKey: Keys.anchorActive)
        ud.set(anchorLat,           forKey: Keys.anchorLat)
        ud.set(anchorLon,           forKey: Keys.anchorLon)
        ud.set(anchorRadius,        forKey: Keys.anchorRadius)
        ud.set(anchorWindMax,       forKey: Keys.anchorWindMax)
        ud.set(anchorWindShift,     forKey: Keys.anchorWindShift)
        ud.set(anchorInitialTWD,    forKey: Keys.anchorInitialTWD)
        ud.set(anchorDropTime,      forKey: Keys.anchorDropTime)
        ud.set(anchorDepthMin,      forKey: Keys.anchorDepthMin)
        ud.set(anchorDepthMax,      forKey: Keys.anchorDepthMax)
        ud.set(anchorBowOffset,     forKey: Keys.anchorBowOffset)
        ud.set(anchorRodeLength,    forKey: Keys.anchorRodeLength)
        ud.set(anchorWarnRadius,    forKey: Keys.anchorWarnRadius)
        ud.set(anchorAlarmDelay,    forKey: Keys.anchorAlarmDelay)
        ud.set(anchorGPSLossAlarm,    forKey: Keys.anchorGPSLossAlarm)
        ud.set(anchorLowBatteryAlarm, forKey: Keys.anchorLowBatteryAlarm)
        ud.set(anchorLowBatteryPct,   forKey: Keys.anchorLowBatteryPct)
        ud.set(anchorUseDeviceGPS,    forKey: Keys.anchorUseDeviceGPS)
        ud.set(anchorMooringType,     forKey: Keys.anchorMooringType)
        ud.set(anchorPiURL,             forKey: Keys.anchorPiURL)
        ud.set(anchorPiTailscaleURL,    forKey: Keys.anchorPiTailscaleURL)
        ud.set(anchorNtfyTopic,         forKey: Keys.anchorNtfyTopic)
        ud.set(anchorNtfyServer,        forKey: Keys.anchorNtfyServer)
        ud.set(gpsCoordFormat,          forKey: Keys.gpsCoordFormat)
        ud.set(mobActive,               forKey: Keys.mobActive)
        ud.set(mobLat,                  forKey: Keys.mobLat)
        ud.set(mobLon,                  forKey: Keys.mobLon)
        ud.set(mobTime,                 forKey: Keys.mobTime)

        ud.set(chartSatellite,    forKey: Keys.chartSatellite)
        ud.set(chartOpenSeaMap,   forKey: Keys.chartOpenSeaMap)
        ud.set(chartBathymetry,   forKey: Keys.chartBathymetry)
        ud.set(chartShowAIS,      forKey: Keys.chartShowAIS)
        ud.set(chartShowTracks,   forKey: Keys.chartShowTracks)
        ud.set(chartFollowVessel, forKey: Keys.chartFollowVessel)
        ud.set(chartNorthUp,      forKey: Keys.chartNorthUp)
        ud.set(chartTrailMinutes, forKey: Keys.chartTrailMinutes)
        ud.set(aisStreamAPIKey,   forKey: Keys.aisStreamAPIKey)
        ud.set(aisRangeNm,        forKey: Keys.aisRangeNm)
        ud.set(chartShowPredictor,   forKey: Keys.chartShowPredictor)
        ud.set(chartPredictorMin,    forKey: Keys.chartPredictorMin)
        ud.set(chartShowLaylines,    forKey: Keys.chartShowLaylines)
        ud.set(chartTackAngleDeg,    forKey: Keys.chartTackAngleDeg)
        ud.set(chartShowWindRibbon,  forKey: Keys.chartShowWindRibbon)
        ud.set(chartShowSetDrift,    forKey: Keys.chartShowSetDrift)
        ud.set(aisCPAAlarmEnabled,   forKey: Keys.aisCPAAlarmEnabled)
        ud.set(aisCPAThresholdNm,    forKey: Keys.aisCPAThresholdNm)
        ud.set(aisTCPAThresholdMin,  forKey: Keys.aisTCPAThresholdMin)
        ud.set(aisGuardZoneEnabled,  forKey: Keys.aisGuardZoneEnabled)
        ud.set(aisGuardZoneRadiusNm, forKey: Keys.aisGuardZoneRadiusNm)
        ud.set(predictWindPiURL,        forKey: Keys.predictWindPiURL)
        ud.set(chartShowPredictWindAIS, forKey: Keys.chartShowPredictWindAIS)
        ud.set(chartMode,               forKey: Keys.chartMode)
        ud.set(forecastAlarmEnabled,    forKey: Keys.forecastAlarmEnabled)
        ud.set(forecastAlarmMaxWindKn,  forKey: Keys.forecastAlarmMaxWindKn)
        ud.set(forecastAlarmMaxWaveM,   forKey: Keys.forecastAlarmMaxWaveM)
        ud.set(forecastAlarmHoursAhead, forKey: Keys.forecastAlarmHoursAhead)
        schedulePersistBlobs()
    }

    // MARK: - JSON-blob persistence (debounced, with backup copies)
    //
    // persist() fires from many view interactions, sometimes per drag tick.
    // Scalars stay synchronous above (cheap; anchor state must survive a
    // force-quit) — the five encoded arrays are coalesced here instead of
    // being re-encoded on every call. Each blob is written twice: a crash
    // mid-write must not silently erase saved anchorages/routes (the old
    // try?-into-defaults load path did exactly that).

    private var persistBlobsTask: Task<Void, Never>?

    private func schedulePersistBlobs() {
        persistBlobsTask?.cancel()
        persistBlobsTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.persistBlobsNow()
        }
    }

    private func persistBlobsNow() {
        let ud = UserDefaults.standard
        func write<T: Encodable>(_ value: T, _ key: String) {
            guard let d = try? JSONEncoder().encode(value) else { return }
            ud.set(d, forKey: key)
            ud.set(d, forKey: key + ".bak")
        }
        write(savedAnchorages,        Keys.savedAnchorages)
        write(instrumentConfigs,      Keys.instrumentConfigs)
        write(chartDownloadedRegions, Keys.chartDownloadedRegions)
        write(aisFriends,             Keys.aisFriends)
        if let r = activeRoute {
            write(r, Keys.activeRoute)
        } else {
            ud.removeObject(forKey: Keys.activeRoute)
            ud.removeObject(forKey: Keys.activeRoute + ".bak")
        }
    }

    /// Decode a JSON blob with backup fallback + loud logging on corruption.
    private static func loadBlob<T: Decodable>(_ type: T.Type, key: String, ud: UserDefaults) -> T? {
        if let d = ud.data(forKey: key), let v = try? JSONDecoder().decode(type, from: d) { return v }
        if let d = ud.data(forKey: key + ".bak"), let v = try? JSONDecoder().decode(type, from: d) {
            print("[Settings] \(key) unreadable — recovered from backup copy")
            return v
        }
        if ud.data(forKey: key) != nil {
            print("[Settings] \(key) corrupt with no usable backup — defaults in effect")
        }
        return nil
    }
}

// MARK: - AIS friend

struct AISFriend: Codable, Identifiable, Equatable {
    var id: Int { mmsi }      // unique per MMSI
    var mmsi: Int
    var name: String          // contact / vessel name shown on chart and detail
    var phone: String         // E.164 ideally (e.g. +35612345678); used for WhatsApp deep link
    var notes: String = ""

    /// Phone number stripped of spaces, dashes, parens — what wa.me expects.
    var phoneDigits: String {
        phone.filter { "+0123456789".contains($0) }
             .replacingOccurrences(of: "+", with: "")
    }

    /// Returns nil if no phone is set.
    var whatsappURL: URL? {
        let digits = phoneDigits
        guard !digits.isEmpty else { return nil }
        return URL(string: "https://wa.me/\(digits)")
    }
}

// MARK: - Saved anchorage

/// A favourite anchorage the user can re-drop at, with its proven swing zone
/// and conditions noted from last time. Builds a personal pilot book.
struct Anchorage: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var lat: Double
    var lon: Double
    var radius: Double          // metres — the swing/alarm radius that worked
    var rode:  Double = 0       // metres of rode deployed
    var depth: Double = 0       // metres at drop
    var notes: String = ""
    var savedAt: Double = 0     // unix
}

// MARK: - Chart region (cached map area)

struct ChartRegion: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var minLat: Double
    var minLon: Double
    var maxLat: Double
    var maxLon: Double
    var minZoom: Int
    var maxZoom: Int
    var tileCount: Int          // approximate
    var bytes: Int              // approximate
    var downloadedAt: Double    // unix
}
