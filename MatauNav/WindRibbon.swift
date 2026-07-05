import SwiftUI

// MARK: - WindRibbon
//
// Vertical strip along the right edge of the chart. Each row is a 15 s wind
// sample; oldest at the top, current at the bottom. The arrow points to the
// direction the wind is *going*. Colour stripe encodes TWS:
//   <5 kn → blue, 5–10 → cyan, 10–15 → green, 15–20 → yellow, 20–25 → orange, >25 → red.

struct WindRibbon: View {
    let samples: [SignalKService.WindSample]
    let currentTWD: Double

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let n = max(samples.count, 1)
            let step = h / CGFloat(n)
            ZStack(alignment: .top) {
                Color.black.opacity(0.35)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                ForEach(Array(samples.enumerated()), id: \.offset) { idx, s in
                    let y = step * CGFloat(idx)
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.down")
                            .rotationEffect(.degrees(s.twd - 180))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                        Rectangle()
                            .fill(color(forTWS: s.tws))
                            .frame(width: 4, height: max(2, step - 1))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(y: y)
                }

                // Current TWD readout pinned to bottom
                VStack {
                    Spacer()
                    Text(String(format: "%03.0f°", currentTWD))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color.black.opacity(0.5), in: Capsule())
                        .padding(.bottom, 4)
                }
            }
        }
    }

    private func color(forTWS kn: Double) -> Color {
        switch kn {
        case ..<5:   return .blue
        case ..<10:  return .cyan
        case ..<15:  return .green
        case ..<20:  return .yellow
        case ..<25:  return .orange
        default:     return .red
        }
    }
}
