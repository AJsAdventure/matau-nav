import Foundation

enum Instrument: String, CaseIterable, Identifiable, Equatable {

    // Navigation
    case gps        // GPS Position
    case sog        // Speed Over Ground
    case stw        // Speed Through Water
    case heading    // Magnetic Heading
    case depth      // Depth Below Transducer
    case rudder     // Rudder Angle

    // Wind
    case tws        // True Wind Speed
    case twa        // True Wind Angle
    case twd        // True Wind Direction
    case aws        // Apparent Wind Speed
    case awa        // Apparent Wind Angle
    case beaufort   // Beaufort Force

    // Environment
    case waterTemp  // Water Temperature

    // Waypoint
    case dtw        // Distance to Waypoint
    case ctw        // Course to Waypoint

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gps:      "GPS"
        case .sog:      "SOG"
        case .stw:      "STW"
        case .heading:  "HDG"
        case .depth:    "DEPTH"
        case .rudder:   "RUDDER"
        case .tws:      "TWS"
        case .twa:      "TWA"
        case .twd:      "TWD"
        case .aws:      "AWS"
        case .awa:      "AWA"
        case .beaufort: "BFT"
        case .waterTemp:"W.TEMP"
        case .dtw:      "DTW"
        case .ctw:      "CTW"
        }
    }

    var fullName: String {
        switch self {
        case .gps:      "GPS Position"
        case .sog:      "Speed Over Ground"
        case .stw:      "Speed Thru Water"
        case .heading:  "Magnetic Heading"
        case .depth:    "Depth"
        case .rudder:   "Rudder Angle"
        case .tws:      "True Wind Speed"
        case .twa:      "True Wind Angle"
        case .twd:      "True Wind Direction"
        case .aws:      "Apparent Wind Speed"
        case .awa:      "Apparent Wind Angle"
        case .beaufort: "Beaufort Force"
        case .waterTemp:"Water Temperature"
        case .dtw:      "Distance to Waypoint"
        case .ctw:      "Course to Waypoint"
        }
    }

    var unit: String {
        switch self {
        case .gps:                    ""
        case .sog, .stw, .tws, .aws: "kts"
        case .depth:                  "m"
        case .dtw:                    "nm"
        default:                      ""
        }
    }

    var group: String {
        switch self {
        case .gps, .sog, .stw, .heading, .depth, .rudder: "Navigation"
        case .tws, .twa, .twd, .aws, .awa, .beaufort: "Wind"
        case .waterTemp: "Environment"
        case .dtw, .ctw: "Waypoint"
        }
    }

    var icon: String {
        switch self {
        case .gps:          "location.fill"
        case .sog, .stw:    "speedometer"
        case .heading:      "safari"
        case .depth:        "arrow.down.to.line"
        case .rudder:       "arrow.left.and.right"
        case .tws, .aws:    "wind"
        case .twa, .awa:    "arrow.trianglehead.turn.up.right.circle"
        case .twd:          "location.north"
        case .beaufort:     "wind"
        case .waterTemp:    "thermometer.medium"
        case .dtw:          "flag.fill"
        case .ctw:          "arrow.triangle.turn.up.right.circle.fill"
        }
    }

    /// GPS occupies a full-width card and has its own detail sheet.
    var isFullWidth: Bool { self == .gps }

    /// Instruments available for the autopilot corner display (GPS position not useful there).
    var isCornerEligible: Bool { self != .gps }

    @MainActor func value(from s: SignalKService, settings: AppSettings? = nil) -> Double {
        switch self {
        case .gps:       return s.latitude   // proxy; card uses lat+lon directly
        case .sog:       return s.speedOverGround
        case .stw:       return s.boatSpeed
        case .heading:   return s.headingMagnetic
        case .depth:     return s.depth
        case .rudder:    return s.rudderAngle
        case .tws:       return s.trueWindSpeed
        case .twa:       return abs(s.trueWindAngle)
        case .twd:       return s.trueWindDirection
        case .aws:       return s.apparentWindSpeed
        case .awa:       return abs(s.apparentWindAngle)
        case .beaufort:  return beaufort(from: s.trueWindSpeed)
        case .waterTemp: return s.waterTemp
        case .dtw:
            guard let st = settings, st.waypointActive else { return 0 }
            return s.distanceTo(lat: st.waypointLat, lon: st.waypointLon)
        case .ctw:
            guard let st = settings, st.waypointActive else { return 0 }
            return s.bearing(toLat: st.waypointLat, lon2: st.waypointLon)
        }
    }

    /// Returns false when the sensor is connected but reporting a meaningless value.
    @MainActor func hasValidReading(from s: SignalKService, settings: AppSettings? = nil) -> Bool {
        switch self {
        case .depth: return s.depth > 0
        case .gps:   return s.latitude != 0 || s.longitude != 0
        default:     return true
        }
    }

    @MainActor func formattedValue(from s: SignalKService, settings: AppSettings? = nil) -> String {
        switch self {
        case .gps:
            guard s.latitude != 0 || s.longitude != 0 else { return "---" }
            return Instrument.formatDDM(lat: s.latitude, lon: s.longitude, compact: true)
        case .sog, .stw, .tws, .aws:
            return String(format: "%.1f", value(from: s))
        case .heading, .twd:
            return String(format: "%03.0f°", value(from: s))
        case .twa:
            let side = s.trueWindAngle >= 0 ? "S" : "P"
            return "\(String(format: "%.0f°", value(from: s)))\(side)"
        case .awa:
            let side = s.apparentWindAngle >= 0 ? "S" : "P"
            return "\(String(format: "%.0f°", value(from: s)))\(side)"
        case .depth:
            let v = value(from: s)
            return v <= 0 ? "---" : String(format: "%.1f", v)
        case .rudder:
            let v = s.rudderAngle
            let side = v > 0 ? "S" : (v < 0 ? "P" : "")
            return side.isEmpty ? "0°" : "\(String(format: "%.1f°", abs(v)))\(side)"
        case .beaufort:
            return String(format: "%.0f", value(from: s))
        case .waterTemp:
            return String(format: "%.1f°C", value(from: s))
        case .dtw:
            guard let st = settings, st.waypointActive else { return "---" }
            let d = s.distanceTo(lat: st.waypointLat, lon: st.waypointLon)
            return d < 10 ? String(format: "%.2f", d) : String(format: "%.1f", d)
        case .ctw:
            guard let st = settings, st.waypointActive else { return "---°" }
            return String(format: "%03.0f°", s.bearing(toLat: st.waypointLat, lon2: st.waypointLon))
        }
    }

    private func beaufort(from knots: Double) -> Double {
        switch knots {
        case ..<1:   0
        case ..<4:   1
        case ..<7:   2
        case ..<11:  3
        case ..<17:  4
        case ..<22:  5
        case ..<28:  6
        case ..<34:  7
        case ..<41:  8
        case ..<48:  9
        case ..<56:  10
        case ..<64:  11
        default:     12
        }
    }
}

// MARK: - GPS coordinate formatters
extension Instrument {

    /// Decimal Degrees  →  "35.72340° N  015.12340° E"
    static func formatDD(lat: Double, lon: Double) -> String {
        let latH = lat >= 0 ? "N" : "S"
        let lonH = lon >= 0 ? "E" : "W"
        return String(format: "%.5f° %@   %.5f° %@",
                      abs(lat), latH, abs(lon), lonH)
    }

    /// Degrees Decimal Minutes  →  "35° 43.404' N  015° 07.404' E"
    static func formatDDM(lat: Double, lon: Double, compact: Bool = false) -> String {
        func parts(_ deg: Double) -> (Int, Double) {
            let d = Int(abs(deg))
            let m = (abs(deg) - Double(d)) * 60
            return (d, m)
        }
        let latH = lat >= 0 ? "N" : "S"
        let lonH = lon >= 0 ? "E" : "W"
        let (ld, lm) = parts(lat)
        let (od, om) = parts(lon)
        if compact {
            return String(format: "%d° %06.3f' %@  %d° %06.3f' %@",
                          ld, lm, latH, od, om, lonH)
        }
        return String(format: "%02d° %06.3f' %@   %03d° %06.3f' %@",
                      ld, lm, latH, od, om, lonH)
    }

    /// Degrees Minutes Seconds  →  "35° 43' 24.2\" N  015° 07' 24.2\" E"
    static func formatDMS(lat: Double, lon: Double) -> String {
        func parts(_ deg: Double) -> (Int, Int, Double) {
            let d = Int(abs(deg))
            let mFrac = (abs(deg) - Double(d)) * 60
            let m = Int(mFrac)
            let s = (mFrac - Double(m)) * 60
            return (d, m, s)
        }
        let latH = lat >= 0 ? "N" : "S"
        let lonH = lon >= 0 ? "E" : "W"
        let (ld, lm, ls) = parts(lat)
        let (od, om, os) = parts(lon)
        return String(format: "%02d° %02d' %04.1f\" %@   %03d° %02d' %04.1f\" %@",
                      ld, lm, ls, latH, od, om, os, lonH)
    }
}

// Grouped for the picker
extension Instrument {
    static var grouped: [(String, [Instrument])] {
        let dict = Dictionary(grouping: allCases) { $0.group }
        let order = ["Navigation", "Wind", "Environment", "Waypoint"]
        return order.compactMap { key in
            guard let items = dict[key] else { return nil }
            return (key, items)
        }
    }
}
