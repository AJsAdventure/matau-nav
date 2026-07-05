import SwiftUI

extension Color {
    static let bgPrimary    = Color(red: 0.024, green: 0.051, blue: 0.094)   // #060D18
    static let bgCard       = Color(red: 0.047, green: 0.094, blue: 0.157)   // #0C1828
    static let bgElevated   = Color(red: 0.071, green: 0.125, blue: 0.196)   // #122032
    static let borderColor  = Color(red: 0.118, green: 0.188, blue: 0.267)   // #1E3044
    static let accentCyan   = Color(red: 0.000, green: 0.808, blue: 0.871)   // #00CEDF
    static let statusGreen  = Color(red: 0.000, green: 0.831, blue: 0.541)   // #00D48A
    static let statusOrange = Color(red: 1.000, green: 0.702, blue: 0.000)   // #FFB300
    static let statusRed    = Color(red: 1.000, green: 0.231, blue: 0.188)   // #FF3B30
    static let textPrimary  = Color.white
    static let textSecondary = Color(red: 0.376, green: 0.482, blue: 0.588)  // #607B96
    static let textTertiary  = Color(red: 0.239, green: 0.333, blue: 0.439)  // #3D5570
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .background(Color.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.borderColor, lineWidth: 0.5)
            )
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardModifier())
    }
}

struct SectionHeaderModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(Color.textSecondary)
            .textCase(.uppercase)
            .tracking(0.8)
    }
}

extension View {
    func sectionHeader() -> some View {
        modifier(SectionHeaderModifier())
    }
}

// MARK: - Anchor glyph
//
// SF Symbols has no "anchor", so we draw one. Strokes inherit the ambient
// foregroundStyle, so it colours like an SF Symbol would. Scales to its frame.
struct AnchorMark: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let lw = max(1.2, s * 0.11)
            let cx = s * 0.5
            let ringR = s * 0.10
            let ringCY = s * 0.14
            Path { p in
                // Ring (the shackle at the top)
                p.addEllipse(in: CGRect(x: cx - ringR, y: ringCY - ringR,
                                        width: ringR * 2, height: ringR * 2))
                // Shank (vertical bar)
                p.move(to: CGPoint(x: cx, y: ringCY + ringR))
                p.addLine(to: CGPoint(x: cx, y: s * 0.82))
                // Stock (horizontal crossbar)
                p.move(to: CGPoint(x: cx - s * 0.20, y: s * 0.33))
                p.addLine(to: CGPoint(x: cx + s * 0.20, y: s * 0.33))
                // Flukes / arms curving up from the crown
                p.move(to: CGPoint(x: cx, y: s * 0.82))
                p.addQuadCurve(to: CGPoint(x: cx - s * 0.30, y: s * 0.58),
                               control: CGPoint(x: cx - s * 0.20, y: s * 0.86))
                p.move(to: CGPoint(x: cx, y: s * 0.82))
                p.addQuadCurve(to: CGPoint(x: cx + s * 0.30, y: s * 0.58),
                               control: CGPoint(x: cx + s * 0.20, y: s * 0.86))
            }
            .stroke(style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
            .frame(width: s, height: s)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
