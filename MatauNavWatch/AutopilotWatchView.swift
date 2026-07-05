import SwiftUI
import WatchKit

struct AutopilotWatchView: View {
    @Environment(WatchPiClient.self) private var pi

    var body: some View {
        ZStack {
            Color.bgPrimary.ignoresSafeArea()

            // Bottom heading buttons sit over the rose, which fills the
            // remaining vertical space.
            GeometryReader { geo in
                let w = geo.size.width
                // Extend layout into the bottom safe-area inset so the action
                // row can sit 30pt lower than the safe area would normally
                // allow — gives the rose more vertical real estate.
                let h = geo.size.height + bottomOverflow
                let bottomRowTop = h - buttonHeight - bottomMargin
                // Rose sits 30pt from the top of the screen and leaves a 5pt
                // gap above the button row.
                let rose = min(w, max(80, bottomRowTop - roseTopInset - roseBottomGap))
                let roseCenterY = roseTopInset + rose / 2

                // Rose centred in the area above the bottom button row.
                WindRoseWatch(
                    heading: pi.heading,
                    trueWindAngle: pi.trueWindAngle,
                    apparentWindAngle: nil,
                    rudderAngle: pi.rudderAngle,
                    centerText: centerText,
                    centerColor: centerColor
                )
                .frame(width: rose, height: rose)
                .position(x: w / 2, y: roseCenterY)

                // Bottom action row — three equal-width buttons centred at the
                // very bottom edge so the rose gets every available pixel
                // above it.
                HStack(spacing: 6) {
                    TurnButton(direction: .left,  pi: pi)
                    EngageButton(pi: pi)
                    TurnButton(direction: .right, pi: pi)
                }
                .position(x: w / 2, y: h - buttonHeight / 2 - bottomMargin)
            }
        }
        .navigationBarHidden(true)
    }

    /// Bottom button row metrics. Buttons sit ~4pt from the bottom edge so
    /// the rose can grow as large as possible above them.
    private var buttonHeight: CGFloat { 40 }
    private var bottomMargin: CGFloat { 4 }
    /// Pulls the action row 40pt into the bottom safe-area inset.
    private var bottomOverflow: CGFloat { 40 }
    /// Distance from the top of the screen to the top of the rose. Negative
    /// values let the rose extend above the visible top edge.
    private var roseTopInset: CGFloat { -30 }
    /// Gap between the bottom of the rose and the top of the button row.
    private var roseBottomGap: CGFloat { 10 }


    // MARK: Center readout

    /// Standby → live heading.
    /// Compass engaged → target heading.
    /// Wind engaged → locked wind angle as "54°P" / "54°S".
    private var centerText: String {
        if pi.apEngaged {
            if pi.apMode == "wind", let w = pi.lockedWindAngle {
                let side = w >= 0 ? "S" : "P"
                return "\(Int(abs(w).rounded()))°\(side)"
            }
            return String(format: "%03.0f°", pi.targetHeading)
        }
        return String(format: "%03.0f°", pi.heading)
    }

    private var centerColor: Color {
        if !pi.apEngaged { return .textPrimary }
        return pi.apMode == "wind" ? .statusOrange : .accentCyan
    }
}

// MARK: - Turn buttons (tap = 1°, long-press = 10°)

private struct TurnButton: View {
    enum Direction { case left, right }
    let direction: Direction
    let pi: WatchPiClient

    @State private var flash = false

    private var tint: Color { direction == .left ? .statusRed : .statusGreen }
    private var symbol: String { direction == .left ? "chevron.left" : "chevron.right" }
    private var oneDegCmd: String { direction == .left ? "minus1" : "plus1" }
    private var tenDegCmd: String { direction == .left ? "minus10" : "plus10" }

    var body: some View {
        let disabled = !pi.apEngaged || pi.commandPending
        let effective = disabled ? Color.textTertiary : tint
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(effective.opacity(flash ? 0.30 : 0.12))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(effective.opacity(0.45), lineWidth: 1)
            // Chevron stays where it was when the button was 56pt wide —
            // shift it back toward the centre of the watch so the extra 20pt
            // grows outward (left button extends left, right extends right).
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(effective)
                .offset(x: direction == .left ? 10 : -10)
        }
        .frame(width: 76, height: 40)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .gesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    guard !disabled else { return }
                    pulse()
                    WKHaptic.success()
                    Task { await pi.sendCommand(tenDegCmd) }
                }
                .exclusively(before:
                    TapGesture().onEnded {
                        guard !disabled else { return }
                        pulse()
                        WKHaptic.click()
                        Task { await pi.sendCommand(oneDegCmd) }
                    }
                )
        )
        .allowsHitTesting(!disabled)
        .opacity(disabled ? 0.55 : 1)
    }

    private func pulse() {
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeOut(duration: 0.15)) { flash = false }
        }
    }
}

// MARK: - Engage / Standby

private struct EngageButton: View {
    let pi: WatchPiClient

    var body: some View {
        Button {
            Task {
                if pi.apEngaged {
                    await pi.sendCommand("standby")
                } else {
                    // Engage in compass mode by default — matches the iPhone
                    // engage flow's safe choice when the user hasn't picked wind.
                    await pi.sendCommand("compass_auto")
                }
            }
        } label: {
            ZStack {
                if pi.commandPending {
                    ProgressView()
                        .progressViewStyle(.circular)
                } else {
                    VStack(spacing: 1) {
                        Text(pi.apEngaged ? "STBY" : "AUTO")
                            .font(.system(size: 11, weight: .bold))
                        Circle()
                            .fill(pi.apEngaged ? Color.statusGreen : Color.textTertiary)
                            .frame(width: 5, height: 5)
                    }
                }
            }
            .frame(width: 56, height: 40)
            .background(pi.apEngaged ? Color.statusGreen.opacity(0.18) : Color.bgElevated)
            .foregroundStyle(pi.apEngaged ? Color.statusGreen : Color.textSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(pi.apEngaged ? Color.statusGreen.opacity(0.5) : Color.borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(pi.commandPending)
    }
}

// MARK: - Haptics

enum WKHaptic {
    static func click()   { WKInterfaceDevice.current().play(.click) }
    static func success() { WKInterfaceDevice.current().play(.success) }
}
