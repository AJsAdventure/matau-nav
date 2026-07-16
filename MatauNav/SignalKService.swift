import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class SignalKService {

    var host:   String = "matau.local"
    var port:   Int    = 3000
    var useTLS: Bool   = false          // ws:// vs wss://

    // MARK: Remote fallbacks
    //
    // Three ways to reach the boat, probed in order before every (re)connect:
    //   .local     — http://host:port on the boat Wi-Fi (always preferred)
    //   .tailscale — same ports on the tailnet IP (needs the Tailscale app,
    //                fights NordVPN — kept for setups that use it)
    //   .remote    — public https://matau-<port>.<remoteDomain> via the Pi's
    //                Cloudflare Tunnel, gated by an Access service token.
    //                Plain HTTPS: works from any network, no VPN app.
    // While on a fallback, the better paths are re-probed every 5 minutes.

    enum BoatPath { case local, tailscale, remote }

    /// Tailscale address of the same server (IP or MagicDNS name). Empty = tier disabled.
    var tailscaleHost: String = ""
    /// Domain the Cloudflare Tunnel publishes under (e.g. "gleser.ai"). Empty = tier disabled.
    var remoteDomain: String = ""
    /// Cloudflare Access service-token credentials for the remote tier.
    var cfAccessClientId: String = ""
    var cfAccessClientSecret: String = ""

    private(set) var activePath: BoatPath = .local
    var onTailscale: Bool { activePath == .tailscale }
    var onRemote:    Bool { activePath == .remote }
    private var lastBetterPathRecheckAt: Date = .distantPast

    private var trimmedTailscale: String {
        tailscaleHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedRemoteDomain: String {
        remoteDomain.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Host shown in the UI for the active path.
    var activeHost: String {
        switch activePath {
        case .local:     return host
        case .tailscale: return trimmedTailscale.isEmpty ? host : trimmedTailscale
        case .remote:    return remoteHost(port: port) ?? host
        }
    }

    private func remoteHost(port p: Int) -> String? {
        let d = trimmedRemoteDomain
        guard !d.isEmpty else { return nil }
        return "\(AppSettings.remoteHostPrefix)\(p).\(d)"
    }

    /// Base URL for any Pi service (they share the boat host across ports).
    /// Every sibling service derives its endpoint from this so the whole app
    /// follows one failover decision.
    func piBase(port p: Int) -> String {
        switch activePath {
        case .local:
            return "http://\(host):\(p)"
        case .tailscale:
            let ts = trimmedTailscale
            return "http://\(ts.isEmpty ? host : ts):\(p)"
        case .remote:
            if let h = remoteHost(port: p) { return "https://\(h)" }
            return "http://\(host):\(p)"
        }
    }

    /// Cloudflare Access headers, required iff `base` targets the remote
    /// bridge. Keyed off the URL (not the current path) so a request built
    /// just before a path flip still carries the right headers — and the
    /// secret never travels over cleartext LAN/tailnet requests.
    func piHeaders(for base: String) -> [String: String] {
        let d = trimmedRemoteDomain
        guard !d.isEmpty, base.contains(d),
              !cfAccessClientId.isEmpty, !cfAccessClientSecret.isEmpty else { return [:] }
        return ["CF-Access-Client-Id":     cfAccessClientId,
                "CF-Access-Client-Secret": cfAccessClientSecret]
    }

    private func applyPiHeaders(_ req: inout URLRequest) {
        guard let base = req.url?.absoluteString else { return }
        for (k, v) in piHeaders(for: base) { req.setValue(v, forHTTPHeaderField: k) }
    }

    var state:      ConnectionState = .disconnected
    var serverInfo: ServerInfo?

    // Navigation data — display units: degrees, knots, metres, celsius

    var headingMagnetic:   Double = 0   // degrees 0–360
    var trueWindAngle:     Double = 0   // degrees, signed: +starboard / −port
    var trueWindSpeed:     Double = 0   // knots
    var apparentWindAngle: Double = 0   // degrees, signed
    var apparentWindSpeed: Double = 0   // knots
    var boatSpeed:         Double = 0   // knots (speed through water)
    var speedOverGround:   Double = 0   // knots
    var depth:             Double = 0   // metres
    var waterTemp:         Double = 0   // celsius
    var rudderAngle:       Double = 0   // degrees

    var trueWindDirection: Double {
        (headingMagnetic + trueWindAngle + 360).truncatingRemainder(dividingBy: 360)
    }

    var latitude:         Double = 0
    var longitude:        Double = 0
    var courseOverGround: Double = 0    // degrees true
    var cogHistory: [Double] = []       // rolling 30-second COG trail (60 × 500 ms)

    struct WindSample: Equatable { let t: Date; let twd: Double; let tws: Double }
    var windHistory: [WindSample] = []
    private var lastWindRecordAt: Date = .distantPast

    // GPS outlier rejection — 0.003° ≈ 330 m. A single fix that jumps more than
    // this from the last accepted position is treated as a spike and held back,
    // but a genuine large move (reconnect, GPS regained after an outage, a fast
    // run between sparse fixes) must NOT freeze the marker forever — see
    // applyPosition for the confirm-on-repeat + staleness backstop.
    private static let maxPositionJumpDeg = 0.003
    /// After this long with no accepted fix, the next fix is force-accepted so a
    /// stale rejected jump can't leave the vessel frozen on the chart.
    private static let positionStaleSec: TimeInterval = 15
    private var positionInitialised = false
    /// Last fix we accepted (drives the staleness backstop).
    private var lastAcceptedAt: Date = .distantPast
    /// A held-back jump candidate: if the next fix lands near it, the move is
    /// real (two readings agree) and we accept rather than keep rejecting.
    private var jumpCandidate: (lat: Double, lon: Double)?
    /// Timestamp of the last position update from any source (WS or REST fallback).
    private var lastPositionAt: Date = .distantPast
    private var positionFallbackTask: Task<Void, Never>?

    // Autopilot
    var autopilotEngaged: Bool   = false
    var targetHeading:    Double = 0

    private(set) var lastSuccessfulUpdate: Date? = nil

    var dataAgeString: String? {
        guard let t = lastSuccessfulUpdate else { return nil }
        let age = Int(Date().timeIntervalSince(t))
        return age > 5 ? "\(age)s ago" : nil
    }

    // MARK: - WebSocket state

    private var wsTask:         URLSessionWebSocketTask?
    private var wsSession:      URLSession?
    private var pingTask:       Task<Void, Never>?
    private var reconnectTask:  Task<Void, Never>?
    private var reconnectDelay: Double = 1.0   // seconds; doubles on each failure, cap 30s
    private var subscribed      = false
    private var disconnecting   = false         // set true on manual disconnect to stop auto-reconnect
    private var authToken:      String?         // in-memory only; never persisted
    /// When any WebSocket frame last arrived. Half-open sockets (network died
    /// without a TCP reset: Wi-Fi drop, Mac sleep/wake) leave receive() hanging
    /// forever with no error — freshness has to be tracked explicitly.
    private var lastWSMessageAt: Date = .distantPast
    /// Set when a ping is sent, cleared when its callback fires. A ping whose
    /// callback never fires at all is the half-open-socket signature.
    private var pendingPingSince: Date?
    /// Consecutive REST-fallback failures while the WS claims to be connected.
    private var restUnreachableCount = 0

    /// Dedicated session for the REST calls in this service. Deliberately does
    /// NOT use waitsForConnectivity: these calls double as liveness probes for
    /// the boat network, so failing fast is the feature — waiting would show a
    /// stale-but-green chart while the Pi is unreachable.
    private static let restSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 8
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity       = false
        return URLSession(configuration: config)
    }()

    // MARK: - ConnectionState

    enum ConnectionState: Equatable {
        case disconnected, connecting, connected, failed(String)

        var label: String {
            switch self {
            case .disconnected:    return "Not Connected"
            case .connecting:      return "Connecting…"
            case .connected:       return "Connected"
            case .failed(let msg): return msg
            }
        }
        var color: Color {
            switch self {
            case .disconnected: return .textTertiary
            case .connecting:   return .statusOrange
            case .connected:    return .statusGreen
            case .failed:       return .statusRed
            }
        }
        var isConnected:  Bool { if case .connected  = self { true } else { false } }
        var isConnecting: Bool { if case .connecting = self { true } else { false } }
    }

    struct ServerInfo: Sendable {
        let version: String
        let vesselName: String
    }

    // HTTP base URL (used for vessel name fetch + autopilot PUTs)
    var baseURL: String {
        switch activePath {
        case .remote:
            if let h = remoteHost(port: port) { return "https://\(h)" }
            fallthrough
        default:
            return "http\(useTLS ? "s" : "")://\(activeHost):\(port)"
        }
    }

    /// True while the boat position feed is genuinely live — connected AND a fix
    /// arrived (over the WebSocket or REST fallback) within the last few seconds.
    /// When this goes false the chart falls back to this device's own GPS so the
    /// vessel marker keeps moving even if the Pi / boat network is unreachable
    /// (e.g. the chartplotter — and the network it hosts — was switched off).
    /// Re-evaluated on every render; device-GPS fixes keep the chart re-rendering
    /// so the switch happens within a second of the boat feed dropping.
    var boatPositionIsLive: Bool {
        positionInitialised && state.isConnected
            && Date().timeIntervalSince(lastPositionAt) < 8
    }

    // MARK: - Public API

    func connect() async {
        // Always tear down any existing connection before opening a new one
        if state.isConnected || state.isConnecting {
            closeWebSocket()
        }
        disconnecting  = false
        reconnectDelay = 1.0
        state          = .connecting
        await openWebSocket()
        startPositionFallback()
    }

    func disconnect() {
        disconnecting = true
        positionFallbackTask?.cancel()
        positionFallbackTask = nil
        closeWebSocket()
        state        = .disconnected
        serverInfo   = nil
        authToken    = nil
        lastSuccessfulUpdate = nil
    }

    // MARK: - REST position fallback
    //
    // If the SignalK WebSocket doesn't push navigation.position updates
    // (e.g. stationary boat, GPS on a separate NMEA bus, or SignalK plugin
    // stores the value without streaming deltas), poll the REST API every 5 s.
    // This is a fallback — WebSocket updates take priority and reset the timer.

    private enum RESTPositionResult {
        case ok           // fresh position applied
        case noPosition   // server answered but has no (valid) position — not a network problem
        case unreachable  // request failed: the network path to the Pi is broken
    }

    private func startPositionFallback() {
        positionFallbackTask?.cancel()
        positionFallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { break }
                // While on a fallback path, re-probe the better tiers every
                // 5 min and move up the moment one answers — local is faster
                // and works with the boat's internet down. connect()
                // replaces this task; bail out after switching.
                if self.activePath != .local,
                   Date().timeIntervalSince(self.lastBetterPathRecheckAt) > 300 {
                    self.lastBetterPathRecheckAt = Date()
                    var better: [BoatPath] = [.local]
                    if self.activePath == .remote,
                       self.configuredPaths.contains(.tailscale) { better.append(.tailscale) }
                    var switched = false
                    for path in better {
                        if await self.probe(path) { self.activePath = path; switched = true; break }
                    }
                    if switched {
                        await self.connect()   // replaces this task
                        break
                    }
                }
                // Only poll if we haven't had a WebSocket position update in 10 s
                guard Date().timeIntervalSince(self.lastPositionAt) > 10 else {
                    self.restUnreachableCount = 0
                    continue
                }
                switch await self.fetchPositionFromREST() {
                case .ok, .noPosition:
                    self.restUnreachableCount = 0
                case .unreachable:
                    self.restUnreachableCount += 1
                    // Two consecutive REST failures while the WS still claims
                    // to be connected: the socket is a zombie (see
                    // lastWSMessageAt). Reconnect — and flip the UI out of a
                    // false green "Connected" — instead of showing stale data.
                    if self.restUnreachableCount >= 2, self.state.isConnected {
                        self.restUnreachableCount = 0
                        await self.scheduleReconnect(reason: "Server unreachable")
                    }
                }
            }
        }
    }

    private static let isoTimestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoTimestampNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    @discardableResult
    private func fetchPositionFromREST() async -> RESTPositionResult {
        // Full object (value + timestamp), NOT /value: the server serves the
        // last known position no matter how old. Stamping a stale fix as
        // live blinds boatPositionIsLive — and with it the drag and GPS-loss
        // alarms — exactly when the GPS dies. Observed live 2026-07-12: the
        // USB GPS hung and this fallback kept "confirming" an 8-min-old fix
        // while the boat lay at anchor.
        guard let url = URL(string:
            "\(baseURL)/signalk/v1/api/vessels/self/navigation/position") else { return .noPosition }
        do {
            var req = URLRequest(url: url, timeoutInterval: 4)
            if let token = authToken {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            applyPiHeaders(&req)
            let (data, _) = try await Self.restSession.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = obj["value"] as? [String: Any],
                  let lat = value["latitude"]  as? Double,
                  let lon = value["longitude"] as? Double,
                  (-90...90).contains(lat), (-180...180).contains(lon),
                  lat != 0 || lon != 0 else { return .noPosition }
            if let ts = obj["timestamp"] as? String,
               let stamped = Self.isoTimestamp.date(from: ts)
                          ?? Self.isoTimestampNoFrac.date(from: ts) {
                // Older than 60 s = a frozen feed, not a fix. Missing or
                // unparseable timestamps are accepted (old behaviour) — a
                // format quirk must not take the whole fallback down.
                guard Date().timeIntervalSince(stamped) < 60 else { return .noPosition }
            }
            applyPosition(lat: lat, lon: lon)
            return .ok
        } catch {
            return .unreachable
        }
    }

    // MARK: - WebSocket lifecycle

    private func openWebSocket() async {
        // Pick the host that actually answers (local vs Tailscale) BEFORE
        // spending a WebSocket timeout on a dead address. On the boat the
        // local probe answers in milliseconds; away from it, this is what
        // routes the whole app over the tailnet.
        await chooseHost()

        // Authenticate first if credentials are stored in Keychain
        if let (user, pass) = SignalKKeychain.loadCredentials() {
            authToken = await fetchToken(username: user, password: pass)
        }

        var urlString: String
        switch activePath {
        case .remote where remoteHost(port: port) != nil:
            urlString = "wss://\(remoteHost(port: port)!)/signalk/v1/stream?subscribe=none"
        default:
            urlString = "\(useTLS ? "wss" : "ws")://\(activeHost):\(port)/signalk/v1/stream?subscribe=none"
        }
        if let token = authToken,
           let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            urlString += "&token=\(encoded)"
        }

        guard let url = URL(string: urlString) else {
            state = .failed("Invalid server address"); return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 10
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config)
        wsSession = session

        // Access headers ride on the upgrade request when on the remote path.
        var wsReq = URLRequest(url: url)
        applyPiHeaders(&wsReq)
        let task = session.webSocketTask(with: wsReq)
        wsTask    = task
        subscribed = false
        task.resume()

        startReceiving(task: task)
        startPing(task: task)
    }

    /// Candidate paths in preference order (local first, remote last).
    private var configuredPaths: [BoatPath] {
        var out: [BoatPath] = [.local]
        let ts = trimmedTailscale
        if !ts.isEmpty, ts != host { out.append(.tailscale) }
        if remoteHost(port: port) != nil { out.append(.remote) }
        return out
    }

    /// Pick the path that actually answers before spending a WebSocket
    /// timeout on a dead address. The last-good path is probed first so
    /// reconnects while away from the boat stay fast; otherwise preference
    /// order (local → tailscale → remote). When nothing answers the previous
    /// choice stands — the reconnect backoff will land here again anyway.
    private func chooseHost() async {
        var order = configuredPaths
        guard order.count > 1 else { activePath = .local; return }
        if activePath != .local, let i = order.firstIndex(of: activePath) {
            order.remove(at: i)
            order.insert(activePath, at: 0)
        }
        for path in order {
            if await probe(path) {
                if path != .local, activePath == .local { lastBetterPathRecheckAt = Date() }
                activePath = path
                return
            }
        }
    }

    /// GET /signalk (the discovery document) with a short timeout — cheap
    /// liveness check for one candidate path. The remote tier needs the
    /// Access headers or Cloudflare answers 403 for everyone.
    private func probe(_ path: BoatPath) async -> Bool {
        let base: String
        switch path {
        case .local:     base = "http\(useTLS ? "s" : "")://\(host):\(port)"
        case .tailscale: base = "http\(useTLS ? "s" : "")://\(trimmedTailscale):\(port)"
        case .remote:
            guard let h = remoteHost(port: port) else { return false }
            base = "https://\(h)"
        }
        guard let url = URL(string: base + "/signalk") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        applyPiHeaders(&req)
        guard let (_, resp) = try? await Self.restSession.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private func closeWebSocket() {
        pingTask?.cancel();      pingTask      = nil
        reconnectTask?.cancel(); reconnectTask = nil
        wsTask?.cancel(with: .goingAway, reason: nil); wsTask = nil
        wsSession?.invalidateAndCancel(); wsSession = nil
        subscribed = false
    }

    // MARK: - Receive loop

    private func startReceiving(task: URLSessionWebSocketTask) {
        Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let msg = try await task.receive()
                    await self?.handle(message: msg)
                }
            } catch {
                await self?.scheduleReconnect(reason: error.localizedDescription)
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) async {
        let data: Data
        switch message {
        case .data(let d):   data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default:    return
        }

        lastWSMessageAt = Date()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // SignalK sends a hello/welcome frame first (has "name" or "version" key).
        // We send the subscribe message only once we've seen it.
        if !subscribed, json["name"] != nil || json["version"] != nil {
            subscribed     = true
            state          = .connected
            reconnectDelay = 1.0

            let version = json["version"] as? String ?? "unknown"
            let name    = await fetchVesselName()
            serverInfo  = ServerInfo(version: version, vesselName: name)

            await sendSubscribe()
            return
        }

        applyDelta(json)
    }

    // MARK: - Subscription

    private func sendSubscribe() async {
        // (path, minPeriodMs) — faster for helm-critical data, slower for ambient sensors
        let paths: [(String, Int)] = [
            ("navigation.headingMagnetic",                200),
            ("environment.wind.angleTrueWater",           200),
            ("environment.wind.speedTrue",                200),
            ("environment.wind.angleApparent",            200),
            ("environment.wind.speedApparent",            200),
            ("navigation.speedThroughWater",              500),
            ("navigation.speedOverGround",                500),
            ("navigation.courseOverGroundTrue",           500),
            ("navigation.position",                       500),
            ("steering.rudderAngle",                      200),
            ("steering.autopilot.state",                 1000),
            ("steering.autopilot.target.headingMagnetic", 500),
            ("environment.depth.belowTransducer",        1000),
            ("environment.water.temperature",            5000),
        ]

        let body: [String: Any] = [
            "context": "vessels.self",
            "subscribe": paths.map { (path, period) in
                ["path": path, "period": period, "policy": "ideal"] as [String: Any]
            },
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let str  = String(data: data, encoding: .utf8) else { return }
        try? await wsTask?.send(.string(str))
    }

    // MARK: - Delta parsing

    private func applyDelta(_ json: [String: Any]) {
        guard let updates = json["updates"] as? [[String: Any]] else { return }
        var gotData = false
        for update in updates {
            guard let values = update["values"] as? [[String: Any]] else { continue }
            for entry in values {
                guard let path = entry["path"] as? String else { continue }
                applyValue(path: path, rawValue: entry["value"])
                gotData = true
            }
        }
        guard gotData else { return }
        let now = Date()
        if trueWindSpeed > 0, now.timeIntervalSince(lastWindRecordAt) >= 15 {
            windHistory.append(.init(t: now, twd: trueWindDirection, tws: trueWindSpeed))
            let cutoff = now.addingTimeInterval(-1800)   // 30 min
            windHistory.removeAll { $0.t < cutoff }
            lastWindRecordAt = now
        }
        lastSuccessfulUpdate = now
    }

    // All values are range-clamped before being applied.  A malformed or
    // injected message can corrupt display values but cannot crash the app
    // or push out-of-range numbers into downstream alarm logic.
    private func applyValue(path: String, rawValue: Any?) {
        switch path {

        case "navigation.headingMagnetic":
            // Radians 0–2π
            if let v = clamp(rawValue, lo: 0, hi: .pi * 2)         { headingMagnetic = toDeg(v) }

        case "environment.wind.angleTrueWater":
            if let v = asDouble(rawValue) {
                var a = toDeg(v); if a > 180 { a -= 360 }; if a < -180 { a += 360 }
                if abs(a) <= 185                                     { trueWindAngle = a }
            }

        case "environment.wind.speedTrue":
            // m/s; 50 m/s ≈ 97 kts covers any realistic condition
            if let v = clamp(rawValue, lo: 0, hi: 50)              { trueWindSpeed = v * 1.94384 }

        case "environment.wind.angleApparent":
            if let v = asDouble(rawValue) {
                var a = toDeg(v); if a > 180 { a -= 360 }; if a < -180 { a += 360 }
                if abs(a) <= 185                                     { apparentWindAngle = a }
            }

        case "environment.wind.speedApparent":
            if let v = clamp(rawValue, lo: 0, hi: 50)              { apparentWindSpeed = v * 1.94384 }

        case "navigation.speedThroughWater":
            if let v = clamp(rawValue, lo: 0, hi: 30)              { boatSpeed = v * 1.94384 }

        case "navigation.speedOverGround":
            if let v = clamp(rawValue, lo: 0, hi: 30)              { speedOverGround = v * 1.94384 }

        case "environment.depth.belowTransducer":
            if let v = clamp(rawValue, lo: 0, hi: 5000)            { depth = v }

        case "environment.water.temperature":
            // Kelvin; 250 K = −23°C, 320 K = 47°C
            if let v = clamp(rawValue, lo: 250, hi: 320)           { waterTemp = v - 273.15 }

        case "steering.rudderAngle":
            // Radians; ±π/2 covers any physical rudder
            if let v = clamp(rawValue, lo: -.pi / 2, hi: .pi / 2) { rudderAngle = toDeg(v) }

        case "navigation.courseOverGroundTrue":
            if let v = clamp(rawValue, lo: 0, hi: .pi * 2) {
                courseOverGround = toDeg(v)
                cogHistory.append(courseOverGround)
                if cogHistory.count > 60 { cogHistory.removeFirst() }
            }

        case "navigation.position":
            if let obj = rawValue as? [String: Any],
               let lat = obj["latitude"]  as? Double,
               let lon = obj["longitude"] as? Double,
               (-90...90).contains(lat), (-180...180).contains(lon) {
                applyPosition(lat: lat, lon: lon)
            }

        case "steering.autopilot.state":
            if let s = rawValue as? String {
                // "auto", "wind" (vane) and "route"/"track" are all ENGAGED
                // states. The old == "auto" check reported STANDBY while the
                // pilot steered in vane mode — and because this delta arrives
                // every second, it kept overwriting the correct Pi-mirrored
                // value, so the app looked wrong from launch.
                let v = s.lowercased()
                autopilotEngaged = !(v == "standby" || v == "off" || v.isEmpty)
            }

        case "steering.autopilot.target.headingMagnetic":
            if let v = clamp(rawValue, lo: 0, hi: .pi * 2)         { targetHeading = toDeg(v) }

        default: break
        }
    }

    // MARK: - Heartbeat ping

    private func startPing(task: URLSessionWebSocketTask) {
        pingTask?.cancel()
        pendingPingSince = nil
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.wsTask === task, !Task.isCancelled else { break }
                // The previous ping's callback never fired at all: half-open
                // socket. sendPing only reports *explicit* errors — a network
                // that vanished without a TCP reset (Wi-Fi drop, sleep/wake)
                // produces silence, and receive() hangs on it forever.
                if let since = self.pendingPingSince,
                   Date().timeIntervalSince(since) > 25 {
                    await self.scheduleReconnect(reason: "Connection lost (no ping response)")
                    break
                }
                self.pendingPingSince = Date()
                task.sendPing { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, self.wsTask === task else { return }
                        self.pendingPingSince = nil
                        if error != nil {
                            await self.scheduleReconnect(reason: "Ping timeout")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Reconnect with exponential backoff

    private func scheduleReconnect(reason: String) async {
        guard !disconnecting else { return }
        closeWebSocket()
        state = .failed(reason)

        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !(self?.disconnecting ?? true) else { return }
            self?.state = .connecting
            await self?.openWebSocket()
        }
    }

    /// Retry the connection immediately, bypassing the current backoff delay,
    /// unless the feed is already demonstrably live. Called on wake-from-sleep
    /// and app foregrounding: the old socket is dead then, and sitting out a
    /// 30 s backoff (or waiting for the ping watchdog to notice) makes the
    /// chart look frozen right when the user is looking at it.
    func nudgeReconnect() {
        guard !disconnecting else { return }
        if state.isConnected, Date().timeIntervalSince(lastWSMessageAt) < 10 { return }
        reconnectTask?.cancel()
        reconnectDelay = 1.0
        Task { await self.connect() }
    }

    // MARK: - Authentication

    private func fetchToken(username: String, password: String) async -> String? {
        guard let url = URL(string: "\(baseURL)/signalk/v1/auth/login") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["username": username,
                                                                    "password": password])
        applyPiHeaders(&req)
        guard let (data, resp) = try? await Self.restSession.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else { return nil }
        return token
    }

    // MARK: - Autopilot (HTTP PUT — infrequent; auth header injected when token is set)

    func adjustAutopilot(by degrees: Double) async {
        targetHeading = (targetHeading + degrees + 360).truncatingRemainder(dividingBy: 360)
        await putSignalK("steering/autopilot/target/headingMagnetic",
                         value: targetHeading * .pi / 180)
    }

    func engageAutopilot() async {
        targetHeading = headingMagnetic
        await putSignalK("steering/autopilot/state", value: "auto")
        await putSignalK("steering/autopilot/target/headingMagnetic",
                         value: headingMagnetic * .pi / 180)
        autopilotEngaged = true
    }

    func standbyAutopilot() {
        Task { await putSignalK("steering/autopilot/state", value: "standby") }
        autopilotEngaged = false
    }

    private func putSignalK(_ path: String, value: Any) async {
        guard let url = URL(string: "\(baseURL)/signalk/v1/api/vessels/self/\(path)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken { req.setValue("JWT \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["value": value])
        applyPiHeaders(&req)
        _ = try? await Self.restSession.data(for: req)
    }

    // MARK: - Vessel name (HTTP, called once on connect)

    private func fetchVesselName() async -> String {
        guard let url = URL(string: "\(baseURL)/signalk/v1/api/vessels/self") else { return "Matau" }
        var req = URLRequest(url: url, timeoutInterval: 8)
        applyPiHeaders(&req)
        guard let (data, _) = try? await Self.restSession.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else { return "Matau" }
        return name
    }

    // MARK: - Navigation math

    func distanceTo(lat lat2: Double, lon lon2: Double) -> Double {
        let R  = 3440.065
        let φ1 = latitude * .pi / 180
        let φ2 = lat2     * .pi / 180
        let Δφ = (lat2 - latitude) * .pi / 180
        let Δλ = (lon2 - longitude) * .pi / 180
        let a  = sin(Δφ/2) * sin(Δφ/2) + cos(φ1) * cos(φ2) * sin(Δλ/2) * sin(Δλ/2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    func bearing(toLat lat2: Double, lon2: Double) -> Double {
        let φ1 = latitude * .pi / 180
        let φ2 = lat2     * .pi / 180
        let Δλ = (lon2 - longitude) * .pi / 180
        let y  = sin(Δλ) * cos(φ2)
        let x  = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    // MARK: - Helpers

    private func toDeg(_ r: Double) -> Double { r * 180 / .pi }

    private func asDouble(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int    { return Double(i) }
        return nil
    }

    private func clamp(_ v: Any?, lo: Double, hi: Double) -> Double? {
        guard let d = asDouble(v), d >= lo, d <= hi else { return nil }
        return d
    }

    private func applyPosition(lat: Double, lon: Double) {
        lastPositionAt = Date()    // a fix arrived → WS is alive (gates REST fallback)
        guard positionInitialised else {
            latitude = lat; longitude = lon
            positionInitialised = true
            lastAcceptedAt = Date()
            return
        }
        let dLat = abs(lat - latitude)
        let dLon = abs(lon - longitude)
        if dLat > Self.maxPositionJumpDeg || dLon > Self.maxPositionJumpDeg {
            // Large jump. Accept it anyway if the track has gone stale (anti-freeze
            // backstop) or if a previous fix already flagged a jump near here —
            // two readings agreeing means the boat really moved, not a one-sample
            // spike. Otherwise hold this sample back and wait for confirmation.
            let stale = Date().timeIntervalSince(lastAcceptedAt) > Self.positionStaleSec
            let confirmed = jumpCandidate.map {
                abs(lat - $0.lat) <= Self.maxPositionJumpDeg &&
                abs(lon - $0.lon) <= Self.maxPositionJumpDeg
            } ?? false
            guard stale || confirmed else {
                jumpCandidate = (lat, lon)
                return
            }
        }
        latitude = lat; longitude = lon
        lastAcceptedAt = Date()
        jumpCandidate = nil
    }
}
