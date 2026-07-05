import Foundation
import Observation

// MARK: - PredictWind AIS target (from PW tile API)

struct PWAISTarget: Identifiable, Equatable {
    var id: String { mmsi }
    let mmsi:    String
    let lat:     Double
    let lon:     Double
    let heading: Double
    let type:    String
    let status:  String
    let speed:   Double   // knots
    let source:  String   // "TER" or "SAT"

    var isUnderway: Bool {
        status == "Under Way Using Engine" || status == "Under Way Sailing"
    }

    var typeIcon: String {
        switch type {
        case let t where t.contains("Sail"):        return "sailboat"
        case let t where t.contains("Cargo"):       return "shippingbox"
        case let t where t.contains("Tanker"):      return "drop.fill"
        case let t where t.contains("Passenger"):   return "person.3"
        case let t where t.contains("Fishing"):     return "fish"
        case let t where t.contains("Tug"):         return "ferry.fill"
        default:                                     return "ferry"
        }
    }
}

// MARK: - PredictWind forecast entry

struct PWForecastHour: Identifiable {
    var id: Int { unixTimestamp }
    let unixTimestamp: Int
    let hour:  String
    let day:   String
}

struct PWForecastSeries: Identifiable {
    var id: String { "\(source)/\(title)" }
    let source:   String   // PWG, PWE, ECMWF, …
    let title:    String   // Speed, Direction, …
    let unitName: String
    let data:     [Int]
}

struct PWForecast {
    let hours:   [PWForecastHour]
    let series:  [PWForecastSeries]
}

// MARK: - Service

@Observable @MainActor
final class PredictWindService {

    enum Status: Equatable {
        case idle, authenticating, authenticated, failed(String)
        var label: String {
            switch self {
            case .idle:            return "Not configured"
            case .authenticating:  return "Authenticating…"
            case .authenticated:   return "Connected"
            case .failed(let m):   return m
            }
        }
        var isOK: Bool { if case .authenticated = self { true } else { false } }
    }

    private(set) var status:     Status = .idle
    private(set) var pwAIS:      [PWAISTarget] = []
    private(set) var lastAISFetch: Date?
    private(set) var forecast:   PWForecast?

    // MARK: - Internal

    private var piURL: String = ""
    private var pollTask: Task<Void, Never>?

    // MARK: - Public interface

    func configure(piURL: String) {
        self.piURL = piURL
    }

    func start(settings: AppSettings) {
        pollTask?.cancel()
        pollTask = Task { await self.runLoop(settings: settings) }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Push credentials to the Pi; Pi will authenticate and persist them.
    func setCredentials(email: String, password: String, piURL: String) async -> Bool {
        guard !piURL.isEmpty else {
            status = .failed("Pi URL not configured")
            return false
        }
        self.piURL = piURL
        status = .authenticating
        guard let url = URL(string: "\(piURL)/credentials") else {
            status = .failed("Invalid Pi URL")
            return false
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["email": email, "password": password]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["ok"] as? Bool == true else {
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "Auth failed"
                status = .failed(msg)
                return false
            }
            status = .authenticated
            return true
        } catch {
            status = .failed(error.localizedDescription)
            return false
        }
    }

    /// Check Pi auth status (without re-authenticating).
    func refreshStatus() async {
        guard !piURL.isEmpty else { return }
        guard let url = URL(string: "\(piURL)/health") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8))
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let authed = json["authenticated"] as? Bool ?? false
                status = authed ? .authenticated : .idle
            }
        } catch {
            // Silently ignore connectivity errors during status check
        }
    }

    /// Fetch AIS targets for a bounding box from the Pi.
    func fetchAIS(south: Double, west: Double, north: Double, east: Double) async {
        guard !piURL.isEmpty, status.isOK else { return }
        var comps = URLComponents(string: "\(piURL)/ais")!
        comps.queryItems = [
            URLQueryItem(name: "south", value: String(format: "%.4f", south)),
            URLQueryItem(name: "west",  value: String(format: "%.4f", west)),
            URLQueryItem(name: "north", value: String(format: "%.4f", north)),
            URLQueryItem(name: "east",  value: String(format: "%.4f", east)),
            URLQueryItem(name: "zoom",  value: "8"),
            URLQueryItem(name: "age",   value: "60"),
        ]
        guard let url = comps.url else { return }
        do {
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10))
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let vessels = json["vessels"] as? [[String: Any]] else { return }
            let targets = vessels.compactMap { v -> PWAISTarget? in
                guard let mmsi   = v["mmsi"] as? String,
                      let lat    = v["lat"]  as? Double,
                      let lon    = v["lon"]  as? Double else { return nil }
                return PWAISTarget(
                    mmsi:    mmsi,
                    lat:     lat,
                    lon:     lon,
                    heading: v["heading"] as? Double ?? 0,
                    type:    v["type"]    as? String ?? "Vessel",
                    status:  v["status"]  as? String ?? "",
                    speed:   v["speed"]   as? Double ?? 0,
                    source:  v["source"]  as? String ?? ""
                )
            }
            pwAIS = targets
            lastAISFetch = Date()
        } catch {
            // Keep the last targets through a brief blip, but do NOT leave
            // ghost ships on the chart: after ~3 missed 5-min poll cycles the
            // overlay is cleared so old AIS positions can't read as current.
            if let t = lastAISFetch, Date().timeIntervalSince(t) > 900 {
                pwAIS = []
            }
        }
    }

    /// True when AIS data is older than ~2.5 poll cycles — surfaced by the
    /// chart so a quiet overlay is distinguishable from a dead one.
    var aisIsStale: Bool {
        guard let t = lastAISFetch else { return false }
        return Date().timeIntervalSince(t) > 750
    }

    /// Fetch 7-day forecast for a PredictWind location ID.
    func fetchForecast(locationId: Int) async -> PWForecast? {
        guard !piURL.isEmpty, status.isOK else { return nil }
        guard let url = URL(string: "\(piURL)/forecast/\(locationId)") else { return nil }
        do {
            // Forecast payloads are big and the Pi may be on a slow link, but
            // 60 s (the URLSession default) would freeze the Safe-Tonight
            // verdict for a full minute when the Pi is gone. 15 s is plenty.
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d    = json["data"] as? [String: Any],
                  let ft   = d["ForecastTable"] as? [String: Any] else { return nil }
            let rawHours = ft["hours"] as? [[String: Any]] ?? []
            let hours = rawHours.compactMap { h -> PWForecastHour? in
                guard let ts   = h["unixTimestamp"] as? Int,
                      let hour = h["hour"] as? String,
                      let day  = h["day"]  as? String else { return nil }
                return PWForecastHour(unixTimestamp: ts, hour: hour, day: day)
            }
            let rawTypes = ft["forecastTypes"] as? [[String: Any]] ?? []
            let series = rawTypes.compactMap { t -> PWForecastSeries? in
                guard let src   = t["sourceName"] as? String,
                      let title = t["title"]      as? String,
                      let unit  = t["unitName"]   as? String,
                      let data  = t["data"]       as? [Int] else { return nil }
                return PWForecastSeries(source: src, title: title, unitName: unit, data: data)
            }
            let f = PWForecast(hours: hours, series: series)
            self.forecast = f
            return f
        } catch {
            return nil
        }
    }

    func setForecastLocation(lat: Double, lon: Double) async -> Int? {
        guard !piURL.isEmpty, let url = URL(string: "\(piURL)/location/set") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "name": "Pi Location", "lat": lat, "lon": lon
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true,
              let id = json["id"] as? Int else { return nil }
        return id
    }

    func setForecastAlarm(enabled: Bool, locationId: Int, settings: AppSettings) async {
        guard !piURL.isEmpty, let url = URL(string: "\(piURL)/forecast-alarm") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "enabled":     enabled,
            "location_id": locationId,
            "max_wind_kn": settings.forecastAlarmMaxWindKn,
            "max_wave_m":  settings.forecastAlarmMaxWaveM,
            "hours_ahead": settings.forecastAlarmHoursAhead,
            "ntfy_server": settings.anchorNtfyServer,
            "ntfy_topic":  settings.anchorNtfyTopic,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Poll loop

    private func runLoop(settings: AppSettings) async {
        while !Task.isCancelled {
            let url = buildPiURL(settings: settings)
            if url != piURL { piURL = url }

            if !piURL.isEmpty {
                await refreshStatus()
            }

            try? await Task.sleep(for: .seconds(60))
        }
    }

    private func buildPiURL(settings: AppSettings) -> String {
        // Explicit override, else derived from the SignalK host (:10115).
        settings.effectivePredictWindPiURL
    }
}
