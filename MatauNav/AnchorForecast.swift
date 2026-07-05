import SwiftUI

// MARK: - "Safe Tonight?" forecast verdict
//
// Turns a raw PredictWind forecast into a single glanceable go/caution/no-go
// call for the hours ahead at anchor — the thing cruisers actually want to know
// from the bunk: "is it going to be a rough night on the hook?"

enum AnchorForecastRating: Sendable {
    case good, caution, rough, unknown

    var word: String {
        switch self {
        case .good:    "CALM"
        case .caution: "WATCH"
        case .rough:   "ROUGH"
        case .unknown: "—"
        }
    }
    var color: Color {
        switch self {
        case .good:    .statusGreen
        case .caution: .statusOrange
        case .rough:   .statusRed
        case .unknown: .textTertiary
        }
    }
    var icon: String {
        switch self {
        case .good:    "checkmark.seal.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .rough:   "wind"
        case .unknown: "questionmark.circle"
        }
    }
}

struct AnchorForecastVerdict {
    let rating:   AnchorForecastRating
    let headline: String
    let reasons:  [String]
    let maxWind:  Int?
    let maxGust:  Int?
    let dirSpread: Int?          // degrees the wind direction sweeps over the window
    let hours:    [ForecastPoint]

    var word:  String { rating.word }
    var color: Color  { rating.color }

    struct ForecastPoint: Identifiable {
        let id: Int
        let label: String        // "21h"
        let wind:  Int
        let gust:  Int?
        let dir:   Int?
        let over:  Bool          // wind exceeds the user's threshold this hour
    }
}

enum AnchorForecast {

    /// Build a verdict from the most recently fetched forecast for the window
    /// `settings.forecastAlarmHoursAhead` hours ahead.
    @MainActor
    static func verdict(forecast: PWForecast?, settings: AppSettings,
                        now: Date = Date()) -> AnchorForecastVerdict {
        guard let f = forecast, !f.hours.isEmpty else {
            return .init(rating: .unknown, headline: "No forecast yet",
                         reasons: ["Connect PredictWind in Setup, then open this from anchor."],
                         maxWind: nil, maxGust: nil, dirSpread: nil, hours: [])
        }

        let windThresh = settings.forecastAlarmMaxWindKn
        let horizon    = now.addingTimeInterval(Double(settings.forecastAlarmHoursAhead) * 3600)

        // Indices of the hours that fall inside our window.
        let nowTs = Int(now.timeIntervalSince1970)
        let endTs = Int(horizon.timeIntervalSince1970)
        let idx   = f.hours.enumerated()
            .filter { $0.element.unixTimestamp >= nowTs - 3600 && $0.element.unixTimestamp <= endTs }
            .map { $0.offset }
        guard !idx.isEmpty else {
            return .init(rating: .unknown, headline: "Forecast out of range",
                         reasons: ["No forecast hours in the next \(settings.forecastAlarmHoursAhead) h."],
                         maxWind: nil, maxGust: nil, dirSpread: nil, hours: [])
        }

        let speed = series(f, matching: ["speed", "wind"], excluding: ["gust", "dir"])
        let gust  = series(f, matching: ["gust"], excluding: [])
        let dir   = series(f, matching: ["dir"], excluding: [])

        func at(_ s: [Int]?, _ i: Int) -> Int? { (s != nil && i < s!.count) ? s![i] : nil }

        var winds: [Int] = [], gusts: [Int] = [], dirs: [Int] = []
        var points: [AnchorForecastVerdict.ForecastPoint] = []
        for i in idx {
            let w = at(speed, i) ?? 0
            let g = at(gust, i)
            let d = at(dir, i)
            winds.append(w)
            if let g { gusts.append(g) }
            if let d { dirs.append(d) }
            points.append(.init(id: f.hours[i].unixTimestamp,
                                label: f.hours[i].hour,
                                wind: w, gust: g, dir: d,
                                over: Double(w) >= windThresh))
        }

        let maxWind = winds.max() ?? 0
        let maxGust = gusts.max()
        let dirSpread = circularSpread(dirs)

        // Reasons + rating
        var reasons: [String] = []
        var rating: AnchorForecastRating = .good

        if Double(maxWind) >= windThresh * 1.25 {
            rating = .rough
            reasons.append("Sustained wind to \(maxWind) kt — above your \(Int(windThresh)) kt limit.")
        } else if Double(maxWind) >= windThresh * 0.8 {
            rating = max(rating, .caution)
            reasons.append("Wind building to \(maxWind) kt.")
        } else {
            reasons.append("Wind stays light — peak \(maxWind) kt.")
        }

        if let mg = maxGust {
            if Double(mg) >= windThresh * 1.5 {
                rating = .rough
                reasons.append("Gusts to \(mg) kt\(gustTimeSuffix(points)).")
            } else if Double(mg) >= windThresh {
                rating = max(rating, .caution)
                reasons.append("Gusts near \(mg) kt\(gustTimeSuffix(points)).")
            }
        }

        if let spread = dirSpread {
            if spread >= 120 {
                rating = max(rating, .caution)
                reasons.append("Wind swings \(spread)° overnight — make sure there's room all around.")
            } else if spread <= 30 {
                reasons.append("Wind direction steady (\(spread)° sweep).")
            }
        }

        let headline: String = switch rating {
        case .good:    "Settled night on the hook"
        case .caution: "Workable, but keep an eye out"
        case .rough:   "Rough night — consider a better-protected spot"
        case .unknown: "—"
        }

        return .init(rating: rating, headline: headline, reasons: reasons,
                     maxWind: maxWind, maxGust: maxGust, dirSpread: dirSpread, hours: points)
    }

    // MARK: helpers

    private static func series(_ f: PWForecast, matching: [String], excluding: [String]) -> [Int]? {
        // Prefer the first source's matching series.
        for s in f.series {
            let t = s.title.lowercased()
            let hit = matching.contains { t.contains($0) }
            let bad = excluding.contains { t.contains($0) }
            if hit && !bad { return s.data }
        }
        return nil
    }

    private static func gustTimeSuffix(_ points: [AnchorForecastVerdict.ForecastPoint]) -> String {
        guard let peak = points.max(by: { ($0.gust ?? 0) < ($1.gust ?? 0) }), peak.gust != nil
        else { return "" }
        return " around \(peak.label)"
    }

    /// Spread of compass directions accounting for the 0/360 wrap.
    private static func circularSpread(_ degs: [Int]) -> Int? {
        guard degs.count >= 2 else { return nil }
        let rads = degs.map { Double($0) * .pi / 180 }
        // Find the gap-complement: the largest empty arc, spread = 360 - gap.
        let sorted = rads.map { ($0.truncatingRemainder(dividingBy: 2 * .pi) + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi) }.sorted()
        var maxGap = (sorted.first! + 2 * .pi) - sorted.last!
        for i in 1..<sorted.count { maxGap = Swift.max(maxGap, sorted[i] - sorted[i-1]) }
        let spread = (2 * .pi - maxGap) * 180 / .pi
        return Int(spread.rounded())
    }
}

private extension AnchorForecastRating {
    static func max(_ a: AnchorForecastRating, _ b: AnchorForecastRating) -> AnchorForecastRating {
        func rank(_ r: AnchorForecastRating) -> Int {
            switch r { case .good: 0; case .caution: 1; case .rough: 2; case .unknown: -1 }
        }
        return rank(a) >= rank(b) ? a : b
    }
}

// Free function so call sites can write `max(ratingA, ratingB)`.
func max(_ a: AnchorForecastRating, _ b: AnchorForecastRating) -> AnchorForecastRating {
    AnchorForecastRating.max(a, b)
}

// MARK: - Safe Tonight sheet

struct SafeTonightSheet: View {
    let settings:    AppSettings
    let predictWind: PredictWindService
    let anchorLat:   Double
    let anchorLon:   Double

    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var verdict: AnchorForecastVerdict?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        if loading && verdict == nil {
                            ProgressView("Reading the sky…")
                                .tint(Color.accentCyan)
                                .foregroundStyle(Color.textSecondary)
                                .padding(.top, 60)
                        } else if let v = verdict {
                            verdictCard(v)
                            if !v.hours.isEmpty { hourStrip(v) }
                            reasonsCard(v)
                        }
                        thresholdsNote
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Safe Tonight?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if predictWind.status.isOK {
                        Image(systemName: "checkmark.icloud").foregroundStyle(Color.statusGreen)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Color.accentCyan)
                }
            }
        }
        .presentationBackground(Color.bgPrimary)
        .sheetDetents([.medium, .large])
        .task { await load() }
    }

    private func load() async {
        loading = true
        // Use cached forecast immediately if present, then refresh.
        verdict = AnchorForecast.verdict(forecast: predictWind.forecast, settings: settings)
        if anchorLat != 0 || anchorLon != 0, predictWind.status.isOK {
            if let id = await predictWind.setForecastLocation(lat: anchorLat, lon: anchorLon),
               let f = await predictWind.fetchForecast(locationId: id) {
                verdict = AnchorForecast.verdict(forecast: f, settings: settings)
            }
        }
        loading = false
    }

    private func verdictCard(_ v: AnchorForecastVerdict) -> some View {
        VStack(spacing: 10) {
            Image(systemName: v.rating.icon)
                .font(.system(size: 40)).foregroundStyle(v.color)
            Text(v.word)
                .font(.system(size: 34, weight: .heavy)).foregroundStyle(v.color)
            Text(v.headline)
                .font(.headline).foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)
            HStack(spacing: 22) {
                if let w = v.maxWind { miniStat("PEAK WIND", "\(w) kt") }
                if let g = v.maxGust { miniStat("GUSTS", "\(g) kt") }
                if let s = v.dirSpread { miniStat("DIR SWING", "\(s)°") }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(v.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(v.color.opacity(0.4), lineWidth: 1))
    }

    private func miniStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 17, weight: .bold, design: .monospaced)).foregroundStyle(Color.textPrimary)
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(Color.textSecondary)
        }
    }

    private func hourStrip(_ v: AnchorForecastVerdict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NEXT HOURS").sectionHeader()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(v.hours.prefix(24)) { h in
                        VStack(spacing: 4) {
                            Text(h.label).font(.system(size: 10)).foregroundStyle(Color.textSecondary)
                            if let d = h.dir {
                                Image(systemName: "location.north.fill")
                                    .font(.system(size: 10))
                                    .rotationEffect(.degrees(Double(d) + 180))  // arrow points where wind blows TO
                                    .foregroundStyle(Color.accentCyan)
                            }
                            Text("\(h.wind)")
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                                .foregroundStyle(h.over ? Color.statusRed : Color.textPrimary)
                            if let g = h.gust {
                                Text("\(g)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.textTertiary)
                            }
                        }
                        .frame(width: 38)
                        .padding(.vertical, 8)
                        .background(Color.bgCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            Text("kt — top: sustained, bottom: gust · arrow: wind direction")
                .font(.system(size: 10)).foregroundStyle(Color.textTertiary)
        }
    }

    private func reasonsCard(_ v: AnchorForecastVerdict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(v.reasons.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(v.color).padding(.top, 6)
                    Text(r).font(.subheadline).foregroundStyle(Color.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var thresholdsNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Color.accentCyan)
            Text("Verdict uses your \(Int(settings.forecastAlarmMaxWindKn)) kt wind limit over the next \(settings.forecastAlarmHoursAhead) h. Adjust in anchor settings.")
                .font(.caption).foregroundStyle(Color.textSecondary)
        }
        .padding(.top, 4)
    }
}
