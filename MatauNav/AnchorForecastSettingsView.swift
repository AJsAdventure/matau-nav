import SwiftUI

// MARK: - Anchor Settings Sheet with Forecast Alarm
//
// Combined sheet shown from ChartView when in anchor mode.
// Merges existing anchor alarm settings (position, wind, depth) with
// a new forecast alarm section backed by the PredictWind Pi server.

struct AnchorSettingsSheetWithForecast: View {
    let settings:    AppSettings
    let anchorWatch: AnchorWatchService
    let piService:   AnchorPiService
    let predictWind: PredictWindService
    var signalK:     SignalKService? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving  = false
    @State private var saveError: String? = nil

    private func saveCurrentAnchorage() {
        let n = settings.savedAnchorages.count + 1
        let a = Anchorage(
            name: String(format: "Anchorage %d · %.3f, %.3f", n, settings.anchorLat, settings.anchorLon),
            lat: settings.anchorLat, lon: settings.anchorLon,
            radius: settings.anchorRadius, rode: settings.anchorRodeLength,
            depth: signalK?.depth ?? 0, notes: "",
            savedAt: Date().timeIntervalSince1970)
        settings.savedAnchorages.insert(a, at: 0)
        settings.persist()
    }

    /// Persist locally (settings already bind live) and push to the Pi. Kept as
    /// a plain method so the toolbar Save button can stay a simple titled button
    /// — a conditional custom-label button in `.confirmationAction` does not
    /// render reliably as a Save control inside a macOS sheet.
    private func performSave() {
        isSaving  = true
        saveError = nil
        settings.persist()
        Task {
            if !settings.anchorPiURL.isEmpty {
                await piService.syncConfig(settings: settings)
                if piService.connectionState == .disconnected {
                    saveError = "Saved locally — Pi sync failed"
                    isSaving  = false
                    return
                }
            }
            isSaving = false
            dismiss()
        }
    }

    private func restore(_ a: Anchorage) {
        settings.anchorLat       = a.lat
        settings.anchorLon       = a.lon
        settings.anchorRadius    = a.radius
        settings.anchorRodeLength = a.rode
        if let sk = signalK {
            anchorWatch.dropAnchor(settings: settings, signalK: sk)
        } else {
            settings.anchorActive = true
        }
        settings.persist()
        Task { await piService.syncConfig(settings: settings) }
        dismiss()
    }

    /// Suggested alarm radius from rode + depth (horizontal scope) + bow offset.
    private var radiusFromRode: Double {
        let depth = signalK?.depth ?? 0
        let rode  = settings.anchorRodeLength
        guard rode > 0 else { return 0 }
        let horiz = (depth > 0 && rode > depth) ? (rode*rode - depth*depth).squareRoot() : rode
        return (horiz + settings.anchorBowOffset + 5).rounded()
    }

    var body: some View {
        @Bindable var s = settings
        NavigationStack {
            ZStack {
                Color.bgPrimary.ignoresSafeArea()
                List {
                    // MARK: Position alarm
                    Section {
                        ForecastLabeledSlider(
                            label: "Drag radius",
                            value: $s.anchorRadius, range: 5...50, step: 1,
                            format: "%.0f m")
                    } header: {
                        Text("Position Alarm")
                            .sectionHeader()
                            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 4, trailing: 16))
                    }

                    // MARK: Wind alarms
                    Section {
                        ForecastLabeledSlider(
                            label: "Max wind speed",
                            value: $s.anchorWindMax, range: 5...60, step: 1,
                            format: "%.0f kts", offAtMax: true)
                        ForecastLabeledSlider(
                            label: "Max wind shift",
                            value: $s.anchorWindShift, range: 10...90, step: 5,
                            format: "%.0f°", offAtMax: true)
                        if settings.anchorActive {
                            HStack {
                                Text("Wind ref (TWD)")
                                    .font(.subheadline).foregroundStyle(Color.textSecondary)
                                Spacer()
                                Text(String(format: "%.0f°", settings.anchorInitialTWD))
                                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.textPrimary)
                            }
                            .listRowBackground(Color.bgCard)
                        }
                    } header: {
                        Text("Wind Alarms")
                            .sectionHeader()
                            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 4, trailing: 16))
                    }

                    // MARK: Depth alarm
                    Section {
                        ForecastDepthRangeRow(low: $s.anchorDepthMin, high: $s.anchorDepthMax)
                    } header: {
                        Text("Depth Alarm")
                            .sectionHeader()
                            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 4, trailing: 16))
                    }

                    // MARK: Geometry
                    Section {
                        Picker(selection: $s.anchorMooringType) {
                            Text("Swinging").tag("swinging")
                            Text("Fixed").tag("fixed")
                        } label: {
                            Text("Mooring type").font(.subheadline).foregroundStyle(Color.textSecondary)
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.bgCard)
                        ForecastLabeledSlider(
                            label: "Warning ring",
                            value: $s.anchorWarnRadius, range: 0...50, step: 1,
                            format: "%.0f m", zeroLabel: "Auto (75%)")
                        ForecastLabeledSlider(
                            label: "GPS → bow offset",
                            value: $s.anchorBowOffset, range: 0...30, step: 1,
                            format: "%.0f m", zeroLabel: "Off")
                        ForecastLabeledSlider(
                            label: "Rode deployed",
                            value: $s.anchorRodeLength, range: 0...120, step: 5,
                            format: "%.0f m", zeroLabel: "—")
                        if radiusFromRode > 0 {
                            Button {
                                settings.anchorRadius = max(5, min(50, radiusFromRode))
                            } label: {
                                HStack {
                                    Image(systemName: "scope")
                                    Text("Set alarm radius from rode")
                                    Spacer()
                                    Text(String(format: "%.0f m", radiusFromRode))
                                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                }
                                .font(.subheadline)
                            }
                            .foregroundStyle(Color.accentCyan)
                            .listRowBackground(Color.bgCard)
                        }
                    } header: {
                        Text("Anchor Geometry")
                            .sectionHeader()
                            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 4, trailing: 16))
                    } footer: {
                        Text("Bow offset places the anchor ahead of the GPS antenna. Rode helps size the swing radius and the scope readout.")
                            .font(.caption).foregroundStyle(Color.textTertiary)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    }

                    // MARK: Reliability
                    Section {
                        ForecastLabeledSlider(
                            label: "Drag confirm delay",
                            value: $s.anchorAlarmDelay, range: 0...120, step: 5,
                            format: "%.0f s", zeroLabel: "Instant")
                        Toggle(isOn: $s.anchorUseDeviceGPS) {
                            Text("Phone GPS backup").font(.subheadline).foregroundStyle(Color.textPrimary)
                        }.tint(Color.accentCyan).listRowBackground(Color.bgCard)
                        Toggle(isOn: $s.anchorGPSLossAlarm) {
                            Text("Alarm on GPS loss").font(.subheadline).foregroundStyle(Color.textPrimary)
                        }.tint(Color.accentCyan).listRowBackground(Color.bgCard)
                        Toggle(isOn: $s.anchorLowBatteryAlarm) {
                            Text("Alarm on low battery").font(.subheadline).foregroundStyle(Color.textPrimary)
                        }.tint(Color.accentCyan).listRowBackground(Color.bgCard)
                        if settings.anchorLowBatteryAlarm {
                            ForecastLabeledSlider(
                                label: "Battery threshold",
                                value: $s.anchorLowBatteryPct, range: 5...50, step: 5,
                                format: "%.0f %%")
                        }
                    } header: {
                        Text("Reliability")
                            .sectionHeader()
                            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 4, trailing: 16))
                    } footer: {
                        Text("The drag confirm delay rejects brief GPS wander before sounding. Phone GPS backup keeps the watch alive if the boat network drops.")
                            .font(.caption).foregroundStyle(Color.textTertiary)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    }

                    // MARK: Forecast alarm
                    Section {
                        Toggle(isOn: $s.forecastAlarmEnabled) {
                            Text("Enable forecast alarm")
                                .font(.subheadline).foregroundStyle(Color.textPrimary)
                        }
                        .tint(Color.accentCyan)
                        .listRowBackground(Color.bgCard)

                        if settings.forecastAlarmEnabled {
                            ForecastLabeledSlider(
                                label: "Max wind",
                                value: $s.forecastAlarmMaxWindKn, range: 5...60, step: 1,
                                format: "%.0f kn")
                            ForecastLabeledSlider(
                                label: "Max wave height",
                                value: $s.forecastAlarmMaxWaveM, range: 0.5...6, step: 0.5,
                                format: "%.1f m")
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Hours ahead")
                                        .font(.subheadline).foregroundStyle(Color.textSecondary)
                                    Spacer()
                                    Text("\(settings.forecastAlarmHoursAhead) h")
                                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.textPrimary)
                                }
                                Slider(
                                    value: Binding(
                                        get: { Double(settings.forecastAlarmHoursAhead) },
                                        set: { settings.forecastAlarmHoursAhead = Int($0) }
                                    ),
                                    in: 6...72, step: 6
                                )
                                .tint(Color.accentCyan)
                            }
                            .listRowBackground(Color.bgCard)
                        }
                    } header: {
                        Text("Forecast Alarm (PredictWind)")
                            .sectionHeader()
                            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 4, trailing: 16))
                    }

                    // MARK: Saved anchorages
                    Section {
                        if settings.anchorActive {
                            Button {
                                saveCurrentAnchorage()
                            } label: {
                                Label("Save this anchorage", systemImage: "bookmark.fill")
                            }
                            .foregroundStyle(Color.accentCyan)
                            .listRowBackground(Color.bgCard)
                        }
                        if settings.savedAnchorages.isEmpty {
                            Text("No saved anchorages yet")
                                .font(.caption).foregroundStyle(Color.textTertiary)
                                .listRowBackground(Color.bgCard)
                        } else {
                            ForEach(settings.savedAnchorages) { a in
                                Button { restore(a) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(a.name).font(.subheadline).foregroundStyle(Color.textPrimary)
                                            Text(String(format: "r %.0f m · rode %.0f m · %.1f m deep", a.radius, a.rode, a.depth))
                                                .font(.caption2).foregroundStyle(Color.textTertiary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.down.circle").foregroundStyle(Color.statusOrange)
                                    }
                                }
                                .listRowBackground(Color.bgCard)
                            }
                            .onDelete { idx in
                                settings.savedAnchorages.remove(atOffsets: idx)
                                settings.persist()
                            }
                        }
                    } header: {
                        Text("Saved Anchorages")
                            .sectionHeader()
                            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 4, trailing: 16))
                    }

                    // MARK: Data management
                    Section {
                        Button("Clear GPS Track") { anchorWatch.clearTrack() }
                            .foregroundStyle(Color.statusRed)
                            .listRowBackground(Color.bgCard)
                        Button("Clear Alarm Log") { anchorWatch.clearLog() }
                            .foregroundStyle(Color.statusRed)
                            .listRowBackground(Color.bgCard)
                    } header: {
                        Text("Data")
                            .sectionHeader()
                            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 4, trailing: 16))
                    }

                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle").foregroundStyle(Color.accentCyan)
                            Text("Radius alarm works when app is closed via iOS geofencing. Pi daemon sends always-loud ntfy push notifications. Forecast alarm requires a PredictWind Pi server on port 10115.")
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                        .listRowBackground(Color.bgPrimary)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Anchor Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSaving ? "Saving…" : "Save") { performSave() }
                        .foregroundStyle(Color.accentCyan)
                        .fontWeight(.semibold)
                        .disabled(isSaving)
                }
            }
            .alert("Pi Sync Failed",
                   isPresented: Binding(
                       get: { saveError != nil },
                       set: { if !$0 { saveError = nil } }
                   )) {
                Button("Save Anyway") { saveError = nil; dismiss() }
                Button("Stay", role: .cancel) { saveError = nil }
            } message: {
                Text("Settings saved on device but could not be synced to the Pi.")
            }
        }
        .sheetDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.bgPrimary)
    }
}

// MARK: - Slider row (private to this file)

private struct ForecastLabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    var offAtMax: Bool = false
    var zeroLabel: String? = nil

    private var displayText: String {
        if let zeroLabel, value <= range.lowerBound { return zeroLabel }
        if offAtMax && value >= range.upperBound { return "Off" }
        return String(format: format, value)
    }

    private var isMuted: Bool {
        (zeroLabel != nil && value <= range.lowerBound) || (offAtMax && value >= range.upperBound)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.subheadline).foregroundStyle(Color.textSecondary)
                Spacer()
                Text(displayText)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isMuted ? Color.textTertiary : Color.textPrimary)
                    .contentTransition(.numericText())
            }
            Slider(value: $value, in: range, step: step)
                .tint(Color.statusOrange)
        }
        .listRowBackground(Color.bgCard)
    }
}

// MARK: - Depth range row (private to this file)

private struct ForecastDepthRangeRow: View {
    @Binding var low:  Double
    @Binding var high: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Safe depth range").font(.subheadline).foregroundStyle(Color.textSecondary)
                Spacer()
                Text(String(format: "%.1f m — %.1f m", low, high))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
                    .contentTransition(.numericText())
            }
            ForecastDepthRangeSlider(low: $low, high: $high, range: 1...20, step: 0.5)
                .frame(height: 28)
        }
        .listRowBackground(Color.bgCard)
    }
}

private struct ForecastDepthRangeSlider: View {
    @Binding var low:  Double
    @Binding var high: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.bgElevated).frame(height: 4)
                Capsule()
                    .fill(Color.statusOrange)
                    .frame(width: max(0, highX(w) - lowX(w)), height: 4)
                    .offset(x: lowX(w))
                thumb(x: lowX(w))
                    .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                        let v = valueAt(drag.location.x, width: w)
                        low = max(range.lowerBound, min(v, high - step))
                    })
                thumb(x: highX(w))
                    .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                        let v = valueAt(drag.location.x, width: w)
                        high = min(range.upperBound, max(v, low + step))
                    })
            }
            .frame(height: 28)
        }
    }

    private func thumb(x: CGFloat) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 26, height: 26)
            .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
            .overlay(Circle().stroke(Color.statusOrange, lineWidth: 2))
            .offset(x: x - 13)
    }

    private func fraction(_ v: Double) -> CGFloat {
        CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
    private func lowX(_ w: CGFloat)  -> CGFloat { fraction(low)  * w }
    private func highX(_ w: CGFloat) -> CGFloat { fraction(high) * w }
    private func valueAt(_ x: CGFloat, width: CGFloat) -> Double {
        let f = Double(max(0, min(x, width))) / Double(width)
        let raw = range.lowerBound + f * (range.upperBound - range.lowerBound)
        return (raw / step).rounded() * step
    }
}
