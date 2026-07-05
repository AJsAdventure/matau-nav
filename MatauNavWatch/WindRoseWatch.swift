import SwiftUI

/// Stripped-down compass rose for the watch. Matches the iPhone aesthetic
/// (cyan major ticks, no-go zone, T marker, boat V) but at a smaller scale
/// and with the autopilot lock readout in the centre instead of a pill.
struct WindRoseWatch: View {
    let heading: Double
    let trueWindAngle: Double
    let apparentWindAngle: Double?
    let rudderAngle: Double
    let centerText: String
    let centerColor: Color

    var body: some View {
        ZStack {
            // 1. Rotating ring (ticks + no-go zone)
            Canvas { ctx, size in
                var c = ctx
                drawRing(ctx: &c, size: size)
            }
            .rotationEffect(.degrees(-heading))
            .animation(.easeOut(duration: 0.35), value: heading)

            // 2. Cardinal labels (upright)
            CompassLabelsWatch(heading: heading)

            // 3. True wind T marker
            TrueWindMarkerWatch(trueWindAngle: trueWindAngle, heading: heading)

            // 4. Apparent wind tick (small orange triangle on outer ring)
            if let awa = apparentWindAngle {
                ApparentWindMarkerWatch(apparentWindAngle: awa)
            }

            // 5. Boat V + rudder bar (fixed)
            let rud = rudderAngle
            Canvas { ctx, size in
                var c = ctx
                drawBoat(ctx: &c, size: size)
                drawRudder(ctx: &c, size: size, rudderAngle: rud)
            }

            // 6. Centre: AP lock readout (no pill — bigger, monospaced)
            Text(centerText)
                .font(.system(size: 22, weight: .heavy, design: .monospaced))
                .foregroundStyle(centerColor)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }

    // MARK: Ring
    private func drawRing(ctx: inout GraphicsContext, size: CGSize) {
        let cx = size.width / 2, cy = size.height / 2
        let r       = min(cx, cy)
        let outerR  = r * 0.98
        let innerR  = r * 0.66
        let ringW   = outerR - innerR

        var ring = Path()
        ring.addArc(center: .init(x: cx, y: cy), radius: outerR, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
        ring.addArc(center: .init(x: cx, y: cy), radius: innerR, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: true)
        ctx.fill(ring, with: .color(Color(white: 0.14)))

        // No-go zone (TWD ±45°, fade to ±55°)
        let twdDeg = heading + trueWindAngle - 90
        let nogoInner = innerR + ringW * 0.05
        let nogoOuter = innerR + ringW * 0.25

        var nogo = Path()
        nogo.addArc(center: .init(x: cx, y: cy), radius: nogoOuter,
                    startAngle: .degrees(twdDeg - 45), endAngle: .degrees(twdDeg + 45), clockwise: false)
        nogo.addArc(center: .init(x: cx, y: cy), radius: nogoInner,
                    startAngle: .degrees(twdDeg + 45), endAngle: .degrees(twdDeg - 45), clockwise: true)
        nogo.closeSubpath()
        ctx.fill(nogo, with: .color(Color.statusRed.opacity(0.40)))

        // Borders
        for (rad, w) in [(outerR, 1.0), (innerR, 0.5)] {
            var c = Path()
            c.addArc(center: .init(x: cx, y: cy), radius: rad, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
            ctx.stroke(c, with: .color(Color(white: 0.25)), lineWidth: w)
        }

        // Tick marks
        let tLen = ringW * 0.32
        for i in 0..<36 {
            let deg   = Double(i * 10)
            let rad   = (deg - 90) * .pi / 180
            let major = i % 3 == 0
            let op    = CGPoint(x: cx + (outerR - 2) * cos(rad), y: cy + (outerR - 2) * sin(rad))
            let ip    = CGPoint(x: cx + (outerR - tLen) * cos(rad), y: cy + (outerR - tLen) * sin(rad))
            var tick  = Path(); tick.move(to: op); tick.addLine(to: ip)
            ctx.stroke(tick, with: .color(major ? Color.accentCyan.opacity(0.7) : Color(white: 0.30)),
                       lineWidth: major ? 1.2 : 0.7)
        }
    }

    // MARK: Boat V (no rudder bar on watch — saves vertical space)
    private func drawBoat(ctx: inout GraphicsContext, size: CGSize) {
        let cx = size.width / 2, cy = size.height / 2
        let r      = min(cx, cy)
        let innerR = r * 0.66

        let bowY   = cy - innerR * 0.50
        let spread = innerR * 0.34
        let armY   = cy + innerR * 0.30

        var port = Path()
        port.move(to: .init(x: cx, y: bowY))
        port.addQuadCurve(to:      .init(x: cx - spread, y: armY),
                          control: .init(x: cx - spread * 0.85, y: bowY + (armY - bowY) * 0.12))
        ctx.stroke(port, with: .linearGradient(
            Gradient(colors: [Color.statusRed, Color.statusRed.opacity(0.06)]),
            startPoint: .init(x: cx, y: bowY), endPoint: .init(x: cx - spread, y: armY)
        ), lineWidth: 1.8)

        var sb = Path()
        sb.move(to: .init(x: cx, y: bowY))
        sb.addQuadCurve(to:      .init(x: cx + spread, y: armY),
                        control: .init(x: cx + spread * 0.85, y: bowY + (armY - bowY) * 0.12))
        ctx.stroke(sb, with: .linearGradient(
            Gradient(colors: [Color.statusGreen, Color.statusGreen.opacity(0.06)]),
            startPoint: .init(x: cx, y: bowY), endPoint: .init(x: cx + spread, y: armY)
        ), lineWidth: 1.8)

        var bow = Path()
        bow.addEllipse(in: CGRect(x: cx - 2.5, y: bowY - 2.5, width: 5, height: 5))
        ctx.fill(bow, with: .color(Color.white.opacity(0.85)))
    }

    // MARK: Rudder bar — matches the iPhone autopilot view
    private func drawRudder(ctx: inout GraphicsContext, size: CGSize, rudderAngle: Double) {
        let cx = size.width / 2, cy = size.height / 2
        let r      = min(cx, cy)
        let innerR = r * 0.66

        let barCY    = cy + innerR * 0.58
        let barHW    = innerR * 0.30
        let barH: CGFloat = 4.0
        let maxAng   = 35.0

        var bg = Path()
        bg.addRoundedRect(in: CGRect(x: cx - barHW, y: barCY - barH / 2, width: barHW * 2, height: barH),
                          cornerSize: CGSize(width: 1.5, height: 1.5))
        ctx.fill(bg, with: .color(Color(white: 0.16)))

        let clamped = max(-maxAng, min(maxAng, rudderAngle))
        let fillW   = barHW * CGFloat(abs(clamped) / maxAng)
        if fillW > 0.5 {
            let color = clamped > 0 ? Color.statusGreen : Color.statusRed
            let fillX = clamped > 0 ? cx : cx - fillW
            var fill  = Path()
            fill.addRect(CGRect(x: fillX, y: barCY - barH / 2, width: fillW, height: barH))
            ctx.fill(fill, with: .color(color.opacity(0.9)))
        }

        var notch = Path()
        notch.move(to: CGPoint(x: cx, y: barCY - barH - 1))
        notch.addLine(to: CGPoint(x: cx, y: barCY + barH + 1))
        ctx.stroke(notch, with: .color(Color(white: 0.52)), lineWidth: 0.8)
    }
}

private struct CompassLabelsWatch: View {
    let heading: Double
    var body: some View {
        GeometryReader { geo in
            let cx     = geo.size.width  / 2
            let cy     = geo.size.height / 2
            let r      = min(cx, cy)
            let outerR = r * 0.98
            let innerR = r * 0.66
            let labelR = outerR - (outerR - innerR) * 0.55

            ForEach([0, 3, 6, 9], id: \.self) { i in
                let compassDeg  = Double(i * 30)
                let screenAngle = (compassDeg - heading - 90) * .pi / 180
                let lx = cx + labelR * cos(screenAngle)
                let ly = cy + labelR * sin(screenAngle)
                let label: String = ["N","E","S","W"][i / 3]
                Text(label)
                    .font(.system(size: r * 0.13, weight: .bold))
                    .foregroundStyle(Color(white: 0.94))
                    .position(x: lx, y: ly)
            }
        }
        .animation(.easeOut(duration: 0.35), value: heading)
    }
}

private struct TrueWindMarkerWatch: View {
    let trueWindAngle: Double
    let heading: Double
    var body: some View {
        GeometryReader { geo in
            let size   = min(geo.size.width, geo.size.height)
            let r      = size / 2
            let outerR = r * 0.98
            let innerR = r * 0.66
            let mR     = outerR - (outerR - innerR) * 0.50

            let twd       = (heading + trueWindAngle + 360).truncatingRemainder(dividingBy: 360)
            let screenDeg = twd - heading
            let screenRad = (screenDeg - 90) * Double.pi / 180
            let mx = geo.size.width  / 2 + mR * cos(screenRad)
            let my = geo.size.height / 2 + mR * sin(screenRad)

            ZStack {
                TriangleWatch()
                    .fill(Color(red: 0.18, green: 0.38, blue: 0.92))
                    .frame(width: size * 0.10, height: size * 0.10)
                    .rotationEffect(.degrees(screenDeg + 180))
                    .position(x: mx, y: my)
                Text("T")
                    .font(.system(size: size * 0.045, weight: .black))
                    .foregroundStyle(.white)
                    .position(x: mx, y: my)
            }
        }
    }
}

private struct ApparentWindMarkerWatch: View {
    let apparentWindAngle: Double
    var body: some View {
        GeometryReader { geo in
            let size   = min(geo.size.width, geo.size.height)
            let r      = size / 2
            let outerR = r * 0.98
            let innerR = r * 0.66
            let mR     = outerR - (outerR - innerR) * 0.15
            let rad    = (apparentWindAngle - 90) * Double.pi / 180
            let mx = geo.size.width  / 2 + mR * cos(rad)
            let my = geo.size.height / 2 + mR * sin(rad)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: size * 0.06))
                .foregroundStyle(Color.statusOrange)
                .rotationEffect(.degrees(apparentWindAngle))
                .position(x: mx, y: my)
        }
    }
}

private struct TriangleWatch: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}
