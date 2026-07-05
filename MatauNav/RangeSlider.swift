import SwiftUI

// MARK: - RangeSlider
//
// Two-thumb integer slider used by the chart downloader to pick the
// min/max zoom range. SwiftUI's built-in `Slider` only supports a single
// thumb; building one is faster than pulling in a dependency.
//
// The two thumbs cannot cross — `low` is clamped <= `high - 1`.

struct RangeSlider: View {
    @Binding var low: Int
    @Binding var high: Int
    let bounds: ClosedRange<Int>
    var step: Int = 1

    @State private var dragging: Thumb?
    private enum Thumb { case low, high }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let track = max(1, w - thumbSize)
            let span = Double(bounds.upperBound - bounds.lowerBound)
            let lowFrac  = Double(low  - bounds.lowerBound) / span
            let highFrac = Double(high - bounds.lowerBound) / span
            let lowX  = CGFloat(lowFrac)  * track
            let highX = CGFloat(highFrac) * track

            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.bgElevated)
                    .frame(height: 4)
                // Selected segment
                Capsule()
                    .fill(Color.accentCyan)
                    .frame(width: max(0, highX - lowX), height: 4)
                    .offset(x: lowX + thumbSize / 2)
                // Low thumb
                thumb(value: low)
                    .offset(x: lowX)
                    .gesture(makeDrag(track: track, isLow: true))
                // High thumb
                thumb(value: high)
                    .offset(x: highX)
                    .gesture(makeDrag(track: track, isLow: false))
            }
        }
        .frame(height: thumbSize)
    }

    private let thumbSize: CGFloat = 26

    private func thumb(value: Int) -> some View {
        ZStack {
            Circle()
                .fill(Color.accentCyan)
                .frame(width: thumbSize, height: thumbSize)
                .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            Text("\(value)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.black)
        }
    }

    private func makeDrag(track: CGFloat, isLow: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let x = min(track, max(0, g.location.x - thumbSize / 2))
                let span = Double(bounds.upperBound - bounds.lowerBound)
                var v = bounds.lowerBound + Int((Double(x) / Double(track)) * span + 0.5)
                v = (v / step) * step
                if isLow {
                    low = min(v, high - 1)
                } else {
                    high = max(v, low + 1)
                }
            }
    }
}
