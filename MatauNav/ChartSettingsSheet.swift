import SwiftUI
import MapKit
import UniformTypeIdentifiers
import CoreLocation

// MARK: - ChartSettingsSheet
//
// One-stop modal for everything the chart tab needs beyond the live map:
//   • Layer toggles (satellite, seamarks, AIS, tracks)
//   • Map orientation (north-up / heading-up — north-up only for now)
//   • Offline downloads — quick "current view" + advanced bbox (manual lat/lon)
//   • AIS key input + reconnect
//   • Tracks: list, toggle visibility, delete, import GPX, save live trail,
//     refetch from Pi.
//   • Cache management

struct ChartSettingsSheet: View {
    @Environment(AppSettings.self)    private var settings
    @Environment(SignalKService.self) private var signalK
    @Environment(PiStateService.self) private var piState
    @Environment(TrackService.self)   private var tracks
    @Environment(\.dismiss)           private var dismiss

    let zoomProxy: MapZoomProxy

    @State private var downloader = TileDownloader()
    @State private var showImporter = false
    @State private var importError: String?

    // Downloader UI state — bbox via map picker, zoom range via two-thumb slider
    @State private var pickedSW: CLLocationCoordinate2D?
    @State private var pickedNE: CLLocationCoordinate2D?
    @State private var minZoom: Int = 10
    @State private var maxZoom: Int = 16
    @State private var showRegionPicker = false

    @State private var cacheSizeLabel: String = "—"
    @State private var saveLiveName: String = ""
    @State private var showSaveLive = false

    // Friends management
    @State private var showFriendForm = false
    @State private var editingFriend: AISFriend?
    @State private var friendMMSI  = ""
    @State private var friendName  = ""
    @State private var friendPhone = ""
    @State private var friendNotes = ""
    @State private var showContactPicker = false
    @State private var sharingTrack: Track?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    layersCard
                    tacticalCard
                    routeCard
                    aisSafetyCard
                    downloadCard
                    aisCard
                    friendsCard
                    tracksCard
                    cacheCard
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(Color.bgPrimary)
            .navigationTitle("Chart")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.accentCyan)
                }
            }
        }
        .presentationBackground(Color.bgPrimary)
        .onAppear { cacheSizeLabel = TileDownloader.fmtBytes(TileDownloader.cacheSizeBytes()) }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml, .xml],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do { try tracks.importGPX(from: url) }
                catch { importError = error.localizedDescription }
            case .failure(let err):
                importError = err.localizedDescription
            }
        }
        .alert("Import failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
        .sheet(isPresented: $showFriendForm) { friendForm }
        .sheet(isPresented: $showRegionPicker) {
            let initial = zoomProxy.mapView?.region.center
                ?? CLLocationCoordinate2D(latitude: signalK.latitude  != 0 ? signalK.latitude  : 35.8893,
                                          longitude: signalK.longitude != 0 ? signalK.longitude : 14.5122)
            RegionPickerSheet(initialCenter: initial) { sw, ne in
                pickedSW = sw; pickedNE = ne
            }
        }
        .sheet(item: $sharingTrack) { track in
            if let url = try? GPXExport.writeTemp(for: track) {
                ShareSheet(items: [url])
            } else {
                Text("Failed to write GPX").padding()
            }
        }
        .alert("Save live trail", isPresented: $showSaveLive) {
            TextField("Name", text: $saveLiveName)
            Button("Save") {
                let n = saveLiveName.isEmpty ? "Trail \(Date().formatted(date: .abbreviated, time: .shortened))" : saveLiveName
                tracks.saveLiveAsTrack(name: n); saveLiveName = ""
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Layers

    private var layersCard: some View {
        @Bindable var s = settings
        return VStack(alignment: .leading, spacing: 14) {
            Label("Layers", systemImage: "square.3.layers.3d")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)

            toggle("Satellite imagery",  $s.chartSatellite)
            toggle("OpenSeaMap seamarks", $s.chartOpenSeaMap)
            toggle("Depth shading", $s.chartBathymetry)
            if s.chartBathymetry {
                Text("Bundled depth bands derived from EMODnet Bathymetry DTM 2024 (CC-BY 4.0) with OSM coastlines. Renders between the base/satellite layer and OpenSeaMap seamarks.")
                    .font(.caption2)
                    .foregroundStyle(Color.textTertiary)
                    .padding(.leading, 4)
            }
            toggle("AIS targets (aisstream.io)", $s.chartShowAIS)
            toggle("PredictWind AIS overlay",    $s.chartShowPredictWindAIS)
            toggle("Tracks",              $s.chartShowTracks)
            toggle("Follow vessel",       $s.chartFollowVessel)
        }
        .cardStyle()
        .onChange(of: settings.chartSatellite)    { _, _ in settings.persist() }
        .onChange(of: settings.chartOpenSeaMap)   { _, _ in settings.persist() }
        .onChange(of: settings.chartBathymetry)   { _, _ in settings.persist() }
        .onChange(of: settings.chartShowAIS)             { _, _ in settings.persist() }
        .onChange(of: settings.chartShowPredictWindAIS) { _, _ in settings.persist() }
        .onChange(of: settings.chartShowTracks)          { _, _ in settings.persist() }
        .onChange(of: settings.chartFollowVessel) { _, _ in settings.persist() }
    }

    // MARK: Tactical overlays

    private var tacticalCard: some View {
        @Bindable var s = settings
        return VStack(alignment: .leading, spacing: 14) {
            Label("Tactical overlays", systemImage: "scope")
                .font(.headline).foregroundStyle(Color.textPrimary)

            toggle("Predictor line",       $s.chartShowPredictor)
            if s.chartShowPredictor {
                HStack {
                    Text("Tick every")
                        .font(.caption).foregroundStyle(Color.textSecondary)
                    Picker("", selection: $s.chartPredictorMin) {
                        ForEach(AppSettings.predictorTickChoices, id: \.self) { m in
                            Text(AppSettings.predictorTickLabel(m)).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
            toggle("Laylines to active waypoint", $s.chartShowLaylines)
            if s.chartShowLaylines {
                HStack {
                    Text("Tack angle: \(Int(s.chartTackAngleDeg))°")
                        .font(.caption).foregroundStyle(Color.textSecondary)
                    Slider(value: $s.chartTackAngleDeg, in: 30...60, step: 1)
                }
            }
            toggle("Wind history ribbon", $s.chartShowWindRibbon)
            toggle("Set & drift readout", $s.chartShowSetDrift)
        }
        .cardStyle()
        .onChange(of: settings.chartShowPredictor) { _, _ in settings.persist() }
        .onChange(of: settings.chartPredictorMin)  { _, _ in settings.persist() }
        .onChange(of: settings.chartShowLaylines)  { _, _ in settings.persist() }
        .onChange(of: settings.chartTackAngleDeg)  { _, _ in settings.persist() }
        .onChange(of: settings.chartShowWindRibbon){ _, _ in settings.persist() }
        .onChange(of: settings.chartShowSetDrift)  { _, _ in settings.persist() }
    }

    // MARK: Route editor

    private var routeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Route", systemImage: "point.topleft.down.curvedto.point.filled.bottomright.up")
                    .font(.headline).foregroundStyle(Color.textPrimary)
                Spacer()
                if let r = settings.activeRoute {
                    Text("\(r.legIndex + 1)/\(r.waypoints.count) legs")
                        .font(.caption).foregroundStyle(Color.textSecondary)
                }
            }
            Text("Long-press the chart to add waypoints. The active leg shows as a filled purple circle; passed legs go grey.")
                .font(.caption).foregroundStyle(Color.textSecondary)

            if let route = settings.activeRoute, !route.waypoints.isEmpty {
                ForEach(Array(route.waypoints.enumerated()), id: \.element.id) { idx, wp in
                    HStack {
                        Image(systemName: idx == route.legIndex ? "circle.fill"
                                       : idx < route.legIndex ? "checkmark.circle.fill"
                                       : "circle")
                            .foregroundStyle(idx == route.legIndex ? Color.purple
                                          : idx < route.legIndex ? Color.statusGreen
                                          : Color.textTertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(idx + 1). \(wp.name)")
                                .font(.subheadline).foregroundStyle(Color.textPrimary)
                            Text(String(format: "%.4f°  %.4f°", wp.lat, wp.lon))
                                .font(.caption2).monospaced()
                                .foregroundStyle(Color.textTertiary)
                        }
                        Spacer()
                        Button {
                            removeWaypoint(at: idx)
                        } label: {
                            Image(systemName: "trash").foregroundStyle(Color.statusRed)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
                Button {
                    Task { await piState.clearRoute() }
                } label: {
                    Text("Clear route")
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color.statusRed.opacity(0.15))
                        .foregroundStyle(Color.statusRed)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            } else {
                Text("No active route.")
                    .font(.caption).foregroundStyle(Color.textTertiary)
            }
        }
        .cardStyle()
    }

    private func removeWaypoint(at idx: Int) {
        guard var r = settings.activeRoute, r.waypoints.indices.contains(idx) else { return }
        r.waypoints.remove(at: idx)
        if r.legIndex > idx { r.legIndex -= 1 }
        if r.waypoints.isEmpty {
            Task { await piState.clearRoute() }
        } else {
            Task { await piState.setRoute(r) }
        }
    }

    // MARK: AIS safety

    private var aisSafetyCard: some View {
        @Bindable var s = settings
        return VStack(alignment: .leading, spacing: 14) {
            Label("AIS safety", systemImage: "shield.lefthalf.filled")
                .font(.headline).foregroundStyle(Color.textPrimary)

            toggle("CPA collision alarm", $s.aisCPAAlarmEnabled)
            if s.aisCPAAlarmEnabled {
                HStack {
                    Text(String(format: "Min CPA: %.2f nm", s.aisCPAThresholdNm))
                        .font(.caption).foregroundStyle(Color.textSecondary)
                    Slider(value: $s.aisCPAThresholdNm, in: 0.1...3, step: 0.1)
                }
                HStack {
                    Text("Min TCPA: \(Int(s.aisTCPAThresholdMin)) min")
                        .font(.caption).foregroundStyle(Color.textSecondary)
                    Slider(value: $s.aisTCPAThresholdMin, in: 2...30, step: 1)
                }
                Text("Targets that get inside both thresholds get a red ring on the chart and trigger a banner.")
                    .font(.caption2).foregroundStyle(Color.textTertiary)
            }

            Divider().background(Color.borderColor)

            toggle("Guard zone", $s.aisGuardZoneEnabled)
            if s.aisGuardZoneEnabled {
                HStack {
                    Text(String(format: "Radius: %.1f nm", s.aisGuardZoneRadiusNm))
                        .font(.caption).foregroundStyle(Color.textSecondary)
                    Slider(value: $s.aisGuardZoneRadiusNm, in: 0.2...5, step: 0.1)
                }
                Text("Any AIS target inside the dashed circle around your vessel gets highlighted.")
                    .font(.caption2).foregroundStyle(Color.textTertiary)
            }

            if !s.aisAcknowledgedMMSIs.isEmpty {
                Button {
                    s.aisAcknowledgedMMSIs.removeAll()
                } label: {
                    Text("Clear acknowledged alarms (\(s.aisAcknowledgedMMSIs.count))")
                        .font(.caption).foregroundStyle(Color.accentCyan)
                }
            }
        }
        .cardStyle()
        .onChange(of: settings.aisCPAAlarmEnabled)   { _, _ in settings.persist() }
        .onChange(of: settings.aisCPAThresholdNm)    { _, _ in settings.persist(); pushSafetyConfig() }
        .onChange(of: settings.aisTCPAThresholdMin)  { _, _ in settings.persist(); pushSafetyConfig() }
        .onChange(of: settings.aisGuardZoneEnabled)  { _, _ in settings.persist(); pushSafetyConfig() }
        .onChange(of: settings.aisGuardZoneRadiusNm) { _, _ in settings.persist(); pushSafetyConfig() }
    }

    private func pushSafetyConfig() {
        let body: [String: Any] = [
            "cpa_threshold_nm":     settings.aisCPAThresholdNm,
            "tcpa_threshold_min":   settings.aisTCPAThresholdMin,
            "guard_zone_enabled":   settings.aisGuardZoneEnabled,
            "guard_zone_radius_nm": settings.aisGuardZoneRadiusNm,
        ]
        Task { await piState.setConfig(body) }
    }

    // MARK: Downloads

    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Offline charts", systemImage: "arrow.down.circle")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)

            Text("Tiles are stored on this device. They appear instantly on the chart and work fully offline.")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)

            // Pick region by dragging a rectangle on a full-screen map
            Button {
                showRegionPicker = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.dashed")
                    Text(pickedSW == nil || pickedNE == nil
                         ? "Pick region on map"
                         : "Reselect region")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(Color.accentCyan.opacity(0.15))
                .foregroundStyle(Color.accentCyan)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            if let sw = pickedSW, let ne = pickedNE {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(format: "SW %.3f° %.3f°   NE %.3f° %.3f°",
                                sw.latitude, sw.longitude, ne.latitude, ne.longitude))
                        .font(.caption2).monospaced()
                        .foregroundStyle(Color.textTertiary)

                    Text("Zoom range: z\(minZoom) – z\(maxZoom)")
                        .font(.caption).foregroundStyle(Color.textSecondary)
                    RangeSlider(low: $minZoom, high: $maxZoom, bounds: 1...18)
                        .padding(.vertical, 4)

                    let stats = estimate(
                        minLat: sw.latitude, minLon: sw.longitude,
                        maxLat: ne.latitude, maxLon: ne.longitude,
                        minZoom: minZoom, maxZoom: maxZoom
                    )
                    Text("≈ \(stats.tiles) tiles · ~\(stats.estMB) MB · OSM + seamarks + satellite + EMODnet bathymetry")
                        .font(.caption).foregroundStyle(Color.textTertiary)

                    primaryButton("Download region") {
                        startDownloadBBox(
                            minLat: sw.latitude, minLon: sw.longitude,
                            maxLat: ne.latitude, maxLon: ne.longitude,
                            minZoom: minZoom, maxZoom: maxZoom,
                            name: "Region z\(minZoom)–z\(maxZoom)"
                        )
                    }
                }
            }

            // Progress
            if downloader.inProgress {
                Divider().background(Color.borderColor).padding(.vertical, 4)
                ProgressView(value: downloader.total > 0
                             ? Double(downloader.completed + downloader.failed) / Double(downloader.total)
                             : 0)
                    .tint(Color.accentCyan)
                Text(downloader.statusMessage)
                    .font(.caption).foregroundStyle(Color.textSecondary)
                Button("Cancel") { downloader.cancel() }
                    .font(.caption)
                    .foregroundStyle(Color.statusRed)
            } else if !downloader.statusMessage.isEmpty {
                Text(downloader.statusMessage)
                    .font(.caption).foregroundStyle(Color.textTertiary)
            }

            // Already-downloaded
            if !settings.chartDownloadedRegions.isEmpty {
                Divider().background(Color.borderColor).padding(.vertical, 4)
                Text("Saved regions").sectionHeader()
                ForEach(settings.chartDownloadedRegions) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).font(.subheadline).foregroundStyle(Color.textPrimary)
                            Text("z\(r.minZoom)–z\(r.maxZoom)  ·  \(r.tileCount) tiles  ·  \(TileDownloader.fmtBytes(r.bytes))")
                                .font(.caption).foregroundStyle(Color.textTertiary)
                        }
                        Spacer()
                        Button {
                            settings.chartDownloadedRegions.removeAll { $0.id == r.id }
                            settings.persist()
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(Color.statusRed)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .cardStyle()
    }

    // MARK: AIS

    private var aisCard: some View {
        @Bindable var s = settings
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("AIS (via Pi)", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(piState.connected
                              ? (piState.aisConnected ? Color.statusGreen : Color.statusOrange)
                              : Color.statusRed)
                        .frame(width: 7, height: 7)
                    Text(piState.connected
                         ? (piState.aisConnected ? "\(piState.targets.count) targets" : "Pi up · AIS down")
                         : "Pi offline")
                        .font(.caption).foregroundStyle(Color.textSecondary)
                }
            }
            Text("AIS now runs on the Pi: one WebSocket on the boat feeds every phone. Set the AIS key on the Pi via /etc/matau/state.json or push it from here.")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)

            FormField(label: "Push AIS key to Pi", placeholder: "paste aisstream.io key", text: $s.aisStreamAPIKey)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            HStack {
                Text("Range: \(Int(s.aisRangeNm)) nm")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                Slider(value: $s.aisRangeNm, in: 5...100, step: 5)
            }
            Button {
                let body: [String: Any] = [
                    "ais_stream_api_key": settings.aisStreamAPIKey,
                    "ais_range_nm":       settings.aisRangeNm,
                ]
                // Don't keep the key on the phone after handing it to the Pi
                let keyToWipe = !settings.aisStreamAPIKey.isEmpty
                Task {
                    await piState.setConfig(body)
                    if keyToWipe {
                        await MainActor.run {
                            settings.aisStreamAPIKey = ""
                            settings.persist()
                        }
                    }
                }
            } label: {
                Text("Send to Pi")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.accentCyan.opacity(0.15))
                    .foregroundStyle(Color.accentCyan)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            if let e = piState.lastError {
                Text(e).font(.caption).foregroundStyle(Color.statusRed)
            }
        }
        .cardStyle()
    }

    // MARK: Friends

    private var friendsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("AIS Friends", systemImage: "heart.fill")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text("\(settings.aisFriends.count)")
                    .font(.caption).foregroundStyle(Color.textSecondary)
                Button {
                    startAddFriend()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.pink)
                }
                .buttonStyle(.plain)
            }
            Text("Tag known vessels by MMSI. They show with a heart icon on the chart and get a one-tap WhatsApp button when an AIS detail is opened.")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)

            if settings.aisFriends.isEmpty {
                Text("No friends yet.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            } else {
                ForEach(settings.aisFriends) { f in
                    HStack(spacing: 10) {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(Color.pink)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name).font(.subheadline).foregroundStyle(Color.textPrimary)
                            Text("MMSI \(f.mmsi)\(f.phone.isEmpty ? "" : " · \(f.phone)")")
                                .font(.caption).foregroundStyle(Color.textTertiary)
                        }
                        Spacer()
                        if let url = f.whatsappURL {
                            Link(destination: url) {
                                Image(systemName: "message.fill")
                                    .foregroundStyle(Color(red: 0.149, green: 0.827, blue: 0.396))
                            }
                        }
                        Button {
                            startEditFriend(f)
                        } label: {
                            Image(systemName: "pencil").foregroundStyle(Color.accentCyan)
                        }
                        .buttonStyle(.plain)
                        Button {
                            settings.aisFriends.removeAll { $0.mmsi == f.mmsi }
                            settings.persist()
                        } label: {
                            Image(systemName: "trash").foregroundStyle(Color.statusRed)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .cardStyle()
    }

    private var friendForm: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    FormField(label: "MMSI", placeholder: "e.g. 215123456", text: $friendMMSI)
                        .keyboardType(.numberPad)
                        .disabled(editingFriend != nil)
                    Button { showContactPicker = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.crop.circle.badge.plus")
                            Text("Pick from Contacts")
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.accentCyan.opacity(0.15))
                        .foregroundStyle(Color.accentCyan)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    FormField(label: "Name", placeholder: "Sail Out", text: $friendName)
                    FormField(label: "Phone", placeholder: "+356 12 345 678", text: $friendPhone)
                        .keyboardType(.phonePad)
                    FormField(label: "Notes", placeholder: "", text: $friendNotes)
                    Button {
                        saveFriend()
                    } label: {
                        Text("Save friend")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(canSaveFriend ? Color.pink : Color.pink.opacity(0.3))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSaveFriend)
                }
                .padding(16)
            }
            .background(Color.bgPrimary)
            .navigationTitle(editingFriend == nil ? "Add Friend" : "Edit Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showFriendForm = false }
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
        .presentationBackground(Color.bgPrimary)
        .sheetDetents([.medium, .large])
        .sheet(isPresented: $showContactPicker) {
            ContactPicker { name, phone in
                if !name.isEmpty  { friendName = name }
                if !phone.isEmpty { friendPhone = phone }
                showContactPicker = false
            } onCancel: { showContactPicker = false }
        }
    }

    private var canSaveFriend: Bool {
        Int(friendMMSI) != nil && !friendName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func startAddFriend() {
        editingFriend = nil
        friendMMSI = ""; friendName = ""; friendPhone = ""; friendNotes = ""
        showFriendForm = true
    }

    private func startEditFriend(_ f: AISFriend) {
        editingFriend = f
        friendMMSI  = String(f.mmsi)
        friendName  = f.name
        friendPhone = f.phone
        friendNotes = f.notes
        showFriendForm = true
    }

    private func saveFriend() {
        guard let mmsi = Int(friendMMSI) else { return }
        var copy = settings.aisFriends.filter { $0.mmsi != mmsi }
        copy.append(.init(
            mmsi: mmsi,
            name: friendName.trimmingCharacters(in: .whitespaces),
            phone: friendPhone.trimmingCharacters(in: .whitespaces),
            notes: friendNotes
        ))
        copy.sort { $0.name.lowercased() < $1.name.lowercased() }
        settings.aisFriends = copy
        settings.persist()
        showFriendForm = false
    }

    // MARK: Tracks

    private var tracksCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Tracks", systemImage: "scribble.variable")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text("\(tracks.tracks.count) saved")
                    .font(.caption).foregroundStyle(Color.textSecondary)
            }

            HStack(spacing: 8) {
                actionChip("Import GPX", icon: "square.and.arrow.down") { showImporter = true }
                actionChip("Refresh Pi", icon: "arrow.clockwise") {
                    Task { await tracks.fetchPiTracks(base: signalK.piBase(port: 10113), headers: signalK.piHeaders(for: signalK.piBase(port: 10113))) }
                }
                actionChip("Save live", icon: "checkmark.circle") {
                    saveLiveName = "Trail \(Date().formatted(date: .abbreviated, time: .shortened))"
                    showSaveLive = true
                }
            }

            if tracks.liveTrack.points.count > 1 {
                HStack {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.accentCyan)
                    Text("Live trail · \(tracks.liveTrack.points.count) pts")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    Spacer()
                }
            }

            if tracks.tracks.isEmpty {
                Text("No tracks yet. Import a GPX file or wait for the Pi to share recordings.")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            } else {
                ForEach(tracks.tracks) { t in
                    HStack {
                        Image(systemName: sourceIcon(t.source))
                            .font(.caption)
                            .foregroundStyle(Color.accentCyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).font(.subheadline).foregroundStyle(Color.textPrimary)
                            Text("\(t.points.count) pts · \(t.source.rawValue.uppercased())")
                                .font(.caption).foregroundStyle(Color.textTertiary)
                        }
                        Spacer()
                        Button {
                            sharingTrack = t
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(Color.accentCyan)
                        }
                        .buttonStyle(.plain)
                        Button {
                            tracks.setVisible(t.id, visible: !t.visible)
                        } label: {
                            Image(systemName: t.visible ? "eye" : "eye.slash")
                                .foregroundStyle(t.visible ? Color.accentCyan : Color.textTertiary)
                        }
                        .buttonStyle(.plain)
                        Button {
                            tracks.delete(t.id)
                        } label: {
                            Image(systemName: "trash").foregroundStyle(Color.statusRed)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
            if let e = tracks.lastError {
                Text(e).font(.caption).foregroundStyle(Color.statusRed)
            }
        }
        .cardStyle()
    }

    private func sourceIcon(_ s: Track.Source) -> String {
        switch s {
        case .pi:    return "cpu"
        case .local: return "iphone"
        case .gpx:   return "doc.text"
        }
    }

    // MARK: Cache

    private var cacheCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Cache", systemImage: "internaldrive")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)
            HStack {
                Text("On-disk tiles").font(.subheadline).foregroundStyle(Color.textSecondary)
                Spacer()
                Text(cacheSizeLabel).font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.textPrimary)
            }
            Button(role: .destructive) {
                TileDownloader.clearAllCaches()
                settings.chartDownloadedRegions.removeAll()
                settings.persist()
                cacheSizeLabel = TileDownloader.fmtBytes(TileDownloader.cacheSizeBytes())
            } label: {
                Text("Clear tile cache")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.statusRed.opacity(0.15))
                    .foregroundStyle(Color.statusRed)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .cardStyle()
    }

    // MARK: Helpers

    /// Estimates total tiles + MB for OSM base + OpenSeaMap seamark + satellite
    /// (we always download all three for an offline region — chart on the boat
    /// needs to work in every layer style).
    private func estimate(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double,
                          minZoom: Int, maxZoom: Int) -> (tiles: Int, estMB: Int) {
        let baseTiles = TileMath.totalTiles(minLat: minLat, minLon: minLon,
                                            maxLat: maxLat, maxLon: maxLon,
                                            minZoom: minZoom, maxZoom: maxZoom)
        let tiles = baseTiles * 4                       // OSM + seamark + satellite + bathymetry
        // ~15 KB OSM + ~3 KB seamark + ~30 KB satellite ≈ 48 KB avg per location
        let mb = max(1, (tiles * 16) / 1024)
        return (tiles, mb)
    }

    private func startDownloadBBox(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double,
                                   minZoom: Int, maxZoom: Int, name: String) {
        // Download all three layers sequentially so the saved region is fully
        // usable offline regardless of which layer toggle is on at view time.
        downloader.downloadAll(
            minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon,
            minZoom: minZoom, maxZoom: maxZoom
        ) { tiles, bytes in
            let region = ChartRegion(
                name: name,
                minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon,
                minZoom: minZoom, maxZoom: maxZoom,
                tileCount: tiles, bytes: bytes,
                downloadedAt: Date().timeIntervalSince1970
            )
            settings.chartDownloadedRegions.insert(region, at: 0)
            settings.persist()
            cacheSizeLabel = TileDownloader.fmtBytes(TileDownloader.cacheSizeBytes())
        }
    }

    // MARK: Sub-components

    private func toggle(_ label: String, _ value: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(Color.textPrimary)
            Spacer()
            Toggle("", isOn: value).labelsHidden().tint(Color.accentCyan)
        }
    }

    private func actionChip(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption)
                Text(title).font(.caption).fontWeight(.medium)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.accentCyan.opacity(0.12))
            .foregroundStyle(Color.accentCyan)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.accentCyan)
                .foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(downloader.inProgress)
        .opacity(downloader.inProgress ? 0.5 : 1)
    }
}

// MARK: - Small inputs

private struct FormField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Color.textSecondary)
            TextField(placeholder, text: $text)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.bgElevated)
                .foregroundStyle(Color.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
