//  SystemHealth.swift
//  Aggregated connection health across every boat-side dependency.
//
//  Why: the sidebar/menu-bar used to show only the SignalK state — the AIS/
//  CPA feed (PiStateService), the anchor daemon, and PredictWind could all be
//  down behind a green "Connected" chip. One aggregate keeps silent
//  degradation visible without adding a dashboard.

import Foundation

struct SystemHealthIssue: Identifiable, Equatable {
    let id: String       // subsystem name, e.g. "Boat state"
    let detail: String
}

enum SystemHealth {

    /// Current problems, worst-first. Empty = everything the user has
    /// configured is reachable. Deliberately conservative: subsystems the
    /// user hasn't configured/enabled don't nag.
    @MainActor
    static func issues(signalK: SignalKService,
                       piState: PiStateService,
                       piService: AnchorPiService,
                       predictWind: PredictWindService,
                       settings: AppSettings) -> [SystemHealthIssue] {
        var out: [SystemHealthIssue] = []
        if !signalK.state.isConnected {
            out.append(.init(id: "SignalK", detail: signalK.state.label))
        }
        if !piState.connected {
            out.append(.init(id: "Boat state", detail: "AIS/route feed offline"))
        }
        // Anchor daemon matters whenever it is configured and has ever been
        // seen; while actively anchored it is safety-relevant.
        if piService.connectionState == .disconnected {
            out.append(.init(id: "Anchor daemon", detail: "Pi daemon unreachable"))
        }
        if settings.chartShowPredictWindAIS || settings.forecastAlarmEnabled {
            if case .failed(let msg) = predictWind.status {
                out.append(.init(id: "PredictWind", detail: msg))
            }
        }
        return out
    }
}
