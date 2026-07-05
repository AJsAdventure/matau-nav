import Foundation
import WatchConnectivity

/// WatchConnectivity bridge: receives mirrored state from the phone and sends
/// autopilot commands back. The phone owns SignalK and the Pi — the watch is
/// a thin remote.
final class WatchSessionBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchSessionBridge()

    /// Latest state dict applied — the view layer registers this to receive
    /// updates. Always invoked on the main queue.
    var onState: (([String: Any]) -> Void)?
    /// Reachability changed — driven on the main queue.
    var onReachability: ((Bool) -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        // applicationContext is cached by the system — apply the last value
        // we received so the first frame after wake isn't empty.
        applyContext(s.receivedApplicationContext)
        let reachable = s.isReachable
        DispatchQueue.main.async { self.onReachability?(reachable) }
    }

    // MARK: - Send a command, wait for the phone's reply

    /// Returns true if the phone acknowledged the Pi accepted the command.
    func sendCommand(_ cmd: String) async -> Bool {
        guard WCSession.isSupported() else { return false }
        let s = WCSession.default
        guard s.activationState == .activated else { return false }
        return await withCheckedContinuation { cont in
            if s.isReachable {
                s.sendMessage(["cmd": cmd],
                              replyHandler: { reply in
                                  cont.resume(returning: (reply["ok"] as? Bool) ?? false)
                              },
                              errorHandler: { _ in cont.resume(returning: false) })
            } else {
                // Queue for delivery when the phone wakes up — the user won't
                // get a confirmation but the command will eventually run.
                s.transferUserInfo(["cmd": cmd])
                cont.resume(returning: false)
            }
        }
    }

    // MARK: - WCSessionDelegate

    private func applyContext(_ ctx: [String: Any]) {
        guard !ctx.isEmpty else { return }
        // WCSession property-list dicts are effectively immutable across
        // threads but `[String: Any]` isn't Sendable — wrap in a box so the
        // dict can cross to the main actor without Swift 6 strict checks
        // flagging a data race.
        let box = StateBox(dict: ctx)
        DispatchQueue.main.async { self.onState?(box.dict) }
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        applyContext(session.receivedApplicationContext)
        let reachable = session.isReachable
        DispatchQueue.main.async { self.onReachability?(reachable) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        applyContext(applicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        // Phone occasionally pushes via sendMessage when foreground — treat
        // it as a state update too.
        applyContext(message)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        DispatchQueue.main.async { self.onReachability?(reachable) }
    }
}

/// Sendable wrapper for WC property-list dicts — they're inert plists, safe
/// to ship across actors even though the element type is `Any`.
private struct StateBox: @unchecked Sendable {
    let dict: [String: Any]
}
