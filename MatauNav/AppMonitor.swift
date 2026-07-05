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

    /// Launch every monitoring loop exactly once. Safe to call repeatedly
    /// (e.g. each time the window reopens) — only the first call does work.
    func start() {
        guard !started else { return }
        started = true

        // Keep poll/alarm timers at full cadence when the app is unfocused.
        AppActivity.shared.beginBackgroundActivity()

        // Ask for notification permission up front so anchor-drag alarms land.
        anchorWatch.requestPermissions()

        // 1 — SignalK websocket.
        tasks.append(Task { [self] in
            signalK.host   = settings.signalKHost
            signalK.port   = settings.signalKPort
            signalK.useTLS = settings.signalKUseTLS
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
                try? await Task.sleep(for: .seconds(2))
            }
        })

        // 4 — Pi daemon heartbeat + remote alarm state (30 s).
        tasks.append(Task { [self] in
            await piService.startMonitoring(settings: settings)
        })

        // 5 — PredictWind auth/status.
        tasks.append(Task { [self] in
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
            Task { @MainActor in self?.signalK.nudgeReconnect() }
        }
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
