import SwiftUI
import MapKit

struct WaypointPickerSheet: View {
    let settings: AppSettings
    let signalK:  SignalKService
    @Environment(\.dismiss) private var dismiss

    @State private var pickedCoord: CLLocationCoordinate2D?
    @State private var pickedName:  String = ""
    @State private var satellite:   Bool   = false
    @StateObject private var zoomProxy = MapZoomProxy()

    private var initialCenter: CLLocationCoordinate2D {
        settings.waypointActive
            ? CLLocationCoordinate2D(latitude: settings.waypointLat, longitude: settings.waypointLon)
            : CLLocationCoordinate2D(latitude: signalK.latitude,     longitude: signalK.longitude)
    }

    init(settings: AppSettings, signalK: SignalKService) {
        self.settings = settings
        self.signalK  = signalK
        if settings.waypointActive {
            _pickedCoord = State(initialValue: CLLocationCoordinate2D(
                latitude:  settings.waypointLat,
                longitude: settings.waypointLon))
            _pickedName  = State(initialValue: settings.waypointName)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // OSM / ESRI tile map — disk-cached, works offline after first visit.
                // Uses non-Apple CDN so it renders even when Apple map servers are blocked.
                OSMMapPickerView(
                    initialCenter:    initialCenter,
                    vesselCoordinate: CLLocationCoordinate2D(latitude: signalK.latitude,
                                                             longitude: signalK.longitude),
                    pickedCoord: $pickedCoord,
                    onPick:      { reverseGeocode($0) },
                    zoomProxy:   zoomProxy,
                    satellite:   satellite
                )
                .ignoresSafeArea()

                // UI overlay
                VStack(spacing: 6) {

                    // ── Instruction banner + GPS shortcut ──────────────────
                    HStack(spacing: 8) {
                        Text(pickedCoord == nil ? "Tap chart to set waypoint"
                                                : "Tap chart to move waypoint")
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)

                        Button {
                            let c = CLLocationCoordinate2D(latitude:  signalK.latitude,
                                                           longitude: signalK.longitude)
                            pickedCoord = c
                            reverseGeocode(c)
                        } label: {
                            Label("Use GPS", systemImage: "location.fill")
                                .font(.caption)
                                .foregroundStyle(Color.accentCyan)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.accentCyan.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 12)

                    // ── Coordinate readout ─────────────────────────────────
                    if let c = pickedCoord {
                        Text(String(format: "%.5f°N   %.5f°E", c.latitude, c.longitude))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }

                    Spacer()

                    // ── Map style + zoom buttons (trailing) ────────────────
                    VStack(spacing: 0) {
                        // Satellite / standard toggle
                        Button { satellite.toggle() } label: {
                            Image(systemName: satellite ? "map" : "globe")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Color.textPrimary)
                                .frame(width: 46, height: 46)
                        }
                        Divider().frame(width: 30)
                        // Zoom in
                        Button { zoomProxy.zoomIn() } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Color.textPrimary)
                                .frame(width: 46, height: 46)
                        }
                        Divider().frame(width: 30)
                        // Zoom out
                        Button { zoomProxy.zoomOut() } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Color.textPrimary)
                                .frame(width: 46, height: 46)
                        }
                    }
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.borderColor, lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 16)
                    .padding(.bottom, 80)
                }
            }
            .navigationTitle("Set Waypoint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if settings.waypointActive {
                        Button("Clear", role: .destructive) {
                            settings.waypointActive = false
                            settings.waypointName   = ""
                            settings.persist()
                            dismiss()
                        }
                        .foregroundStyle(Color.statusRed)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.accentCyan)
                }
                ToolbarItem(placement: .bottomBar) {
                    if let coord = pickedCoord {
                        Button {
                            settings.waypointLat    = coord.latitude
                            settings.waypointLon    = coord.longitude
                            settings.waypointName   = pickedName
                            settings.waypointActive = true
                            settings.persist()
                            dismiss()
                        } label: {
                            Label(pickedName.isEmpty ? "Set Waypoint" : "Set \"\(pickedName)\"",
                                  systemImage: "flag.fill")
                                .font(.headline)
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.statusOrange)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                    }
                }
            }
        }
        .sheetDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.bgPrimary)
    }

    private func reverseGeocode(_ coord: CLLocationCoordinate2D) {
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(
            CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        ) { placemarks, _ in
            if let name = placemarks?.first?.name ?? placemarks?.first?.locality {
                pickedName = name
            }
        }
    }
}
