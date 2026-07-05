import Foundation
import CoreLocation

// MARK: - Route models

struct RouteWaypoint: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var lat: Double
    var lon: Double
    /// Arrival circle in nm — leg advances when within this distance.
    var arrivalRadiusNm: Double = 0.05      // ~90 m
}

struct Route: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = "Route"
    var waypoints: [RouteWaypoint] = []
    /// Index of the currently-active leg's destination waypoint.
    /// `legIndex` of 0 = navigating to waypoints[0]. When the boat enters the
    /// arrival circle of waypoints[legIndex], `legIndex` is incremented.
    var legIndex: Int = 0

    var activeWaypoint: RouteWaypoint? {
        guard waypoints.indices.contains(legIndex) else { return nil }
        return waypoints[legIndex]
    }

    var isFinished: Bool { legIndex >= waypoints.count }
}

// MARK: - Geo / nav math

enum NavMath {

    // MARK: Distance / bearing helpers
    static let earthNm: Double = 3440.065

    static func distanceNm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude  * .pi / 180, φ2 = b.latitude  * .pi / 180
        let Δφ = (b.latitude  - a.latitude)  * .pi / 180
        let Δλ = (b.longitude - a.longitude) * .pi / 180
        let h  = sin(Δφ/2)*sin(Δφ/2) + cos(φ1)*cos(φ2)*sin(Δλ/2)*sin(Δλ/2)
        return earthNm * 2 * atan2(sqrt(h), sqrt(1 - h))
    }

    static func bearingDeg(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude  * .pi / 180, φ2 = b.latitude  * .pi / 180
        let Δλ = (b.longitude - a.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Returns the destination coordinate reached from `start` by sailing
    /// `bearingDeg` for `distanceNm` (great-circle).
    static func destination(from start: CLLocationCoordinate2D,
                            bearingDeg: Double,
                            distanceNm: Double) -> CLLocationCoordinate2D {
        let δ  = distanceNm / earthNm           // angular distance
        let θ  = bearingDeg * .pi / 180
        let φ1 = start.latitude  * .pi / 180
        let λ1 = start.longitude * .pi / 180
        let φ2 = asin(sin(φ1)*cos(δ) + cos(φ1)*sin(δ)*cos(θ))
        let λ2 = λ1 + atan2(sin(θ)*sin(δ)*cos(φ1),
                            cos(δ) - sin(φ1)*sin(φ2))
        return .init(latitude: φ2 * 180 / .pi,
                     longitude: λ2 * 180 / .pi)
    }

    /// Destination from origin by bearing and distance in metres.
    static func destination(from origin: CLLocationCoordinate2D,
                            bearingDeg: Double, distanceM: Double) -> CLLocationCoordinate2D {
        let R  = 6_371_000.0
        let d  = distanceM / R
        let br = bearingDeg * .pi / 180
        let φ1 = origin.latitude  * .pi / 180
        let λ1 = origin.longitude * .pi / 180
        let φ2 = asin(sin(φ1) * cos(d) + cos(φ1) * sin(d) * cos(br))
        let λ2 = λ1 + atan2(sin(br) * sin(d) * cos(φ1), cos(d) - sin(φ1) * sin(φ2))
        return CLLocationCoordinate2D(latitude: φ2 * 180 / .pi, longitude: λ2 * 180 / .pi)
    }

    // MARK: Predictor

    /// Where the vessel will be `minutes` ahead at current COG/SOG.
    static func predictor(from pos: CLLocationCoordinate2D,
                          cogDeg: Double, sogKn: Double,
                          minutes: Int) -> CLLocationCoordinate2D {
        let nm = sogKn * (Double(minutes) / 60.0)
        return destination(from: pos, bearingDeg: cogDeg, distanceNm: nm)
    }

    // MARK: Set & drift
    //
    // Set  = direction of current (degrees true)
    // Drift = speed of current (knots)
    // Computed as the vector difference between the GPS track (COG/SOG) and
    // the water track (heading/STW).

    static func setDrift(headingDeg: Double, stwKn: Double,
                         cogDeg: Double, sogKn: Double) -> (setDeg: Double, driftKn: Double) {
        let h = headingDeg * .pi / 180
        let c = cogDeg     * .pi / 180
        let hx = stwKn * sin(h), hy = stwKn * cos(h)
        let cx = sogKn * sin(c), cy = sogKn * cos(c)
        let dx = cx - hx, dy = cy - hy
        let drift = sqrt(dx*dx + dy*dy)
        var set   = atan2(dx, dy) * 180 / .pi
        if set < 0 { set += 360 }
        return (set, drift)
    }

    // MARK: Laylines
    //
    // Returns the two end-points of the layline pair drawn from `waypoint`,
    // back along the wind, at ±tackAngle either side of true-wind direction.
    // Each line is `length` long. The intent: when the vessel crosses one of
    // these lines, the next tack puts the waypoint on the bow.

    static func laylines(toward waypoint: CLLocationCoordinate2D,
                         windFromDeg twd: Double,
                         tackAngleDeg tack: Double,
                         lengthNm length: Double = 8)
    -> (port: CLLocationCoordinate2D, stbd: CLLocationCoordinate2D) {
        // From the waypoint, project upwind along TWD ± tack.
        let port = destination(from: waypoint,
                               bearingDeg: (twd - tack + 360).truncatingRemainder(dividingBy: 360),
                               distanceNm: length)
        let stbd = destination(from: waypoint,
                               bearingDeg: (twd + tack).truncatingRemainder(dividingBy: 360),
                               distanceNm: length)
        return (port, stbd)
    }

    // MARK: CPA / TCPA
    //
    // Given two vessels with current positions and motion vectors (cog/sog),
    // compute closest-point-of-approach distance (nm) and time to CPA (min).
    // Uses a flat-earth projection — accurate enough at AIS scales (<50 nm).

    struct CPAResult {
        var cpaNm: Double
        var tcpaMin: Double           // negative means CPA already passed
    }

    static func cpa(ourLat: Double, ourLon: Double, ourCogDeg: Double, ourSogKn: Double,
                    them: AISTarget) -> CPAResult {
        let nmPerDegLat = 60.0
        let nmPerDegLon = 60.0 * cos(ourLat * .pi / 180)

        // Position vector (them - us) in nm
        let rx = (them.longitude - ourLon) * nmPerDegLon
        let ry = (them.latitude  - ourLat) * nmPerDegLat

        // Velocity vectors in nm/hr (= knots)
        let ourRad  = ourCogDeg   * .pi / 180
        let theirRad = them.cog   * .pi / 180
        let ourVx   = ourSogKn * sin(ourRad),   ourVy   = ourSogKn * cos(ourRad)
        let theirVx = them.sog * sin(theirRad), theirVy = them.sog * cos(theirRad)

        // Relative velocity: target - us
        let vx = theirVx - ourVx
        let vy = theirVy - ourVy
        let vSq = vx*vx + vy*vy

        // Parallel courses or both stopped → CPA = current range, TCPA = 0
        guard vSq > 1e-6 else {
            let range = sqrt(rx*rx + ry*ry)
            return .init(cpaNm: range, tcpaMin: 0)
        }

        // Time of CPA in hours: -(r · v) / |v|^2
        let tHr = -(rx*vx + ry*vy) / vSq
        let cx = rx + vx * tHr
        let cy = ry + vy * tHr
        return .init(cpaNm: sqrt(cx*cx + cy*cy), tcpaMin: tHr * 60)
    }
}

// MARK: - GPX export

enum GPXExport {

    /// Build a GPX 1.1 document from a track.
    static func gpx(for track: Track) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]

        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += #"<gpx version="1.1" creator="MatauNav" xmlns="http://www.topografix.com/GPX/1/1">"#
        s += "\n  <trk><name>\(xml(track.name))</name><trkseg>\n"
        for p in track.points {
            let date = Date(timeIntervalSince1970: p.t)
            s += "    <trkpt lat=\"\(p.lat)\" lon=\"\(p.lon)\">"
            s += "<time>\(f.string(from: date))</time>"
            if let sog = p.sog {
                let ms = sog / 1.94384
                s += "<extensions><speed>\(ms)</speed>"
                if let cog = p.cog { s += "<course>\(cog)</course>" }
                s += "</extensions>"
            } else if let cog = p.cog {
                s += "<extensions><course>\(cog)</course></extensions>"
            }
            s += "</trkpt>\n"
        }
        s += "  </trkseg></trk>\n</gpx>\n"
        return s
    }

    /// Write GPX to a temporary file and return the URL for sharing.
    static func writeTemp(for track: Track) throws -> URL {
        let s = gpx(for: track)
        let name = track.name.replacingOccurrences(of: "/", with: "-") + ".gpx"
        let url  = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try s.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    private static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&",  with: "&amp;")
         .replacingOccurrences(of: "<",  with: "&lt;")
         .replacingOccurrences(of: ">",  with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'",  with: "&apos;")
    }
}
