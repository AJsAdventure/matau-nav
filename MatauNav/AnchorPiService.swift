import Foundation
import Observation

// Monitors the Pi anchor watch daemon via HTTP polling.
// • Polls GET /status every 30 s — 3 consecutive failures → loud alarm (bypasses mute)
// • Automatically fails over to Tailscale URL when local is unreachable
// • Re-checks local URL every 5 minutes when running on Tailscale
// • Provides syncConfig() to push alarm limits to the Pi via PUT /config
@Observable @MainActor
final class AnchorPiService {

    enum ConnectionState: Equatable {
        case unknown, connected, disconnected
    }

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
    /// The URL that is currently responding (either local or Tailscale)
    private(set) var activeURL: String = ""

    private var consecutiveFails  = 0
    private(set) var onTailscale   = false
    private var localCheckCountdown = 0   // how many polls until we try local again
    private let localRetryInterval  = 10  // re-check local every ~5 min (10 × 30s polls)
    private let player = AlarmPlayer.shared

    // MARK: - Monitoring

    func startMonitoring(settings: AppSettings) async {
        while !Task.isCancelled {
            await poll(settings: settings)
            let delay: Duration = connectionState == .disconnected ? .seconds(10) : .seconds(30)
            try? await Task.sleep(for: delay)
        }
    }

    private func poll(settings: AppSettings) async {
        let local     = settings.effectiveAnchorPiURL
        let tailscale = settings.anchorPiTailscaleURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !local.isEmpty else {
            connectionState = .unknown
            activeURL       = ""
            return
        }

        // Periodically try to switch back to local when we're on Tailscale
        if onTailscale && !tailscale.isEmpty {
            localCheckCountdown -= 1
            if localCheckCountdown <= 0 {
                localCheckCountdown = localRetryInterval
                if await tryFetch(base: local) != nil {
                    // Local is reachable again — switch back
                    onTailscale = false
                    activeURL   = local
                }
            }
        }

        // Pick the URL to use this cycle
        let urlToUse: String
        if onTailscale, !tailscale.isEmpty {
            urlToUse = tailscale
        } else {
            urlToUse = local
        }

        if let status = await tryFetch(base: urlToUse) {
            piStatus           = status
            lastSeen           = Date()
            consecutiveFails   = 0
            activeURL          = urlToUse
            if connectionState != .connected {
                connectionState = .connected
                player.stop()   // clear Pi-down alarm if it was ringing
            }
            return
        }

        // Fetch failed — if we were using local and Tailscale is configured, try Tailscale now
        if !onTailscale, !tailscale.isEmpty {
            if let status = await tryFetch(base: tailscale) {
                piStatus           = status
                lastSeen           = Date()
                consecutiveFails   = 0
                onTailscale        = true
                activeURL          = tailscale
                localCheckCountdown = localRetryInterval
                if connectionState != .connected {
                    connectionState = .connected
                    player.stop()
                }
                return
            }
        }

        // Both URLs (if configured) failed
        consecutiveFails += 1
        connectionState   = .disconnected
        if consecutiveFails >= 3 {
            player.start()  // Pi unreachable for ~90 s → loud alarm
        }
    }

    private func tryFetch(base: String) async -> PiStatus? {
        guard let url = URL(string: base + "/status") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "GET"
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
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = json["ok"] as? Bool else { return false }
        return ok
    }

    // MARK: - Config sync

    func syncConfig(settings: AppSettings) async {
        // Sync to whichever URL is currently active (or fall back to primary)
        let base = activeURL.isEmpty
            ? settings.effectiveAnchorPiURL
            : activeURL
        guard !base.isEmpty, let url = URL(string: base + "/config") else { return }

        let payload: [String: Any] = [
            "anchorActive":     settings.anchorActive,
            "anchorLat":        settings.anchorLat,
            "anchorLon":        settings.anchorLon,
            "anchorRadius":     settings.anchorRadius,
            "anchorWindMax":    settings.anchorWindMax,
            "anchorWindShift":  settings.anchorWindShift,
            "anchorInitialTWD": settings.anchorInitialTWD,
            "anchorDepthMin":   settings.anchorDepthMin,
            "anchorDepthMax":   settings.anchorDepthMax,
            "ntfyServer":       settings.anchorNtfyServer,
            "ntfyTopic":        settings.anchorNtfyTopic,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "PUT"
        req.httpBody   = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try? await URLSession.shared.data(for: req)
    }
}
