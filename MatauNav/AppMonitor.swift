//  AppMonitor.swift
//  Owns the app-scoped services and the long-lived monitoring loops.
//
//  Why this exists: the loops used to hang off ContentView's `.task` blocks.
//  That's fine on iOS, but on macOS the menu-bar agent must keep the anchor
//  watch + alarm loop running even when the main window is CLOSED — and a view's
//  `.task` is cancelled when its window closes. So the loops live here as Tasks
//  owned by this app-lifetime object; the view only kicks `start()` (idempotent).

import Foundation
import SwiftUI
import UserNotifications

#if os(macOS)
/// Thread-safe heartbeat the main-actor 2 s loop stamps and the off-main
/// watchdog reads. Lives outside AppMonitor so it doesn't inherit @MainActor.
private final class Heartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var beatAt     = Date()
    private var watching   = false
    private var lastNotify = Date.distantPast

    func beat(watching: Bool) {
        lock.lock(); beatAt = Date(); self.watching = watching; lock.unlock()
    }
    /// System sleep legitimately stops the heartbeat — don't call that a hang.
    func pause() {
        lock.lock(); watching = false; lock.unlock()
    }
    /// True when the heartbeat has stalled during an active anchor watch and
    /// a (re-)notification is due.
    func hangNotificationDue(threshold: TimeInterval, renotify: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard watching, Date().timeIntervalSince(beatAt) > threshold else {
            lastNotify = .distantPast
            return false
        }
        guard Date().timeIntervalSince(lastNotify) >= renotify else { return false }
        lastNotify = Date()
        return true
    }

    /// Build + start the watchdog timer. This MUST live here, in a plain
    /// nonisolated class — a closure formed inside @MainActor code (e.g.
    /// AppMonitor.start()) inherits main-actor isolation, and executing it
    /// on the timer's background queue trips the Swift runtime's isolation
    /// assertion. That exact mistake crashed the app (EXC_BREAKPOINT in
    /// dispatch_assert_queue) 90 s after EVERY launch on 2026-07-12 — the
    /// watchdog killed the watch it was guarding.
    func startWatchdog() -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 90, repeating: 30)
        t.setEventHandler { [weak self] in
            guard let self, self.hangNotificationDue(threshold: 90, renotify: 120) else { return }
            let content = UNMutableNotificationContent()
            content.title             = "⚓ ANCHOR WATCH FROZEN"
            content.body              = "Matau Nav has stopped responding while the anchor watch is active. Force-quit and reopen it NOW — position is not being monitored."
            content.sound             = .defaultCritical
            content.interruptionLevel = .timeSensitive
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "anchor_hang_\(Date().timeIntervalSince1970)",
                content: content, trigger: nil))
        }
        t.resume()
        return t
    }
}
#endif

@MainActor
@Observable
final class AppMonitor {
    // App-scoped services (previously @State on the App).
    let settings     = AppSettings()
    let signalK      = SignalKService()
    let anchorWatch  = AnchorWatchService()
    let piService    = AnchorPiService()
    let piState      = PiStateService()
    let tracks       = TrackService()
    let bathymetry   = BathymetryService()
    let contours     = ContourService()
    let predictWind  = PredictWindService()

    private var started = false
    private var tasks: [Task<Void, Never>] = []
    #if os(macOS)
    private let heartbeat = Heartbeat()
    private var watchdog: DispatchSourceTimer?
    #endif

    /// Launch every monitoring loop exactly once. Safe to call repeatedly
    /// (e.g. each time the window reopens) — only the first call does work.
    func start() {
        guard !started else { return }
        started = true

        // Keep poll/alarm timers at full cadence when the app is unfocused.
        AppActivity.shared.beginBackgroundActivity()

        // Ask for notification permission up front so anchor-drag alarms land.
        anchorWatch.requestPermissions()

        // Every drop/raise goes straight to the independent Pi alarm daemon;
        // if the push fails, the daemon poll loop retries until acknowledged.
        // The Pi is the backstop when this app/machine dies — it must never
        // be left watching a stale anchorage.
        anchorWatch.onWatchStateChanged = { [weak self] in
            guard let self else { return }
            self.piService.markConfigDirty()
            Task { await self.piService.syncConfig(settings: self.settings) }
        }
        // One Snooze silences every layer — app siren, daemon-alarm mirror,
        // and the daemon's own outputs (ntfy push / buzzer).
        anchorWatch.onSnooze = { [weak self] minutes in
            guard let self else { return }
            Task { await self.piService.silenceDaemonAlarms(minutes: minutes,
                                                            settings: self.settings) }
        }

        // Relaunched mid-watch (update/crash/reboot): the daemon may have
        // missed a drop that happened under an older build — push the current
        // state as soon as the poll loop finds the Pi.
        if settings.anchorActive { piService.markConfigDirty() }

        // 1 — SignalK websocket.
        tasks.append(Task { [self] in
            signalK.host                 = settings.signalKHost
            signalK.port                 = settings.signalKPort
            signalK.useTLS               = settings.signalKUseTLS
            signalK.tailscaleHost        = settings.tailscaleHost
            signalK.remoteDomain         = settings.remoteDomain
            signalK.cfAccessClientId     = settings.cfAccessClientId
            signalK.cfAccessClientSecret = CFAccessKeychain.loadSecret() ?? ""
            await signalK.connect()
        })

        // 2 — Pi state polling + bathymetry vessel watch.
        tasks.append(Task { [self] in
            piState.settings = settings
            piState.signalK  = signalK
            piState.start(signalKHost: settings.signalKHost)
            bathymetry.startWatchingVessel(signalK)
        })

        // 3 — 2 s loop: record track + check wind/depth/anchor alarms.
        tasks.append(Task { [self] in
            while !Task.isCancelled {
                anchorWatch.recordPosition(lat: signalK.latitude, lon: signalK.longitude)
                anchorWatch.checkAlarms(signalK: signalK, settings: settings)
                tracks.recordLive(lat: signalK.latitude,
                                  lon: signalK.longitude,
                                  sog: signalK.speedOverGround,
                                  cog: signalK.courseOverGround)
                #if os(macOS)
                heartbeat.beat(watching: settings.anchorActive)
                #endif
                try? await Task.sleep(for: .seconds(2))
            }
        })

        // 4 — Pi daemon heartbeat + remote alarm state (30 s).
        tasks.append(Task { [self] in
            await piService.startMonitoring(settings: settings)
        })

        // 5 — PredictWind auth/status.
        tasks.append(Task { [self] in
            predictWind.signalK = signalK   // follow local↔Tailscale failover
            predictWind.start(settings: settings)
            await predictWind.refreshStatus()
        })

        // 6 — Paired watch bridge (iOS only; WatchConnectivity has no macOS peer).
        #if os(iOS)
        tasks.append(Task { [self] in
            PhoneWatchBridge.shared.start(signalK: signalK, piState: piState)
        })
        #endif

        // 7 — Reconnect immediately on wake/foreground. Sleep kills the
        // WebSocket without a TCP reset; without this nudge the chart sits on
        // a dead socket until the ping watchdog notices (up to ~60 s) — the
        // exact moment the user has just opened the lid and is looking at it.
        #if os(macOS)
        // NSWorkspace notifications arrive on NSWorkspace's own center.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.signalK.nudgeReconnect()
                // Reset the GPS-loss grace window + log the coverage gap —
                // otherwise the loud alarm fires the instant the lid opens.
                self.anchorWatch.noteSystemWake()
                // Fresh heartbeat so the watchdog doesn't read the sleep gap
                // as a main-thread hang.
                self.heartbeat.beat(watching: self.settings.anchorActive)
            }
        }
        // Sleep suspends the watch (the assertion only blocks idle sleep) —
        // tell the crew position monitoring is stopping.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.anchorWatch.noteSystemSleep()
                self?.heartbeat.pause()
            }
        }

        // Main-thread-hang watchdog. If the main actor livelocks (the
        // AttributeGraph-cycle class of bugs), every in-process alarm dies
        // silently while the UI may still LOOK alive. This timer runs on a
        // plain GCD queue and posts a critical notification when the 2 s
        // loop's heartbeat stalls >90 s during an active anchor watch —
        // notificationd plays the sound, independent of our hung process.
        // Re-notifies every 2 min while the hang persists.
        // Timer + handler are built inside Heartbeat (nonisolated) — see the
        // comment there for why building them here would crash.
        watchdog = heartbeat.startWatchdog()
        #else
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.signalK.nudgeReconnect() }
        }
        #endif
    }
}
