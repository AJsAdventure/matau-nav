import SwiftUI

// MARK: - Time-range options

enum HistoryRange: Int, CaseIterable {
    case five   = 5
    case thirty = 30
    case sixty  = 60

    var label: String { "\(rawValue)m" }
    var samples: Int  { rawValue * 60 / 5 }  // 5-second sampling
}

// MARK: - Data processing helpers

/// Apply outlier rejection then rolling-average damping to a sample array.
func processedInstrumentData(_ raw: [Double], config: InstrumentConfig) -> [Double] {
    guard !raw.isEmpty else { return raw }
    var d = raw

    // 1. Outlier rejection — replace spikes with the previous value
    if config.outlierFactor > 0, d.count > 4 {
        let mean     = d.reduce(0, +) / Double(d.count)
        let variance = d.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(d.count)
        let stdDev   = sqrt(variance)
        if stdDev > 0 {
            for i in 1..<d.count {
                if abs(d[i] - mean) > config.outlierFactor * stdDev { d[i] = d[i - 1] }
            }
        }
    }

    // 2. Rolling-average damping
    if config.dampingSamples > 1 {
        var smoothed = d
        for i in 0..<d.count {
            let start     = max(0, i - config.dampingSamples + 1)
            let window    = d[start...i]
            smoothed[i]   = window.reduce(0, +) / Double(window.count)
        }
        d = smoothed
    }
    return d
}

// MARK: - Main view

struct InstrumentsView: View {
    @Environment(SignalKService.self) private var signalK
    @Environment(AppSettings.self)   private var settings
    @State private var history:            [String: [Double]] = [:]
    @State private var range:              HistoryRange        = .thirty
    @State private var selectedInstrument: Instrument?         = nil

    private static let maxSamples = HistoryRange.sixty.samples

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgPrimary.ignoresSafeArea()
                VStack(spacing: 0) {
                    rangeSelector
                    ScrollView {
                        VStack(spacing: 16) {
                            ForEach(Instrument.grouped, id: \.0) { group, instruments in
                                InstrumentGroup(
                                    title:          group,
                                    instruments:    instruments,
                                    signalK:        signalK,
                                    settings:       settings,
                                    history:        history,
                                    displaySamples: range.samples,
                                    onTap:          { selectedInstrument = $0 }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
            }
            .navigationTitle("Instruments")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if let age = signalK.dataAgeString {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text(age)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.statusOrange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.statusOrange.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .task {
            // Restore history from Pi buffer before the local sampler starts,
            // so the charts are immediately populated after a crash or reconnect.
            await fetchPiHistory()
            while !Task.isCancelled {
                recordSample()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        // Re-fetch Pi history whenever SignalK (re-)connects
        .onChange(of: signalK.state.isConnected) { _, isConnected in
            if isConnected {
                Task { await fetchPiHistory() }
            }
        }
        .sheet(item: $selectedInstrument) { instrument in
            if instrument == .gps {
                GPSDetailSheet(signalK: signalK, settings: settings)
            } else {
                InstrumentDetailSheet(
                    instrument: instrument,
                    signalK:    signalK,
                    settings:   settings,
                    history:    history[instrument.rawValue] ?? []
                )
            }
        }
    }

    // MARK: Range selector

    private var rangeSelector: some View {
        HStack(spacing: 0) {
            ForEach(HistoryRange.allCases, id: \.self) { r in
                Button { withAnimation(.easeInOut(duration: 0.15)) { range = r } } label: {
                    Text(r.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(range == r ? .black : Color.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(range == r ? Color.accentCyan : Color.clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.bgElevated)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.borderColor, lineWidth: 0.5))
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func recordSample() {
        for instrument in Instrument.allCases {
            guard !instrument.isFullWidth else { continue }  // GPS has no time-series history
            let v = instrument.value(from: signalK, settings: settings)
            history[instrument.rawValue, default: []].append(v)
            if history[instrument.rawValue]!.count > Self.maxSamples {
                history[instrument.rawValue]!.removeFirst()
            }
        }
    }

    /// Fetches the Pi's rolling 60-min buffer and pre-populates history.
    /// Called once on view appear — silently no-ops if the Pi is unreachable.
    private func fetchPiHistory() async {
        let base = signalK.piBase(port: 3001)   // follows the remote failover
        guard let url = URL(string: "\(base)/history") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        for (k, v) in signalK.piHeaders(for: base) { req.setValue(v, forHTTPHeaderField: k) }

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples  = json["samples"] as? [[String: Any]] else { return }

        // Pi key → (Instrument, optional transform)
        let mapping: [(String, Instrument, (Double) -> Double)] = [
            ("sog",    .sog,       { $0 }),
            ("stw",    .stw,       { $0 }),
            ("hdg",    .heading,   { $0 }),
            ("depth",  .depth,     { $0 }),
            ("awa",    .awa,       { abs($0) }),
            ("aws",    .aws,       { $0 }),
            ("twa",    .twa,       { abs($0) }),
            ("tws",    .tws,       { $0 }),
            ("twd",    .twd,       { $0 }),
            ("wtemp",  .waterTemp, { $0 }),
            ("rudder", .rudder,    { $0 }),
        ]

        var fetched: [String: [Double]] = [:]
        for (piKey, instrument, transform) in mapping {
            let values = samples.compactMap { s -> Double? in
                guard let v = s[piKey] as? Double else { return nil }
                return transform(v)
            }
            if !values.isEmpty {
                fetched[instrument.rawValue] = Array(values.suffix(Self.maxSamples))
            }
        }

        // Only overwrite if the Pi has more history than we've already built locally
        for (key, values) in fetched {
            if values.count > (history[key]?.count ?? 0) {
                history[key] = values
            }
        }
    }
}

// MARK: - Group section

private struct InstrumentGroup: View {
    let title:          String
    let instruments:    [Instrument]
    let signalK:        SignalKService
    let settings:       AppSettings
    let history:        [String: [Double]]
    let displaySamples: Int
    let onTap:          (Instrument) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .sectionHeader()
                .padding(.horizontal, 4)

            let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(instruments) { instrument in
                    let raw   = history[instrument.rawValue] ?? []
                    let slice = raw.count > displaySamples ? Array(raw.suffix(displaySamples)) : raw
                    let config = settings.instrumentConfigs[instrument.rawValue] ?? InstrumentConfig()
                    let processed = processedInstrumentData(slice, config: config)

                    if instrument.isFullWidth {
                        GPSInstrumentCard(signalK: signalK, settings: settings, onTap: { onTap(instrument) })
                            .gridCellColumns(2)
                    } else {
                        InstrumentCard(
                            instrument:  instrument,
                            signalK:     signalK,
                            settings:    settings,
                            historyData: processed,
                            config:      config,
                            onTap:       { onTap(instrument) }
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Instrument card

private struct InstrumentCard: View {
    let instrument:  Instrument
    let signalK:     SignalKService
    let settings:    AppSettings
    let historyData: [Double]
    let config:      InstrumentConfig
    let onTap:       () -> Void

    var body: some View {
        // Explicit position access guarantees DTW/CTW tiles update live when GPS changes
        // Touch position so SwiftUI tracks it and re-renders DTW/CTW live with GPS updates
        let _ = (instrument == .dtw || instrument == .ctw) ? signalK.latitude + signalK.longitude : 0.0
        let noData   = signalK.lastSuccessfulUpdate == nil
        let noSignal = !instrument.hasValidReading(from: signalK, settings: settings)
        let dimmed   = noData || noSignal
        let displayValue = dimmed ? "---" : instrument.formattedValue(from: signalK, settings: settings)

        Button { onTap() } label: {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: instrument.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentCyan)
                    Text(instrument.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                        .tracking(1.0)
                    Spacer()
                    if config.dampingSamples > 1 || config.outlierFactor > 0 {
                        Image(systemName: "waveform.path")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.accentCyan.opacity(0.60))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

                SparklineView(
                    data:          historyData,
                    color:         sparklineColor,
                    centerOnZero:  instrument == .rudder,
                    coloredBySign: instrument == .rudder,
                    invertY:       instrument == .depth,
                    showMinMax:    config.showMinMax,
                    showTrend:     config.showTrend
                )
                .frame(height: 38)
                .padding(.horizontal, 12)

                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    Text(displayValue)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundStyle(dimmed ? Color.textTertiary : Color.textPrimary)
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    if !instrument.unit.isEmpty && !dimmed {
                        Text(instrument.unit)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.textSecondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 12)

                Spacer(minLength: 0)
            }
            // Fixed height — all tiles identical size in the grid
            .frame(height: 120)
            .background(Color.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.borderColor, lineWidth: 0.5)
            )
        }
        .buttonStyle(InstrumentCardButtonStyle())
    }

    private var sparklineColor: Color {
        switch instrument.group {
        case "Wind", "Waypoint": return Color.statusOrange
        default:                 return Color.accentCyan
        }
    }
}

private struct InstrumentCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

// MARK: - Detail sheet (tap to expand)

struct InstrumentDetailSheet: View {
    let instrument: Instrument
    let signalK:    SignalKService
    let settings:   AppSettings
    let history:    [Double]   // full 60-min raw buffer

    @State private var range           = HistoryRange.thirty
    @State private var showingSettings = false
    @Environment(\.dismiss) private var dismiss

    private var config: InstrumentConfig {
        settings.instrumentConfigs[instrument.rawValue] ?? InstrumentConfig()
    }

    private var processedSlice: [Double] {
        let slice = history.count > range.samples ? Array(history.suffix(range.samples)) : history
        return processedInstrumentData(slice, config: config)
    }

    private var stats: (min: Double, avg: Double, max: Double)? {
        guard processedSlice.count >= 2 else { return nil }
        let mn  = processedSlice.min()!
        let mx  = processedSlice.max()!
        let avg = processedSlice.reduce(0, +) / Double(processedSlice.count)
        return (mn, avg, mx)
    }

    private var sparklineColor: Color {
        switch instrument.group {
        case "Wind", "Waypoint": return Color.statusOrange
        default:                 return Color.accentCyan
        }
    }

    private var processingBadge: String? {
        var parts: [String] = []
        if config.dampingSamples > 1 {
            let seconds = config.dampingSamples * 5
            parts.append(seconds < 60 ? "Smoothed \(seconds)s" : "Smoothed \(seconds/60)min")
        }
        if config.outlierFactor > 0 {
            let label: String = config.outlierFactor >= 3.0 ? "Gentle" :
                                config.outlierFactor >= 2.0 ? "Moderate" : "Strict"
            parts.append("Spike filter: \(label)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {

                        // Sparkline
                        VStack(spacing: 6) {
                            SparklineView(
                                data:          processedSlice,
                                color:         sparklineColor,
                                centerOnZero:  instrument == .rudder,
                                coloredBySign: instrument == .rudder,
                                invertY:       instrument == .depth,
                                showMinMax:    config.showMinMax,
                                showTrend:     config.showTrend
                            )
                            .frame(height: 130)
                            .padding(.horizontal, 20)

                            if let badge = processingBadge {
                                Text(badge)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.accentCyan.opacity(0.80))
                            }
                        }
                        .padding(.top, 16)
                        .padding(.bottom, 12)

                        // Range picker
                        HStack(spacing: 0) {
                            ForEach(HistoryRange.allCases, id: \.self) { r in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) { range = r }
                                } label: {
                                    Text(r.label)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(range == r ? .black : Color.textSecondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 7)
                                        .background(range == r ? Color.accentCyan : Color.clear)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(3)
                        .background(Color.bgElevated)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.borderColor, lineWidth: 0.5))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)

                        // Large live value
                        VStack(spacing: 4) {
                            let noData = signalK.lastSuccessfulUpdate == nil
                            HStack(alignment: .lastTextBaseline, spacing: 8) {
                                Text(noData ? "---" : instrument.formattedValue(from: signalK, settings: settings))
                                    .font(.system(size: 52, weight: .bold, design: .monospaced))
                                    .foregroundStyle(noData ? Color.textTertiary : Color.textPrimary)
                                    .contentTransition(.numericText())
                                    .minimumScaleFactor(0.5)
                                    .lineLimit(1)
                                if !instrument.unit.isEmpty && !noData {
                                    Text(instrument.unit)
                                        .font(.system(size: 22, weight: .medium))
                                        .foregroundStyle(Color.textSecondary)
                                }
                            }
                            Text("LIVE")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.accentCyan.opacity(0.70))
                                .tracking(2)
                        }
                        .padding(.bottom, 24)

                        // Min / Avg / Max stats
                        if let s = stats {
                            HStack(spacing: 0) {
                                StatCell(label: "MIN",  value: compactFmt(s.min),  color: Color.accentCyan)
                                Divider().frame(height: 40).background(Color.borderColor)
                                StatCell(label: "AVG",  value: compactFmt(s.avg),  color: Color.textPrimary)
                                Divider().frame(height: 40).background(Color.borderColor)
                                StatCell(label: "MAX",  value: compactFmt(s.max),  color: Color.statusOrange)
                            }
                            .background(Color.bgCard)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.borderColor, lineWidth: 0.5))
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                        }

                        Spacer(minLength: 40)
                    }
                }
            }
            .navigationTitle(instrument.fullName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.accentCyan)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(Color.textSecondary)
                    }
                }
            }
        }
        .sheetDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.bgPrimary)
        .sheet(isPresented: $showingSettings) {
            InstrumentSettingsView(instrument: instrument, settings: settings)
        }
    }

    private func compactFmt(_ v: Double) -> String {
        abs(v) >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }
}

// MARK: - Stats cell

private struct StatCell: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
                .tracking(1.2)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

// MARK: - Instrument settings sheet

struct InstrumentSettingsView: View {
    let instrument: Instrument
    let settings:   AppSettings
    @Environment(\.dismiss) private var dismiss

    // Local copy — written back on every change
    @State private var config = InstrumentConfig()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {

                        // SMOOTHING
                        settingsCard(title: "Smoothing", icon: "waveform.path") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Averages the last N samples (each 5 s) to calm down noisy readings. Useful for depth and temperature at dock.")
                                    .font(.caption)
                                    .foregroundStyle(Color.textSecondary)

                                let options: [(label: String, value: Int)] = [
                                    ("Off",  1),
                                    ("15 s", 3),
                                    ("30 s", 6),
                                    ("1 min",12),
                                    ("2 min",24)
                                ]
                                SegmentedPicker(
                                    options: options.map { $0.label },
                                    selected: options.firstIndex(where: { $0.value == config.dampingSamples }) ?? 0
                                ) { idx in
                                    config.dampingSamples = options[idx].value
                                    save()
                                }
                            }
                        }

                        // SPIKE FILTER
                        settingsCard(title: "Spike Filter", icon: "bolt.trianglebadge.exclamationmark") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Detects values that jump implausibly far from the running mean and replaces them with the previous reading.")
                                    .font(.caption)
                                    .foregroundStyle(Color.textSecondary)

                                let options: [(label: String, value: Double)] = [
                                    ("Off",      0.0),
                                    ("Gentle",   3.0),
                                    ("Moderate", 2.0),
                                    ("Strict",   1.5)
                                ]
                                SegmentedPicker(
                                    options: options.map { $0.label },
                                    selected: options.firstIndex(where: { $0.value == config.outlierFactor }) ?? 0
                                ) { idx in
                                    config.outlierFactor = options[idx].value
                                    save()
                                }

                                // Context-specific guidance
                                let hint = spikeFilterHint
                                if !hint.isEmpty {
                                    Text(hint)
                                        .font(.caption)
                                        .foregroundStyle(Color.statusOrange.opacity(0.80))
                                }
                            }
                        }

                        // DISPLAY
                        settingsCard(title: "Display", icon: "chart.xyaxis.line") {
                            VStack(spacing: 0) {
                                Toggle(isOn: $config.showMinMax) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Min / Max labels")
                                            .font(.subheadline)
                                            .foregroundStyle(Color.textPrimary)
                                        Text("Show range extremes on the sparkline")
                                            .font(.caption)
                                            .foregroundStyle(Color.textSecondary)
                                    }
                                }
                                .tint(Color.accentCyan)
                                .onChange(of: config.showMinMax) { _, _ in save() }

                                Divider().background(Color.borderColor).padding(.vertical, 10)

                                Toggle(isOn: $config.showTrend) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Trend line")
                                            .font(.subheadline)
                                            .foregroundStyle(Color.textPrimary)
                                        Text("Linear regression line over the history window")
                                            .font(.caption)
                                            .foregroundStyle(Color.textSecondary)
                                    }
                                }
                                .tint(Color.accentCyan)
                                .onChange(of: config.showTrend) { _, _ in save() }
                            }
                        }

                        // RESET
                        Button {
                            config = InstrumentConfig()
                            save()
                        } label: {
                            Text("Reset to Defaults")
                                .font(.subheadline)
                                .foregroundStyle(Color.textTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.bgElevated)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("\(instrument.displayName) Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.accentCyan)
                }
            }
        }
        .sheetDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.bgPrimary)
        .onAppear {
            config = settings.instrumentConfigs[instrument.rawValue] ?? InstrumentConfig()
        }
    }

    private func save() {
        settings.instrumentConfigs[instrument.rawValue] = config
        settings.persist()
    }

    @ViewBuilder
    private func settingsCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(Color.textPrimary)
            content()
        }
        .padding(16)
        .background(Color.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.borderColor, lineWidth: 0.5))
        .padding(.horizontal, 20)
    }

    private var spikeFilterHint: String {
        switch instrument {
        case .depth:
            return config.outlierFactor == 0
                ? "⚠ Depth spikes can be real — consider Gentle only"
                : config.outlierFactor <= 1.5
                    ? "⚠ Strict may suppress real shoaling. Use Gentle underway."
                    : ""
        case .tws, .aws:
            return config.outlierFactor <= 1.5
                ? "⚠ Strict may suppress real gusts."
                : ""
        default:
            return ""
        }
    }
}

// MARK: - Segmented picker helper

private struct SegmentedPicker: View {
    let options:  [String]
    let selected: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { onSelect(i) }
                } label: {
                    Text(options[i])
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected == i ? .black : Color.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(selected == i ? Color.accentCyan : Color.clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.bgElevated)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.borderColor, lineWidth: 0.5))
    }
}

// MARK: - Sparkline

struct SparklineView: View {
    let data:          [Double]
    let color:         Color
    var centerOnZero:  Bool   = false
    var coloredBySign: Bool   = false
    var invertY:       Bool   = false   // high values at bottom (depth sonar convention)
    var showMinMax:    Bool   = true
    var showTrend:     Bool   = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Canvas { ctx, size in
                guard data.count >= 2 else { return }

                let w = size.width
                let h = size.height

                // Y scaling
                let rawLo = data.min()!
                let rawHi = data.max()!
                let lo: Double
                let hi: Double
                if centerOnZero {
                    let maxAbs = max(abs(rawLo), abs(rawHi), 1)
                    lo = -maxAbs * 1.30
                    hi =  maxAbs * 1.30
                } else {
                    let span = rawHi - rawLo
                    let pad  = span < 0.001 ? 1.0 : span * 0.28
                    lo = rawLo - pad
                    hi = rawHi + pad
                }
                let range = hi - lo

                func pt(_ idx: Int) -> CGPoint {
                    let x = w * CGFloat(idx) / CGFloat(data.count - 1)
                    let normalized = CGFloat((data[idx] - lo) / range)
                    // invertY: large values go to bottom (depth sonar convention)
                    let y = invertY ? h * normalized : h - h * normalized
                    return CGPoint(x: x, y: max(0, min(h, y)))
                }

                // Catmull-Rom → cubic Bezier control points for segment [i → i+1].
                // Produces smooth curves that pass through every data point.
                let pts = (0..<data.count).map { pt($0) }
                func catmullCP(_ i: Int) -> (CGPoint, CGPoint) {
                    let pPrev = pts[max(0, i - 1)]
                    let p0    = pts[i]
                    let p1    = pts[i + 1]
                    let pNext = pts[min(pts.count - 1, i + 2)]
                    // Divisor controls tension: 6 = standard Catmull-Rom, higher = less curve
                    let tension: CGFloat = 14
                    let cp1 = CGPoint(x: p0.x + (p1.x - pPrev.x) / tension,
                                      y: p0.y + (p1.y - pPrev.y) / tension)
                    let cp2 = CGPoint(x: p1.x - (pNext.x - p0.x) / tension,
                                      y: p1.y - (pNext.y - p0.y) / tension)
                    return (cp1, cp2)
                }

                // Zero line for rudder
                if centerOnZero {
                    let zeroY = h - h * CGFloat((0 - lo) / range)
                    var zl = Path()
                    zl.move(to: CGPoint(x: 0, y: zeroY))
                    zl.addLine(to: CGPoint(x: w, y: zeroY))
                    ctx.stroke(zl, with: .color(Color.white.opacity(0.18)),
                               style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                }

                if coloredBySign {
                    // Rudder: smooth Catmull-Rom curves, split at zero crossing for
                    // precise color change on the 0 line.
                    let zeroY = h - h * CGFloat((0 - lo) / range)
                    for i in 1..<pts.count {
                        let p0 = pts[i - 1]
                        let p1 = pts[i]
                        let v0 = data[i - 1]
                        let v1 = data[i]
                        let c0: Color = v0 >= 0 ? .statusGreen : .statusRed
                        let c1: Color = v1 >= 0 ? .statusGreen : .statusRed
                        let (cp1, cp2) = catmullCP(i - 1)

                        if (v0 >= 0) == (v1 >= 0) {
                            // Same side — smooth curved segment
                            var seg = Path()
                            seg.move(to: p0)
                            seg.addCurve(to: p1, control1: cp1, control2: cp2)
                            ctx.stroke(seg, with: .color(c0.opacity(0.85)),
                                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        } else {
                            // Zero crossing — split at exact crossing point (linear interpolation)
                            let t = CGFloat(abs(v0) / (abs(v0) + abs(v1)))
                            let crossPt = CGPoint(x: p0.x + (p1.x - p0.x) * t, y: zeroY)

                            var seg0 = Path()
                            seg0.move(to: p0); seg0.addLine(to: crossPt)
                            ctx.stroke(seg0, with: .color(c0.opacity(0.85)),
                                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                            var seg1 = Path()
                            seg1.move(to: crossPt); seg1.addLine(to: p1)
                            ctx.stroke(seg1, with: .color(c1.opacity(0.85)),
                                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        }
                    }
                    let last     = pts[pts.count - 1]
                    let dotColor: Color = data.last! >= 0 ? .statusGreen : .statusRed
                    var dot = Path()
                    dot.addEllipse(in: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5))
                    ctx.fill(dot, with: .color(dotColor))
                } else {
                    // Gradient fill — smooth Catmull-Rom curve for the top edge
                    var fill = Path()
                    fill.move(to: CGPoint(x: 0, y: invertY ? 0 : h))
                    fill.addLine(to: pts[0])
                    for i in 0..<pts.count - 1 {
                        let (cp1, cp2) = catmullCP(i)
                        fill.addCurve(to: pts[i + 1], control1: cp1, control2: cp2)
                    }
                    fill.addLine(to: CGPoint(x: w, y: invertY ? 0 : h))
                    fill.closeSubpath()
                    ctx.fill(fill, with: .linearGradient(
                        Gradient(stops: [
                            .init(color: color.opacity(invertY ? 0.03 : 0.30), location: 0),
                            .init(color: color.opacity(invertY ? 0.30 : 0.03), location: 1)
                        ]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint:   CGPoint(x: 0, y: h)
                    ))

                    // Main line — Catmull-Rom smooth curve through all data points
                    var line = Path()
                    line.move(to: pts[0])
                    for i in 0..<pts.count - 1 {
                        let (cp1, cp2) = catmullCP(i)
                        line.addCurve(to: pts[i + 1], control1: cp1, control2: cp2)
                    }
                    ctx.stroke(line, with: .color(color.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                    // Current dot
                    let last = pts[pts.count - 1]
                    var dot  = Path()
                    dot.addEllipse(in: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5))
                    ctx.fill(dot, with: .color(color))
                }

                // Trend line (linear regression)
                if showTrend && data.count >= 4 {
                    let n      = Double(data.count)
                    let sumX   = (0..<data.count).reduce(0.0) { $0 + Double($1) }
                    let sumY   = data.reduce(0.0, +)
                    let sumXY  = (0..<data.count).reduce(0.0) { $0 + Double($1) * data[$1] }
                    let sumX2  = (0..<data.count).reduce(0.0) { $0 + Double($1) * Double($1) }
                    let denom  = n * sumX2 - sumX * sumX
                    if abs(denom) > 0 {
                        let slope     = (n * sumXY - sumX * sumY) / denom
                        let intercept = (sumY - slope * sumX) / n
                        let norm0 = CGFloat((intercept - lo) / range)
                        let norm1 = CGFloat((slope * Double(data.count - 1) + intercept - lo) / range)
                        let y0 = invertY ? h * norm0 : h - h * norm0
                        let y1 = invertY ? h * norm1 : h - h * norm1
                        var trendLine = Path()
                        trendLine.move(to:    CGPoint(x: 0, y: max(0, min(h, y0))))
                        trendLine.addLine(to: CGPoint(x: w, y: max(0, min(h, y1))))
                        ctx.stroke(trendLine, with: .color(Color.white.opacity(0.40)),
                                   style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    }
                }
            }

            // Min/max labels — offset 5pt away from graph edges so they don't blend with the line
            if showMinMax && data.count >= 2 {
                let lo = data.min()!
                let hi = data.max()!
                VStack(alignment: .trailing, spacing: 0) {
                    Text(compactFormat(invertY ? lo : hi))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(color.opacity(0.65))
                        .padding(.top, 5)    // 5pt below top edge → clear of peak line
                    Spacer()
                    Text(compactFormat(invertY ? hi : lo))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(color.opacity(0.65))
                        .padding(.bottom, 5) // 5pt above bottom edge → clear of trough line
                }
                .padding(.trailing, 3)
            }
        }
    }

    private func compactFormat(_ v: Double) -> String {
        abs(v) >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }
}

// MARK: - GPS instrument card (full-width, two-line, format-aware)

private struct GPSInstrumentCard: View {
    let signalK: SignalKService
    let settings: AppSettings
    let onTap:   () -> Void

    private var lat: Double { signalK.latitude  }
    private var lon: Double { signalK.longitude }
    private var hasfix: Bool { lat != 0 || lon != 0 }

    private func latLine(_ fmt: String) -> (String, String) {
        // Returns (coordinate text, hemisphere letter)
        let h = lat >= 0 ? "N" : "S"
        switch fmt {
        case "DD":
            return (String(format: "%.5f°", abs(lat)), h)
        case "DMS":
            let d = Int(abs(lat)); let mFrac = (abs(lat) - Double(d)) * 60
            let m = Int(mFrac);    let s = (mFrac - Double(m)) * 60
            return (String(format: "%02d° %02d' %04.1f\"", d, m, s), h)
        default: // DDM
            let d = Int(abs(lat)); let m = (abs(lat) - Double(d)) * 60
            return (String(format: "%02d° %06.3f'", d, m), h)
        }
    }

    private func lonLine(_ fmt: String) -> (String, String) {
        let h = lon >= 0 ? "E" : "W"
        switch fmt {
        case "DD":
            return (String(format: "%.5f°", abs(lon)), h)
        case "DMS":
            let d = Int(abs(lon)); let mFrac = (abs(lon) - Double(d)) * 60
            let m = Int(mFrac);    let s = (mFrac - Double(m)) * 60
            return (String(format: "%03d° %02d' %04.1f\"", d, m, s), h)
        default: // DDM
            let d = Int(abs(lon)); let m = (abs(lon) - Double(d)) * 60
            return (String(format: "%03d° %06.3f'", d, m), h)
        }
    }

    var body: some View {
        Button { onTap() } label: {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentCyan)
                    Text("GPS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                        .tracking(1.0)
                    Spacer()
                    Text(settings.gpsCoordFormat)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.textTertiary)
                        .tracking(1.0)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

                if hasfix {
                    let fmt = settings.gpsCoordFormat
                    let (latCoord, latHem) = latLine(fmt)
                    let (lonCoord, lonHem) = lonLine(fmt)
                    VStack(alignment: .leading, spacing: 4) {
                        coordRow(coord: latCoord, hem: latHem)
                        coordRow(coord: lonCoord, hem: lonHem)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                } else {
                    Text("---")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.textTertiary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(Color.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.borderColor, lineWidth: 0.5))
        }
        .buttonStyle(InstrumentCardButtonStyle())
    }

    @ViewBuilder
    private func coordRow(coord: String, hem: String) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(coord)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
                .minimumScaleFactor(0.8)
                .lineLimit(1)
            Text(hem)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.accentCyan)
        }
    }
}

// MARK: - GPS detail sheet

struct GPSDetailSheet: View {
    let signalK: SignalKService
    let settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String? = nil

    enum CoordFormat: String, CaseIterable {
        case ddm = "DDM"
        case dd  = "DD"
        case dms = "DMS"
    }
    @State private var format: CoordFormat = .ddm

    private var lat: Double { signalK.latitude  }
    private var lon: Double { signalK.longitude }
    private var hasfix: Bool { lat != 0 || lon != 0 }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgPrimary.ignoresSafeArea()
                VStack(spacing: 0) {

                    // Format picker
                    HStack(spacing: 0) {
                        ForEach(CoordFormat.allCases, id: \.self) { f in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) { format = f }
                                settings.gpsCoordFormat = f.rawValue
                                settings.persist()
                            } label: {
                                Text(f.rawValue)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(format == f ? .black : Color.textSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(format == f ? Color.accentCyan : Color.clear)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(3)
                    .background(Color.bgElevated)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.borderColor, lineWidth: 0.5))
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 28)

                    if hasfix {
                        // All three format rows, always visible
                        VStack(spacing: 12) {
                            ForEach(CoordFormat.allCases, id: \.self) { f in
                                formatRow(f)
                            }
                        }
                        .padding(.horizontal, 20)
                    } else {
                        Text("No GPS fix")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color.textTertiary)
                    }

                    Spacer()

                    // Copied confirmation
                    if let c = copied {
                        Text("Copied \(c)")
                            .font(.caption)
                            .foregroundStyle(Color.accentCyan)
                            .padding(.bottom, 12)
                            .transition(.opacity)
                    }
                }
            }
            .navigationTitle("GPS Position")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.accentCyan)
                }
            }
        }
        .sheetDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.bgPrimary)
        .onAppear {
            format = CoordFormat(rawValue: settings.gpsCoordFormat) ?? .ddm
        }
    }

    @ViewBuilder
    private func formatRow(_ f: CoordFormat) -> some View {
        let text: String = {
            switch f {
            case .dd:  return Instrument.formatDD(lat: lat, lon: lon)
            case .ddm: return Instrument.formatDDM(lat: lat, lon: lon)
            case .dms: return Instrument.formatDMS(lat: lat, lon: lon)
            }
        }()
        let isActive = format == f

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(f.rawValue)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isActive ? Color.accentCyan : Color.textTertiary)
                    .tracking(1.5)
                Text(text)
                    .font(.system(size: isActive ? 17 : 14,
                                  weight: isActive ? .semibold : .regular,
                                  design: .monospaced))
                    .foregroundStyle(isActive ? Color.textPrimary : Color.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                Clipboard.copy(text)
                withAnimation { copied = f.rawValue }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { if copied == f.rawValue { copied = nil } }
                }
            } label: {
                Image(systemName: copied == f.rawValue ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14))
                    .foregroundStyle(copied == f.rawValue ? Color.statusGreen : Color.accentCyan)
                    .frame(width: 36, height: 36)
                    .background(Color.bgElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(isActive ? Color.accentCyan.opacity(0.08) : Color.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(isActive ? Color.accentCyan.opacity(0.3) : Color.borderColor, lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}
