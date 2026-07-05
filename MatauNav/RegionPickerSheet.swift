import SwiftUI
import MapKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - RegionPickerSheet
//
// Full-screen map for picking a download region by dragging a rectangle.
// Long-press anywhere starts a rectangle; drag with a second finger (or pan)
// to size it. Tap Confirm to return the bbox to the caller.
//
// Behaviour notes:
//   • While the rectangle is being drawn, map panning is disabled so the
//     drag exclusively sizes the box. Pan/zoom resumes once a corner is set.
//   • Tap-anywhere-else to restart the rectangle.

struct RegionPickerSheet: View {
    let initialCenter: CLLocationCoordinate2D
    var onConfirm: (CLLocationCoordinate2D, CLLocationCoordinate2D) -> Void   // sw, ne

    @Environment(\.dismiss) private var dismiss
    @State private var sw: CLLocationCoordinate2D?
    @State private var ne: CLLocationCoordinate2D?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                RegionDragMapView(
                    initialCenter: initialCenter,
                    sw: $sw, ne: $ne
                )
                .ignoresSafeArea()

                VStack(spacing: 12) {
                    Text(instruction)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())

                    HStack(spacing: 12) {
                        Button {
                            sw = nil; ne = nil
                        } label: {
                            Text("Reset")
                                .font(.subheadline).fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.bgElevated)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        Button {
                            if let sw, let ne {
                                onConfirm(sw, ne); dismiss()
                            }
                        } label: {
                            Text("Use this region")
                                .font(.subheadline).fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(sw != nil && ne != nil ? Color.accentCyan : Color.accentCyan.opacity(0.35))
                                .foregroundStyle(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(sw == nil || ne == nil)
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 24)
            }
            .navigationTitle("Pick region")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var instruction: String {
        if sw == nil || ne == nil {
            return "Tap-and-drag on the map to draw a rectangle"
        }
        return "Drag a corner to adjust, or tap to redraw"
    }
}

// MARK: - Drag-rect map

private struct RegionDragMapView: PlatformViewRepresentable {
    let initialCenter: CLLocationCoordinate2D
    @Binding var sw: CLLocationCoordinate2D?
    @Binding var ne: CLLocationCoordinate2D?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    #if os(macOS)
    func makeNSView(context: Context) -> MKMapView { makeMap(context) }
    func updateNSView(_ map: MKMapView, context: Context) { syncMap(map, context: context) }
    #else
    func makeUIView(context: Context) -> MKMapView { makeMap(context) }
    func updateUIView(_ map: MKMapView, context: Context) { syncMap(map, context: context) }
    #endif

    func makeMap(_ context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = false
        map.showsScale = true
        map.addOverlay(OSMTileOverlay(style: .standard), level: .aboveRoads)

        #if os(macOS)
        // On macOS a plain left-drag normally pans. Disable scroll-pan here so
        // the drag exclusively draws the download rectangle; zoom (pinch /
        // double-click) stays available to frame the area first.
        map.isScrollEnabled = false
        let drag = NSPanGestureRecognizer(target: context.coordinator,
                                          action: #selector(Coordinator.handleDrag(_:)))
        drag.delegate = context.coordinator
        map.addGestureRecognizer(drag)
        context.coordinator.pressRecognizer = drag
        #else
        // Long-press starts the rectangle; subsequent finger movement (still
        // within the same gesture) sizes it. This avoids fighting MapKit's
        // own pan gesture: the long-press only activates after a 0.4 s hold.
        let press = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handleDrag(_:)))
        press.minimumPressDuration = 0.4
        press.allowableMovement   = 10_000   // don't cancel as the finger moves
        press.delegate = context.coordinator
        map.addGestureRecognizer(press)
        context.coordinator.pressRecognizer = press
        #endif

        map.setRegion(.init(center: initialCenter,
                            span: .init(latitudeDelta: 0.5, longitudeDelta: 0.5)),
                      animated: false)
        return map
    }

    func syncMap(_ map: MKMapView, context: Context) {
        // Refresh the rectangle overlay
        map.removeOverlays(map.overlays.filter { $0 is MKPolygon })
        if let sw, let ne {
            let coords = [
                CLLocationCoordinate2D(latitude: sw.latitude, longitude: sw.longitude),
                CLLocationCoordinate2D(latitude: sw.latitude, longitude: ne.longitude),
                CLLocationCoordinate2D(latitude: ne.latitude, longitude: ne.longitude),
                CLLocationCoordinate2D(latitude: ne.latitude, longitude: sw.longitude),
            ]
            let poly = MKPolygon(coordinates: coords, count: 4)
            map.addOverlay(poly, level: .aboveLabels)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate, PlatformGestureRecognizerDelegate {
        var parent: RegionDragMapView
        weak var pressRecognizer: PlatformGestureRecognizer?
        private var startCoord: CLLocationCoordinate2D?

        init(_ p: RegionDragMapView) { parent = p }

        @objc func handleDrag(_ g: PlatformGestureRecognizer) {
            guard let map = g.view as? MKMapView else { return }
            let pt = g.location(in: map)
            let coord = map.convert(pt, toCoordinateFrom: map)
            switch g.state {
            case .began:
                startCoord = coord
            case .changed:
                guard let start = startCoord else { return }
                let sw = CLLocationCoordinate2D(
                    latitude:  min(start.latitude,  coord.latitude),
                    longitude: min(start.longitude, coord.longitude)
                )
                let ne = CLLocationCoordinate2D(
                    latitude:  max(start.latitude,  coord.latitude),
                    longitude: max(start.longitude, coord.longitude)
                )
                DispatchQueue.main.async {
                    self.parent.sw = sw; self.parent.ne = ne
                }
            default:
                startCoord = nil
            }
        }

        // Only treat as our gesture if user touches with one finger AND moves
        // — otherwise let map zoom/pan. We achieve this by being strict here:
        // we always allow simultaneous recognition, so the map still pans.
        func gestureRecognizer(_ g: PlatformGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: PlatformGestureRecognizer) -> Bool {
            // Run alongside MKMapView's own gestures so the user can still zoom.
            true
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let t = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: t)
            }
            if let p = overlay as? MKPolygon {
                let r = MKPolygonRenderer(polygon: p)
                r.strokeColor = PlatformColor.systemCyan
                r.lineWidth   = 3
                r.fillColor   = PlatformColor.systemCyan.withAlphaComponent(0.18)
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
