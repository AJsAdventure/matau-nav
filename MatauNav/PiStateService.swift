import Foundation
import Observation
import SwiftUI
import CoreLocation

// MARK: - PiStateService
//
// Thin client for the Pi-side `state_server.py`. The Pi owns:
//   • AIS subscription (one WebSocket on the boat → all phones)
//   • CPA / TCPA / guard-zone evaluation
//   • MOB state (persists across phone restarts)
//   • Active route + auto-advance on arrival
//
// The phone polls /state every 2 s, caches into AppSettings for offline
// display, and PUTs mutations through this service. AppSettings remains the
// SwiftUI source of truth for *rendering* — but its writers go via here, so
// the Pi stays canonical.
//
// If the Pi is unreachable, the phone keeps showing the last-known state
// and surfaces a "Pi offline" badge.

@Observable
@MainActor
final class PiStateService {

    // Server-fed state
    private(set) var targets: [Int: AISTarget] = [:]
    private(set) var dangerousMMSIs: Set<Int> = []
    private(set) var aisConnected: Bool = false
    private(set) var connected: Bool = false
    private(set) var lastSync: Date? = nil
    private(set) var lastError: String?

    /// Derived URL — defaults to http://<signalK host>:10114
    var baseURL: String = ""

    private var pollTask: Task<Void, Never>?
    private var consecutiveFailures = 0

    // MARK: Lifecycle

    func start(signalKHost: String, port: Int = 10114) {
        baseURL = "http://\(signalKHost):\(port)"
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                // Back off while the Pi is down: 2 s live cadence, easing to
                // 10 s after repeated failures so a rebooting Pi isn't hammered
                // (each failed attempt also costs a 4 s timeout on this task).
                let fails = self?.consecutiveFailures ?? 0
                let delay = fails < 3 ? 2.0 : min(10.0, Double(fails))
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        connected = false
        aisConnected = false
        targets.removeAll()
        dangerousMMSIs.removeAll()
    }

    // MARK: Poll

    private struct StatePayload: Decodable {
        struct Vessel: Decodable {
            let lat: Double?; let lon: Double?
            let cog: Double?; let sog: Double?
            let heading: Double?; let twd: Double?; let tws: Double?
        }
        struct Targets: Decodable { let targets: [TargetDTO] }
        struct TargetDTO: Decodable {
            let mmsi: Int
            let name: String?; let callSign: String?; let shipType: Int?
            let lat: Double; let lon: Double
            let cog: Double; let sog: Double
            let heading: Double?
            let length: Double?; let beam: Double?; let draft: Double?
            let destination: String?
            let cpaNm: Double?; let tcpaMin: Double?; let danger: Bool?
            let lastUpdate: Double?
        }
        struct MOB: Decodable { let lat: Double; let lon: Double; let t: Double }
        struct Wp: Decodable {
            let id: String?; let name: String?
            let lat: Double; let lon: Double
            let arrivalRadiusNm: Double?
        }
        struct RouteDTO: Decodable { let name: String?; let waypoints: [Wp]; let legIndex: Int? }
        struct AP: Decodable {
            let engaged: Bool?
            let mode: String?               // "compass" | "wind" | "standby" | nil
            let targetHeadingDeg: Double?
            let lockedWindAngle: Double?
            let engagedAt: Double?
        }
        let ts: Double
        let aisConnected: Bool
        let vessel: Vessel
        let ais: Targets
        let mob: MOB?
        let route: RouteDTO?
        let autopilot: AP?
    }

    /// Settings reference so we can mirror server state into the cache.
    var settings: AppSettings?
    /// SignalKService reference — autopilot engagement + target heading are
    /// mirrored here so the existing AutopilotView keeps reading from one place.
    var signalK: SignalKService?

    /// Autopilot mode: "compass", "wind", "waypoint", or "standby".
    private(set) var autopilotMode: String = "standby"
    private(set) var autopilotEngaged: Bool = false
    /// In wind mode, the AWA the autopilot is trying to maintain (signed deg).
    private(set) var autopilotLockedWindAngle: Double?

    /// While this is in the future, `apply()` will NOT overwrite
    /// `signalK.targetHeading` from poll data. Set after any heading-nudge
    /// command so an optimistic local update isn't stomped by a stale poll
    /// that returns before the AP has processed the button press.
    private var suppressHeadingPollUntil: Date = .distantPast
    /// While in the future, apply() will NOT mirror the Pi's route into
    /// settings — a poll response already in flight when the user cleared or
    /// replaced the route must not resurrect the old one (which locked the
    /// UI in "Add to Route" and made routes feel un-cancellable).
    private var suppressRouteMirrorUntil: Date = .distantPast

    /// Call before sending a plus/minus heading command so the local optimistic
    /// update survives for `duration` seconds without being overwritten by polls.
    func suppressHeadingUpdates(for duration: TimeInterval = 5) {
        suppressHeadingPollUntil = Date().addingTimeInterval(duration)
    }

    /// Manually trigger a refresh — used by views on `.task`/`.onAppear` so they
    /// don't have to wait for the next 2-second tick.
    func refreshNow() async { await poll() }

    private func poll() async {
        // Re-derive the URL each poll: the host can change in Setup at
        // runtime, and SignalKService may have failed over to Tailscale or
        // the public bridge — this service must follow it or the anchor
        // console shows live instruments next to a dead AIS/route panel.
        if let sk = signalK {
            baseURL = sk.piBase(port: 10114)
        } else if let host = settings?.signalKHost, !host.isEmpty {
            baseURL = "http://\(host):10114"
        }
        guard let url = URL(string: "\(baseURL)/state") else { return }
        do {
            var req = URLRequest(url: url, timeoutInterval: 4)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            applyBoatHeaders(&req)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                lastError = "HTTP \( (resp as? HTTPURLResponse)?.statusCode ?? 0 )"
                connected = false
                consecutiveFailures += 1
                return
            }
            let p = try JSONDecoder().decode(StatePayload.self, from: data)
            apply(p)
            connected = true
            aisConnected = p.aisConnected
            lastSync = Date()
            lastError = nil
            consecutiveFailures = 0
        } catch {
            connected = false
            lastError = error.localizedDescription
            consecutiveFailures += 1
        }
    }

    private func apply(_ p: StatePayload) {
        // Targets
        var newTargets: [Int: AISTarget] = [:]
        var hot: Set<Int> = []
        let now = Date()
        for d in p.ais.targets {
            let target = AISTarget(
                mmsi: d.mmsi,
                name: d.name,
                callSign: d.callSign,
                shipType: d.shipType,
                latitude: d.lat,
                longitude: d.lon,
                cog: d.cog,
                sog: d.sog,
                heading: d.heading,
                rateOfTurn: nil,
                navStatus: nil,
                length: d.length,
                beam: d.beam,
                draft: d.draft,
                destination: d.destination,
                cpaNm: d.cpaNm,
                tcpaMin: d.tcpaMin,
                lastUpdate: d.lastUpdate.map { Date(timeIntervalSince1970: $0) } ?? now
            )
            newTargets[d.mmsi] = target
            if d.danger == true { hot.insert(d.mmsi) }
        }
        self.targets = newTargets
        self.dangerousMMSIs = hot

        // Mirror Pi state into AppSettings so existing UI keeps reading from there
        guard let s = settings else { return }

        if let mob = p.mob {
            s.mobActive = true
            s.mobLat = mob.lat; s.mobLon = mob.lon; s.mobTime = mob.t
        } else if s.mobActive {
            s.mobActive = false
        }

        // Autopilot — Pi is canonical (it brokers commands and tracks state
        // because the driver doesn't publish back into SignalK). Mirror the
        // truth here so the AutopilotView shows the right thing whether the
        // engagement happened on this phone, another phone, or via the helm.
        if let ap = p.autopilot {
            autopilotEngaged = ap.engaged ?? false
            autopilotMode    = ap.mode ?? (autopilotEngaged ? "compass" : "standby")
            autopilotLockedWindAngle = ap.lockedWindAngle
            if let sk = signalK {
                sk.autopilotEngaged = autopilotEngaged
                // Only overwrite from poll if no heading command was sent recently.
                // Stale Pi state (before the AP has processed the button press) must
                // not undo the local optimistic update the user just applied.
                if let tgt = ap.targetHeadingDeg,
                   Date() > suppressHeadingPollUntil {
                    sk.targetHeading = tgt
                }
            }
        }

        if Date() > suppressRouteMirrorUntil {
            if let r = p.route {
                let wps = r.waypoints.enumerated().map { (i, w) in
                    RouteWaypoint(
                        name: w.name ?? String(i + 1),
                        lat: w.lat, lon: w.lon,
                        arrivalRadiusNm: w.arrivalRadiusNm ?? 0.05
                    )
                }
                s.activeRoute = Route(name: r.name ?? "Route",
                                      waypoints: wps,
                                      legIndex: r.legIndex ?? 0)
            } else if s.activeRoute != nil {
                s.activeRoute = nil
            }
        }
    }

    // MARK: Mutations

    func setMOB(lat: Double, lon: Double, t: Double = Date().timeIntervalSince1970) async {
        await put("/mob", body: ["lat": lat, "lon": lon, "t": t])
    }

    func clearMOB() async { await delete("/mob") }

    func setRoute(_ r: Route) async {
        // Optimistic: show the new route immediately; the Pi confirms via poll.
        settings?.activeRoute = r
        settings?.persist()
        suppressRouteMirrorUntil = Date().addingTimeInterval(5)
        let body: [String: Any] = [
            "name": r.name,
            "legIndex": r.legIndex,
            "waypoints": r.waypoints.map { w in
                [
                    "id": w.id.uuidString,
                    "name": w.name,
                    "lat": w.lat, "lon": w.lon,
                    "arrivalRadiusNm": w.arrivalRadiusNm,
                ] as [String: Any]
            },
        ]
        await put("/route", body: body)
    }

    func clearRoute() async {
        // Optimistic: the route disappears NOW — an in-flight poll carrying
        // the old route can no longer resurrect it after the delete.
        settings?.activeRoute = nil
        settings?.persist()
        suppressRouteMirrorUntil = Date().addingTimeInterval(5)
        await delete("/route")
    }

    func advanceRoute() async { await postEmpty("/route/advance") }

    /// Mutate server-side tunables (CPA thresholds, guard zone, ais range).
    func setConfig(_ body: [String: Any]) async {
        await put("/config", body: body)
    }

    /// Send an autopilot command through the Pi command broker.
    /// Valid commands: compass_auto, wind_auto, standby, plus1, plus10, minus1, minus10.
    /// Returns true if the anchor daemon acknowledged.
    @discardableResult
    func sendAutopilotCommand(_ cmd: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/autopilot/\(cmd)") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        applyBoatHeaders(&req)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            // Apply the returned snapshot immediately so the UI is snappy.
            if ok, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ap = json["autopilot"] as? [String: Any] {
                autopilotEngaged = ap["engaged"]   as? Bool   ?? autopilotEngaged
                autopilotMode    = ap["mode"]      as? String ?? autopilotMode
                autopilotLockedWindAngle = ap["lockedWindAngle"] as? Double
                if let sk = signalK {
                    sk.autopilotEngaged = autopilotEngaged
                    // Do NOT apply targetHeadingDeg from the command response —
                    // the Pi returns the pre-command value (before the AP has
                    // processed the SeaTalk press). The optimistic local update
                    // + natural poll after suppress-window expiry owns this.
                }
            }
            await poll()
            return ok
        } catch {
            return false
        }
    }

    // MARK: HTTP plumbing

    /// Cloudflare Access headers when baseURL points at the public bridge.
    private func applyBoatHeaders(_ req: inout URLRequest) {
        guard let s = settings, let base = req.url?.absoluteString else { return }
        for (k, v) in s.boatAuthHeaders(forBase: base) { req.setValue(v, forHTTPHeaderField: k) }
    }

    private func put(_ path: String, body: [String: Any]) async {
        guard let url = URL(string: "\(baseURL)\(path)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        applyBoatHeaders(&req)
        _ = try? await URLSession.shared.data(for: req)
        await poll()
    }

    private func delete(_ path: String) async {
        guard let url = URL(string: "\(baseURL)\(path)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "DELETE"
        applyBoatHeaders(&req)
        _ = try? await URLSession.shared.data(for: req)
        await poll()
    }

    private func postEmpty(_ path: String) async {
        guard let url = URL(string: "\(baseURL)\(path)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "POST"
        applyBoatHeaders(&req)
        _ = try? await URLSession.shared.data(for: req)
        await poll()
    }
}
