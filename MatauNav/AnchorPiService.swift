import Foundation
import Observation

// Monitors the Pi anchor watch daemon via HTTP polling.
// • Polls GET /status every 30 s — 3 consecutive failures → loud alarm (bypasses mute)
// • Automatically fails over: local URL → Tailscale URL → public HTTPS
//   remote bridge (Cloudflare Tunnel, Access service-token headers)
// • Re-checks the better URLs every 5 minutes when running on a fallback
// • Provides syncConfig() to arm/disarm the daemon's own anchor watch
//   (POST /anchor/arm | /anchor/disarm — the daemon's actual API; a previous
//   incarnation PUT a /config document the daemon never implemented, so every
//   sync silently died with a 501 and the daemon never knew about the anchor)
//
// Deliberately keeps its own failover instead of following SignalKService:
// this is the alarm backstop, and it must keep reaching the daemon even when
// the SignalK connection logic is wedged.
@Observable @MainActor
final class AnchorPiService {

    enum ConnectionState: Equatable {
        case unknown, connected, disconnected
    }

    enum PathKind { case local, tailscale, remote }

    struct PiStatus: Decodable {
        let ok: Bool
        let time: Double
        let anchorActive: Bool
        let activeAlarms: [String]
        let lat, lon, tws, twd, depth: Double
    }

    private(set) var connectionState: ConnectionState = .unknown
    private(set) var piStatus: PiStatus?
    private(set) var lastSeen: Date?
    /// The URL that is currently responding (local, Tailscale or remote)
    private(set) var activeURL: String = ""
    private(set) var activeKind: PathKind = .local

    var onTailscale: Bool { activeKind == .tailscale && connectionState == .connected }
    var onRemote:    Bool { activeKind == .remote    && connectionState == .connected }

    private var consecutiveFails  = 0
    private var localCheckCountdown = 0   // how many polls until we try the better URLs again
    private let localRetryInterval  = 10  // re-check every ~5 min (10 × 30s polls)

    /// True while the Pi daemon has NOT yet acknowledged the latest anchor
    /// state (drop/raise/position). The poll loop keeps retrying the config
    /// push until it lands — a daemon watching a stale anchorage is worse
    /// than no daemon, because it feels like a backstop and isn't.
    private(set) var configDirty = false

    func markConfigDirty() { configDirty = true }

    /// Local snooze for the daemon-alarm mirror (see below).
    private var mirrorSilencedUntil: Date = .distantPast

    /// Mirror the daemon's OWN alarms (dragging / gps_loss) through the app
    /// siren. The boat Pi has no buzzer fitted and ntfy may be unconfigured —
    /// without this mirror a daemon-only alarm is completely silent (observed
    /// live 2026-07-12: daemon flagged gps_loss for a frozen GPS feed and
    /// nothing anywhere made a sound).
    private func reconcileDaemonAlarmMirror() {
        let alarming = (piStatus?.anchorActive ?? false)
                    && !(piStatus?.activeAlarms.isEmpty ?? true)
        if alarming, Date() >= mirrorSilencedUntil {
            AlarmSiren.shared.acquire("pi-daemon-alarm")
        } else {
            AlarmSiren.shared.release("pi-daemon-alarm")
        }
    }

    /// Silence the daemon's alarms AND the local mirror — wired to the app's
    /// Snooze so one button quiets every layer.
    func silenceDaemonAlarms(minutes: Int, settings: AppSettings) async {
        mirrorSilencedUntil = Date().addingTimeInterval(Double(minutes) * 60)
        AlarmSiren.shared.release("pi-daemon-alarm")
        let base = activeURL.isEmpty ? settings.effectiveAnchorPiURL : activeURL
        guard !base.isEmpty, let url = URL(string: base + "/anchor/silence") else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.httpBody   = try? JSONSerialization.data(withJSONObject: ["minutes": minutes])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in settings.boatAuthHeaders(forBase: base) { req.setValue(v, forHTTPHeaderField: k) }
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Monitoring

    func startMonitoring(settings: AppSettings) async {
        while !Task.isCancelled {
            await poll(settings: settings)
            // Un-acknowledged anchor state? Retry the push now that we know
            // which URL answers (poll just updated activeURL).
            if configDirty, connectionState == .connected {
                await syncConfig(settings: settings)
            }
            let delay: Duration = connectionState == .disconnected ? .seconds(10) : .seconds(30)
            try? await Task.sleep(for: delay)
        }
    }

    /// Candidate daemon URLs in preference order: boat LAN, tailnet, public
    /// HTTPS bridge. Only non-empty tiers appear.
    private func candidates(settings: AppSettings) -> [(url: String, kind: PathKind)] {
        var out: [(String, PathKind)] = []
        let local = settings.effectiveAnchorPiURL
        if !local.isEmpty { out.append((local, .local)) }
        let ts = settings.effectiveAnchorPiTailscaleURL
        if !ts.isEmpty { out.append((ts, .tailscale)) }
        if let remote = settings.remoteBase(port: 10112) { out.append((remote, .remote)) }
        return out
    }

    private func poll(settings: AppSettings) async {
        let cands = candidates(settings: settings)
        guard !cands.isEmpty else {
            connectionState = .unknown
            activeURL       = ""
            return
        }

        // Try the active URL first for a fast happy path — except every
        // ~5 min on a fallback, when the cycle runs in preference order so
        // we migrate back up as soon as a better tier answers.
        var order = cands
        if let idx = cands.firstIndex(where: { $0.url == activeURL }), idx > 0 {
            localCheckCountdown -= 1
            if localCheckCountdown <= 0 {
                localCheckCountdown = localRetryInterval   // preference order this cycle
            } else {
                order = [cands[idx]] + cands.enumerated()
                    .filter { $0.offset != idx }.map(\.element)
            }
        }

        for cand in order {
            if let status = await tryFetch(base: cand.url, settings: settings) {
                piStatus         = status
                lastSeen         = Date()
                consecutiveFails = 0
                if cand.url != activeURL, cand.kind != .local {
                    localCheckCountdown = localRetryInterval   // just landed on a fallback
                }
                activeURL  = cand.url
                activeKind = cand.kind
                if connectionState != .connected {
                    connectionState = .connected
                    AlarmSiren.shared.release("pi-daemon")   // clear Pi-down alarm
                }
                reconcileDaemonAlarmMirror()
                return
            }
        }

        // Every configured URL failed
        consecutiveFails += 1
        connectionState   = .disconnected
        if consecutiveFails >= 3 {
            AlarmSiren.shared.acquire("pi-daemon")  // Pi unreachable ≥3 polls → loud alarm
        }
    }

    private func tryFetch(base: String, settings: AppSettings) async -> PiStatus? {
        guard let url = URL(string: base + "/status") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "GET"
        for (k, v) in settings.boatAuthHeaders(forBase: base) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONDecoder().decode(PiStatus.self, from: data)
    }

    // MARK: - Autopilot commands

    /// POST /autopilot/<cmd> to the daemon.  Returns true when the Pi acknowledged.
    func sendAutopilotCommand(_ cmd: String, settings: AppSettings) async -> Bool {
        // Priority: (1) last-known good URL, (2) effective URL (override or signalKHost:10112)
        let configured = settings.effectiveAnchorPiURL
        let base = !activeURL.isEmpty  ? activeURL
                 : !configured.isEmpty ? configured
                 :                       "http://matau.local:10112"
        guard
              let url = URL(string: "\(base)/autopilot/\(cmd)") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        for (k, v) in settings.boatAuthHeaders(forBase: base) { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = json["ok"] as? Bool else { return false }
        return ok
    }

    // MARK: - Config sync

    /// Arm/disarm the daemon's anchor watch to mirror the app's. Returns true
    /// when the daemon acknowledged; on failure the state is marked dirty and
    /// the poll loop retries until it lands.
    ///
    /// Speaks the daemon's REAL API: POST /anchor/arm {lat, lon, radius_m,
    /// delay_s} and POST /anchor/disarm, both answering {"ok": true}.
    @discardableResult
    func syncConfig(settings: AppSettings) async -> Bool {
        // Sync to whichever URL is currently active (or fall back to primary)
        let base = activeURL.isEmpty
            ? settings.effectiveAnchorPiURL
            : activeURL
        // No Pi configured → nothing to keep in sync.
        guard !base.isEmpty else {
            configDirty = false
            return false
        }

        // Never arm the daemon on the (0,0) "no fix" sentinel.
        let arm = settings.anchorActive && (settings.anchorLat != 0 || settings.anchorLon != 0)
        let path = arm ? "/anchor/arm" : "/anchor/disarm"
        guard let url = URL(string: base + path) else {
            configDirty = false
            return false
        }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        for (k, v) in settings.boatAuthHeaders(forBase: base) { req.setValue(v, forHTTPHeaderField: k) }
        if arm {
            let payload: [String: Any] = [
                "lat":      settings.anchorLat,
                "lon":      settings.anchorLon,
                "radius_m": settings.anchorRadius,
                "delay_s":  settings.anchorAlarmDelay,
            ]
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true else {
            configDirty = true
            return false
        }
        configDirty = false
        return true
    }

}
