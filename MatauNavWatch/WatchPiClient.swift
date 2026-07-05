import Foundation
import Observation

/// State store for the watch autopilot view. The phone is the gateway: it
/// already subscribes to SignalK and tracks the autopilot via `PiStateService`.
/// We mirror the fields the watch needs over WatchConnectivity, and send any
/// autopilot commands back through the same channel.
///
/// Net effect: the watch has zero networking of its own. Adding a new field
/// later is one line on the phone (push it) and one line here (read it).
@Observable
@MainActor
final class WatchPiClient {

    // Mirrored vessel state
    private(set) var heading: Double = 0
    private(set) var trueWindAngle: Double = 0     // signed, ±180°
    private(set) var rudderAngle: Double = 0

    // Mirrored autopilot state
    private(set) var apEngaged: Bool = false
    private(set) var apMode: String = "standby"    // "compass" | "wind" | "standby"
    private(set) var targetHeading: Double = 0
    private(set) var lockedWindAngle: Double? = nil

    // Connectivity
    private(set) var connected: Bool = false       // phone reachable via WC
    private(set) var commandPending: Bool = false

    // MARK: - Apply state pushed from the phone

    func apply(_ state: [String: Any]) {
        if let v = state["heading"]       as? Double { heading = v }
        if let v = state["twa"]           as? Double { trueWindAngle = v }
        if let v = state["rudder"]        as? Double { rudderAngle = v }
        if let v = state["apEngaged"]     as? Bool   { apEngaged = v }
        if let v = state["apMode"]        as? String { apMode = v }
        if let v = state["targetHeading"] as? Double { targetHeading = v }
        // `lockedWindAngle` is nullable — distinguish missing key (don't clear)
        // from explicit null (do clear, autopilot is no longer in wind mode).
        if state.keys.contains("lockedWindAngle") {
            lockedWindAngle = state["lockedWindAngle"] as? Double
        }
        connected = true
    }

    func setReachable(_ r: Bool) { connected = r }

    // MARK: - Commands (routed through the phone)

    /// Valid: compass_auto, wind_auto, standby, plus1, plus10, minus1, minus10.
    @discardableResult
    func sendCommand(_ cmd: String) async -> Bool {
        guard !commandPending else { return false }
        commandPending = true
        defer { commandPending = false }

        // Optimistic local update — UI moves instantly, the next state push
        // from the phone reconciles to canonical Pi truth.
        applyOptimistic(cmd)

        return await WatchSessionBridge.shared.sendCommand(cmd)
    }

    private func applyOptimistic(_ cmd: String) {
        switch cmd {
        case "compass_auto":
            apEngaged = true
            apMode = "compass"
            targetHeading = heading
            lockedWindAngle = nil
        case "wind_auto":
            apEngaged = true
            apMode = "wind"
            lockedWindAngle = trueWindAngle
        case "standby":
            apEngaged = false
            apMode = "standby"
            lockedWindAngle = nil
        case "plus1":   bump(1)
        case "plus10":  bump(10)
        case "minus1":  bump(-1)
        case "minus10": bump(-10)
        default: break
        }
    }

    private func bump(_ delta: Double) {
        guard apEngaged else { return }
        if apMode == "wind" {
            let cur = lockedWindAngle ?? trueWindAngle
            lockedWindAngle = max(-180, min(180, cur + delta))
        } else {
            targetHeading = (targetHeading + delta + 360).truncatingRemainder(dividingBy: 360)
        }
    }
}
