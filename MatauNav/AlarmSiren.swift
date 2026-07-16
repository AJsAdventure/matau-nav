//  AlarmSiren.swift
//  Referee between the independent alarm sources and the single AlarmPlayer.
//
//  Why: AnchorWatchService (drag / GPS-loss) and AnchorPiService (Pi-down)
//  each used to call AlarmPlayer.start()/stop() directly. Whoever stopped
//  last won — a Pi reconnect could silence a live drag alarm (mitigated only
//  by the 2 s self-heal re-arm), and there was no record of who was ringing.
//  This is a refcount: the siren sounds while ANY source holds it, and one
//  source releasing can never cut off another.

import Foundation

@MainActor
final class AlarmSiren {

    static let shared = AlarmSiren()

    /// Sources currently demanding the loud alarm (e.g. "anchor-watch",
    /// "pi-daemon"). Exposed for provenance — the UI/logs can say WHO rings.
    private(set) var holders: Set<String> = []

    /// Idempotent; callers re-invoke on their check cadence (~2 s), which
    /// doubles as the self-heal: if the underlying player was interrupted,
    /// isPlaying reads false and it restarts here.
    func acquire(_ source: String) {
        holders.insert(source)
        #if os(macOS)
        // A muted / turned-down Mac must not sleep through a ringing alarm —
        // while the siren is demanded, keep the output unmuted and above a
        // volume floor (~2 s cadence). Snooze is the sanctioned silence.
        SystemAudio.ensureAudible()
        #endif
        if !AlarmPlayer.shared.isPlaying { AlarmPlayer.shared.start() }
    }

    func release(_ source: String) {
        guard holders.contains(source) else { return }
        holders.remove(source)
        if holders.isEmpty { AlarmPlayer.shared.stop() }
    }
}
