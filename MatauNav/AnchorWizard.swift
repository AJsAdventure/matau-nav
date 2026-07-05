import SwiftUI
import CoreLocation

// MARK: - Anchor-set wizard
//
// Walks through dropping the hook the way it actually happens: choose the
// mooring style, drop, fall back paying out rode, then SET — at which point we
// compute the true anchor position from depth + rode rather than trusting the
// GPS point where you happened to let go.
//
//   • Swinging  — single bow anchor, boat weathervanes. Full swing circle whose
//                 radius = horizontal scope (√(rode²−depth²)) + bow offset.
//   • Fixed     — stern anchor / stern-to / two anchors / lines ashore. The boat
//                 is held, so the watch is a tight tolerance box around the
//                 made-fast position, with no swing sector.

struct AnchorWizardSheet: View {
    let settings:    AppSettings
    let signalK:     SignalKService
    let anchorWatch: AnchorWatchService
    /// Called after the watch is armed, with the final anchor/centre coordinate.
    let onComplete:  (CLLocationCoordinate2D) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Step { case type, drop, rode, fixed }
    @State private var step: Step = .type
    @State private var isSwinging = true
    @State private var fixedKind  = "Stern-to"
    @State private var dropCoord:  CLLocationCoordinate2D?
    @State private var dropDepth:  Double = 0
    @State private var rode:       Double = 30
    @State private var tolerance:  Double = 12

    private let fixedKinds = ["Stern-to", "Stern anchor", "Two anchors", "Two buoys", "Lines ashore"]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        switch step {
                        case .type:  typeStep
                        case .drop:  dropStep
                        case .rode:  rodeStep
                        case .fixed: fixedStep
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Set the Anchor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(step == .type ? "Cancel" : "Back") {
                        if step == .type { dismiss() } else { step = .type }
                    }.foregroundStyle(Color.textSecondary)
                }
            }
            .onAppear { rode = settings.anchorRodeLength > 0 ? settings.anchorRodeLength : 30 }
        }
        .presentationBackground(Color.bgPrimary)
        .sheetDetents([.large])
    }

    // MARK: Step 1 — mooring type

    private var typeStep: some View {
        VStack(spacing: 14) {
            Text("How are you anchoring?")
                .font(.title3.weight(.semibold)).foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            typeCard(
                title: "Swinging", icon: "arrow.clockwise.circle.fill",
                blurb: "Single bow anchor. The boat weathervanes around it — a full swing circle sized from your rode and depth.") {
                    isSwinging = true; step = .drop
                }
            typeCard(
                title: "Fixed", icon: "arrow.left.and.right.circle.fill",
                blurb: "Stern anchor, stern-to a quay, two anchors, two buoys or lines ashore. The boat is held, so we watch a tight box around your position.") {
                    isSwinging = false; step = .fixed
                }
        }
    }

    private func typeCard(title: String, icon: String, blurb: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).font(.system(size: 30)).foregroundStyle(Color.statusOrange)
                    .frame(width: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(Color.textPrimary)
                    Text(blurb).font(.caption).foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(Color.textTertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.bgCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.borderColor, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: Step 2 (swinging) — drop

    private var dropStep: some View {
        VStack(spacing: 16) {
            instruction("Motor up to your spot and stop, bow into the wind. Tap the moment the anchor touches the bottom.")
            liveRow
            Button {
                dropCoord = anchorWatch.dropPosition(signalK: signalK, settings: settings)
                dropDepth = signalK.depth
                step = .rode
            } label: {
                bigButton("Anchor Dropped", system: "arrow.down.circle.fill", enabled: hasFix)
            }
            .buttonStyle(.plain).disabled(!hasFix)
            if !hasFix { noFixNote }
        }
    }

    // MARK: Step 3 (swinging) — rode & set

    private var rodeStep: some View {
        let depth = dropDepth > 0 ? dropDepth : signalK.depth
        let scope = AnchorWatchService.horizontalScope(rode: rode, depth: depth)
        let radius = suggestedRadius(scope: scope)
        return VStack(spacing: 16) {
            instruction("Fall back downwind and pay out your rode. Enter how much you let out — we'll size the swing circle from it and the depth.")

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Rode out").font(.subheadline).foregroundStyle(Color.textSecondary)
                    Spacer()
                    Text(String(format: "%.0f m", rode))
                        .font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundStyle(Color.textPrimary)
                }
                Slider(value: $rode, in: 5...120, step: 5).tint(Color.statusOrange)
            }
            .padding(14).background(Color.bgCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: 10) {
                infoStat("DEPTH", depth > 0 ? String(format: "%.1f m", depth) : "—")
                infoStat("SCOPE", depth > 0 ? String(format: "%.1f:1", rode / max(depth, 0.5)) : "—")
                infoStat("RADIUS", String(format: "%.0f m", radius))
            }

            VStack(spacing: 10) {
                Button { finishSwinging(anchorAt: recomputedAnchor(scope: scope), radius: radius) } label: {
                    bigButton("Set — recompute from here", system: "scope", enabled: hasFix)
                }.buttonStyle(.plain).disabled(!hasFix)

                if let dc = dropCoord {
                    Button { finishSwinging(anchorAt: dc, radius: radius) } label: {
                        bigButtonSecondary("Set — anchor where I dropped")
                    }.buttonStyle(.plain)
                }
            }
            Text("Recompute places the anchor up-rode from where you're lying now — the most accurate centre once the chain is stretched.")
                .font(.caption2).foregroundStyle(Color.textTertiary)
        }
    }

    // MARK: Step 2 (fixed) — set

    private var fixedStep: some View {
        VStack(spacing: 16) {
            instruction("Get the boat made fast in its final position — stern lines, second anchor or buoys set. Then set the watch around where you're sitting.")

            VStack(alignment: .leading, spacing: 8) {
                Text("Mooring").font(.caption).foregroundStyle(Color.textSecondary)
                Picker("", selection: $fixedKind) {
                    ForEach(fixedKinds, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu).tint(Color.accentCyan)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(Color.bgCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Allowed movement").font(.subheadline).foregroundStyle(Color.textSecondary)
                    Spacer()
                    Text(String(format: "%.0f m", tolerance))
                        .font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundStyle(Color.textPrimary)
                }
                Slider(value: $tolerance, in: 5...25, step: 1).tint(Color.statusOrange)
            }
            .padding(14).background(Color.bgCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            liveRow
            Button { finishFixed() } label: {
                bigButton("Set Watch", system: "checkmark.circle.fill", enabled: hasFix)
            }.buttonStyle(.plain).disabled(!hasFix)
            if !hasFix { noFixNote }
        }
    }

    // MARK: Shared pieces

    private var hasFix: Bool { signalK.latitude != 0 || signalK.longitude != 0 }

    private var liveRow: some View {
        HStack(spacing: 10) {
            infoStat("DEPTH", signalK.depth > 0 ? String(format: "%.1f m", signalK.depth) : "—")
            infoStat("WIND", String(format: "%.0f kt", signalK.trueWindSpeed))
            infoStat("DIR", String(format: "%03.0f°", signalK.trueWindDirection))
        }
    }

    private var noFixNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusOrange)
            Text("Waiting for a GPS fix from the boat.").font(.caption).foregroundStyle(Color.textSecondary)
        }
    }

    private func instruction(_ s: String) -> some View {
        Text(s).font(.subheadline).foregroundStyle(Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func infoStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundStyle(Color.textPrimary)
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(Color.bgCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func bigButton(_ title: String, system: String, enabled: Bool) -> some View {
        Label(title, systemImage: system)
            .font(.headline).foregroundStyle(.black)
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .background(enabled ? Color.statusOrange : Color.statusOrange.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func bigButtonSecondary(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.statusOrange)
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .background(Color.statusOrange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.statusOrange.opacity(0.35), lineWidth: 1))
    }

    // MARK: Geometry

    private func suggestedRadius(scope: Double) -> Double {
        max(5, min(100, (scope + settings.anchorBowOffset + 6).rounded()))
    }

    /// Anchor projected up-rode from the current position: in the direction the
    /// boat fell back from (toward the drop point), or upwind if we can't tell.
    private func recomputedAnchor(scope: Double) -> CLLocationCoordinate2D {
        let boat = CLLocationCoordinate2D(latitude: signalK.latitude, longitude: signalK.longitude)
        let dist = scope + settings.anchorBowOffset
        var bearing = signalK.trueWindDirection           // wind-from = upwind = toward anchor
        if let dc = dropCoord {
            let toDropM = NavMath.distanceNm(boat, dc) * 1852
            if toDropM > 5 { bearing = NavMath.bearingDeg(boat, dc) }
        }
        return NavMath.destination(from: boat, bearingDeg: bearing, distanceM: dist)
    }

    private func finishSwinging(anchorAt coord: CLLocationCoordinate2D, radius: Double) {
        settings.anchorMooringType = "swinging"
        settings.anchorRodeLength  = rode
        settings.anchorRadius      = radius
        settings.anchorWarnRadius  = 0    // auto (75 %)
        settings.anchorLat = coord.latitude
        settings.anchorLon = coord.longitude
        anchorWatch.dropAnchor(settings: settings, signalK: signalK)
        settings.persist()
        onComplete(coord)
        dismiss()
    }

    private func finishFixed() {
        let center = CLLocationCoordinate2D(latitude: signalK.latitude, longitude: signalK.longitude)
        settings.anchorMooringType = "fixed"
        settings.anchorRadius      = tolerance
        settings.anchorWarnRadius  = max(3, tolerance - 4)
        settings.anchorLat = center.latitude
        settings.anchorLon = center.longitude
        anchorWatch.dropAnchor(settings: settings, signalK: signalK)
        settings.persist()
        onComplete(center)
        dismiss()
    }
}
