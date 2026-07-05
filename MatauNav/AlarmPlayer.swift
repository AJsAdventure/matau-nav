import AVFoundation
#if os(macOS)
import AppKit
#endif

// Plays a loud two-tone alarm.
// iOS: AVAudioSession .playback bypasses the mute switch (same as music apps).
// macOS: no audio session exists / is needed; AVAudioPlayer plays directly, and
// we additionally bounce the Dock icon until the user acknowledges so a drag
// alarm is impossible to miss when the window is minimised or in the background.
@MainActor
final class AlarmPlayer {

    static let shared = AlarmPlayer()

    private var player: AVAudioPlayer?
    /// True only while the player is genuinely emitting audio. An audio-session
    /// interruption (phone call, Siri, another app grabbing playback) stops the
    /// AVAudioPlayer silently — if this kept reporting true, the alarm loops
    /// (which call start() again whenever it reads false, every ~2 s) could
    /// never restart it and a "ringing" alarm would be mute. Deriving it from
    /// the player makes an interrupted alarm self-heal on the next loop tick.
    var isPlaying: Bool { wantsPlaying && (player?.isPlaying ?? false) }
    private var wantsPlaying = false
    #if os(macOS)
    private var attentionRequest: Int?
    #endif

    func start() {
        guard !isPlaying else { return }
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            player = try AVAudioPlayer(data: makeAlarmWAV())
            player?.numberOfLoops = -1
            player?.volume = 1.0
            player?.play()
            wantsPlaying = true
            #if os(macOS)
            // .criticalRequest bounces the Dock icon until the app is activated.
            attentionRequest = NSApp.requestUserAttention(.criticalRequest)
            #endif
        } catch {
            print("[AlarmPlayer] start failed: \(error)")
        }
    }

    func stop() {
        guard wantsPlaying || player != nil else { return }
        player?.stop()
        player = nil
        wantsPlaying = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #elseif os(macOS)
        if let r = attentionRequest { NSApp.cancelUserAttentionRequest(r); attentionRequest = nil }
        #endif
    }

    // MARK: - Tone generation

    // Two-tone pattern: 880 Hz for 0.5 s, 660 Hz for 0.5 s, silence 0.5 s
    private func makeAlarmWAV() -> Data {
        let rate   = 22050
        let total  = Int(Double(rate) * 1.5)
        var samples = [Int16](repeating: 0, count: total)

        for i in 0..<total {
            let t    = Double(i) / Double(rate)
            let freq = t < 0.5 ? 880.0 : t < 1.0 ? 660.0 : 0.0
            if freq > 0 {
                // Short fade-in/out at segment edges to remove clicks
                let edge   = min(t.truncatingRemainder(dividingBy: 0.5), 0.5 - t.truncatingRemainder(dividingBy: 0.5))
                let env    = min(1.0, edge * 40.0)
                samples[i] = Int16(clamping: Int(28000.0 * env * sin(2.0 * .pi * freq * t)))
            }
        }

        return wavData(samples: samples, sampleRate: UInt32(rate))
    }

    private func wavData(samples: [Int16], sampleRate: UInt32) -> Data {
        var d = Data()
        d.reserveCapacity(44 + samples.count * 2)

        func w32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func w16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        let dataBytes = UInt32(samples.count * 2)
        d.append(contentsOf: "RIFF".utf8); w32(36 + dataBytes)
        d.append(contentsOf: "WAVE".utf8)
        d.append(contentsOf: "fmt ".utf8)
        w32(16); w16(1); w16(1); w32(sampleRate); w32(sampleRate * 2); w16(2); w16(16)
        d.append(contentsOf: "data".utf8); w32(dataBytes)
        for s in samples { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }
}
