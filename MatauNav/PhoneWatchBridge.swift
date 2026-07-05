import Foundation
import WatchConnectivity

/// Phone-side bridge for the Watch autopilot view.
///
/// Out: mirrors the fields the watch needs (heading, twa, rudder, autopilot
///      state) via WCSession applicationContext + live sendMessage pushes when
///      the watch is foreground.
/// In:  receives autopilot commands from the watch (`sendMessage` /
///      `transferUserInfo`) and forwards them to `PiStateService`.
///
/// Architecture rationale: the phone already has every SignalK field via
/// `SignalKService`. Duplicating that connection on the watch would mean
/// porting ~500 lines plus a long-lived WebSocket on a battery-sensitive
/// device. Routing through the phone keeps the watch a thin remote and means
/// adding a new field later is one line on each side.
@MainActor
final class PhoneWatchBridge: NSObject {
    static let shared = PhoneWatchBridge()

    private weak var signalK: SignalKService?
    private weak var piState: PiStateService?

    private var pushTask: Task<Void, Never>?
    private var lastPushed: [String: AnyHashable] = [:]

    /// Wire dependencies and start the WC session + state push loop.
    func start(signalK: SignalKService, piState: PiStateService) {
        self.signalK = signalK
        self.piState = piState

        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = SessionDelegate.shared
        SessionDelegate.shared.commandHandler = { [weak self] cmd in
            await self?.handle(command: cmd) ?? false
        }
        s.activate()

        pushTask?.cancel()
        pushTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pushIfChanged()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func snapshot() -> [String: AnyHashable] {
        guard let sk = signalK else { return [:] }
        var dict: [String: AnyHashable] = [
            "heading":       sk.headingMagnetic,
            "twa":           sk.trueWindAngle,
            "rudder":        sk.rudderAngle,
            "apEngaged":     sk.autopilotEngaged,
            "apMode":        piState?.autopilotMode ?? "standby",
            "targetHeading": sk.targetHeading,
        ]
        // Explicitly carry through nil so the watch can clear its locked angle
        // when the autopilot leaves wind mode.
        if let locked = piState?.autopilotLockedWindAngle {
            dict["lockedWindAngle"] = locked
        } else {
            dict["lockedWindAngle"] = NSNull()
        }
        return dict
    }

    private func pushIfChanged() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated else { return }

        let snap = snapshot()
        guard snap != lastPushed else { return }
        lastPushed = snap

        let payload = snap.mapValues { $0 as Any }

        // Live push when the watch is in front — sub-200 ms latency.
        if s.isReachable {
            s.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
        // Cached snapshot for the next wake — coalesced by the system.
        try? s.updateApplicationContext(payload)
    }

    /// Phone-side command execution: forward to the Pi state service.
    fileprivate func handle(command cmd: String) async -> Bool {
        guard let piState else { return false }
        return await piState.sendAutopilotCommand(cmd)
    }
}

/// WCSession requires an NSObject delegate. We park it on a singleton that
/// hands commands back to the @MainActor bridge.
private final class SessionDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = SessionDelegate()

    var commandHandler: (@Sendable (String) async -> Bool)?

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession,
                 didReceiveMessage message: [String : Any],
                 replyHandler: @escaping ([String : Any]) -> Void) {
        guard let cmd = message["cmd"] as? String, let h = commandHandler else {
            replyHandler(["ok": false]); return
        }
        // Reply closure isn't @Sendable but WCSession only invokes it once,
        // so wrapping in an unchecked-Sendable box is safe.
        let reply = ReplyBox(call: replyHandler)
        Task {
            let ok = await h(cmd)
            reply.call(["ok": ok])
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
        // Watch queued a command while we were unreachable — execute now.
        guard let cmd = userInfo["cmd"] as? String, let h = commandHandler else { return }
        Task { _ = await h(cmd) }
    }
}

private struct ReplyBox: @unchecked Sendable {
    let call: ([String: Any]) -> Void
}
