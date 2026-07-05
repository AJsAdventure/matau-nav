//  AppActivity.swift
//  macOS power-management assertions. On a Mac the app process keeps running
//  while not frontmost (unlike iOS), but the Mac will SLEEP and stop the anchor
//  watch. Hold a sleep-prevention assertion for the duration of an active watch,
//  and a lighter anti-App-Nap assertion while connected so the poll timers stay
//  on schedule when the window isn't focused. No-ops on iOS.

import Foundation

@MainActor
final class AppActivity {
    static let shared = AppActivity()
    private init() {}

    private var sleepToken: (any NSObjectProtocol)?
    private var napToken:   (any NSObjectProtocol)?

    /// Prevent system sleep — the anchor watch must keep checking position.
    func beginAnchorWatch() {
        #if os(macOS)
        guard sleepToken == nil else { return }
        sleepToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Anchor watch active")
        #endif
    }

    func endAnchorWatch() {
        #if os(macOS)
        if let t = sleepToken { ProcessInfo.processInfo.endActivity(t); sleepToken = nil }
        #endif
    }

    /// Keep poll/alarm timers running at full cadence while unfocused.
    func beginBackgroundActivity() {
        #if os(macOS)
        guard napToken == nil else { return }
        napToken = ProcessInfo.processInfo.beginActivity(
            options: [.background],
            reason: "Live boat data + alarm monitoring")
        #endif
    }

    func endBackgroundActivity() {
        #if os(macOS)
        if let t = napToken { ProcessInfo.processInfo.endActivity(t); napToken = nil }
        #endif
    }
}
