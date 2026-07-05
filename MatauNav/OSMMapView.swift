import Foundation
import MapKit
import SwiftUI
import Network
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Internet reachability tracker
//
// Tracks tile fetch success/failure to detect whether internet is reachable
// on the current network. When the device is on a local-only network (e.g. Pi's
// Wi-Fi with no gateway) consecutive tile failures quickly flip the tracker into
// offline mode, switching loadTile to an instant cache-only path so there are no
// 10-second timeouts clogging the map. After 60 s the tracker resets and tries
// the network again — automatically recovering when internet returns.
//
// NWPathMonitor tells us if a cellular interface is in use; cellular always has
// an internet gateway, so we skip the failure-tracking shortcut on cellular.

final class TileNetworkTracker: @unchecked Sendable {

    static let shared = TileNetworkTracker()

    private let q = DispatchQueue(label: "matau.tile.tracker", qos: .utility)
    private var failureCount  = 0
    private var offlineUntil: Date = .distantPast
    private var hasCellular   = false

    private let pathMonitor = NWPathMonitor()

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let cellular = path.usesInterfaceType(.cellular)
            self?.q.async { self?.hasCellular = cellular }
        }
        pathMonitor.start(queue: q)
    }

    /// `true` → skip the network and serve only from disk cache.
    var shouldSkipNetwork: Bool {
        q.sync {
            if hasCellular { return false }          // cellular always has internet
            return Date() < offlineUntil
        }
    }

    func recordSuccess() {
        q.async { [self] in
            failureCount = 0
            offlineUntil = .distantPast
        }
    }

    func recordFailure() {
        q.async { [self] in
            failureCount += 1
            if failureCount >= 3 && offlineUntil <= .distantPast {
                // Mark offline for 60 s, then automatically retry
                offlineUntil = Date().addingTimeInterval(60)
            }
        }
    }
}

// MARK: - Image validator
//
// Tile servers occasionally return a 200-OK response whose body is HTML, an
// XML error, a redirect page, or a tiny placeholder. Caching those poisons
// the chart forever (cache-first reads junk; MapKit then logs "Failed to
// decode key"). We accept only payloads that start with a PNG/JPEG/GIF/WebP
// magic byte sequence.

enum TileImageValidator {
    static func looksLikeImage(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let b = [UInt8](data.prefix(12))
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true }
        // JPEG: FF D8 FF
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return true }
        // GIF87a / GIF89a
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return true }
        // WebP: RIFF....WEBP
        if data.count >= 12,
           b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return true }
        return false
    }
}

// MARK: - Disk-cached tile overlay
//
// Two tile sources, both non-Apple CDN so they work even when Apple's map
// servers are unreachable (common on marina/satellite internet):
//
//   .standard  → OpenStreetMap  (tile.openstreetmap.org)
//   .satellite → ESRI World Imagery (server.arcgisonline.com) — free, no key
//
// Tiles are cached to <Caches>/matau_tiles_{standard|satellite}/{z}/{x}/{y}
// and served from disk on subsequent opens — fully offline once an area is cached.

final class OSMTileOverlay: MKTileOverlay {

    enum Style { case standard, satellite, seamark, bathymetry }

    let style: Style

    private let cacheRoot: URL

    init(style: Style = .standard) {
        self.style = style
        let name: String
        switch style {
        case .standard:   name = "matau_tiles_standard"
        case .satellite:  name = "matau_tiles_satellite"
        case .seamark:    name = "matau_tiles_seamark"
        case .bathymetry: name = "matau_tiles_bathymetry"
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheRoot = caches.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        super.init(urlTemplate: nil)
        // Seamark and bathymetry are transparent overlays — must NOT replace
        // the base map.
        canReplaceMapContent = (style == .standard || style == .satellite)
        minimumZ = 1
        maximumZ = 19
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        switch style {
        case .standard:
            // Round-robin across OSM tile servers a/b/c
            let servers = ["a", "b", "c"]
            let s = servers[(path.x + path.y) % servers.count]
            return URL(string: "https://\(s).tile.openstreetmap.org/\(path.z)/\(path.x)/\(path.y).png")!
        case .satellite:
            // ESRI World Imagery — note: ESRI uses z/y/x order (not z/x/y)
            return URL(string: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/\(path.z)/\(path.y)/\(path.x)")!
        case .seamark:
            // OpenSeaMap seamark overlay — transparent PNGs with buoys, lights, marks.
            // We use the canonical `tiles.openseamap.org` endpoint (proper Let's-
            // Encrypt cert). The historical t1/t2/t3 shards currently serve a
            // default Traefik certificate, which iOS ATS refuses to trust.
            return URL(string: "https://tiles.openseamap.org/seamark/\(path.z)/\(path.x)/\(path.y).png")!
        case .bathymetry:
            // EMODnet Bathymetry — public WMTS, CC-BY 4.0. URL shape:
            //   /{version}/{layer}/{TileMatrixSet}/{z}/{x}/{y}.png
            //
            // We use the `mean_multicolour` layer (no land, full multi-colour
            // depth ramp) — best looking over a chart base. `latest` follows
            // the most recent EMODnet release. `web_mercator` matches MapKit.
            return URL(string: "https://tiles.emodnet-bathymetry.eu/latest/mean_multicolour/web_mercator/\(path.z)/\(path.x)/\(path.y).png")!
        }
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {

        // Skip layers at zoom levels where their renderers return blank
        // tiles — saves round-trips for no visual gain.
        //   • Seamark: nothing below z11
        //   • EMODnet bathymetry: data is sparse below z6 (world-scale)
        if style == .seamark,    path.z < 11 { result(nil, nil); return }
        if style == .bathymetry, path.z < 6  { result(nil, nil); return }

        let dir  = cacheRoot
            .appendingPathComponent("\(path.z)")
            .appendingPathComponent("\(path.x)")
        let file = dir.appendingPathComponent("\(path.y).tile")

        // ── Cache-first ────────────────────────────────────────────────────
        // Once a tile has been seen (in normal use, downloaded, or prefetched)
        // we serve it from disk immediately — zero latency, works offline.
        // We require the cached bytes to look like an image; without this,
        // an earlier session that recorded a 200-OK error page would poison
        // the cache forever and MapKit would log "Failed to decode key".
        if let cached = try? Data(contentsOf: file), TileImageValidator.looksLikeImage(cached) {
            result(cached, nil)
            return
        } else {
            // Drop the junk so the next render attempt re-fetches.
            try? FileManager.default.removeItem(at: file)
        }

        // No cache yet — and we already know there's no internet on this
        // network. Surface a blank tile instantly so MapKit doesn't spin.
        if TileNetworkTracker.shared.shouldSkipNetwork {
            result(nil, nil)
            return
        }

        // First time we've ever seen this tile. Fetch over the network and
        // cache for next time.
        var req = URLRequest(url: url(forTilePath: path), timeoutInterval: 4)
        req.setValue("MatauNav/1.0 (sailing navigation; contact tileuse@matau.local)",
                     forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let data,
               (response as? HTTPURLResponse)?.statusCode == 200,
               TileImageValidator.looksLikeImage(data) {
                TileNetworkTracker.shared.recordSuccess()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: file)
                result(data, nil)
            } else {
                if error != nil { TileNetworkTracker.shared.recordFailure() }
                result(nil, error)
            }
        }.resume()
    }
}

// MARK: - Zoom proxy

final class MapZoomProxy: ObservableObject {
    weak var mapView: MKMapView?

    func zoomIn() {
        guard let map = mapView else { return }
        var r = map.region
        r.span.latitudeDelta  = max(r.span.latitudeDelta  / 2.0, 0.0005)
        r.span.longitudeDelta = max(r.span.longitudeDelta / 2.0, 0.0005)
        map.setRegion(r, animated: true)
    }

    func zoomOut() {
        guard let map = mapView else { return }
        var r = map.region
        r.span.latitudeDelta  = min(r.span.latitudeDelta  * 2.0, 60.0)
        r.span.longitudeDelta = min(r.span.longitudeDelta * 2.0, 60.0)
        map.setRegion(r, animated: true)
    }
}

// MARK: - Custom annotations

final class VesselAnnotation: NSObject, MKAnnotation {
    var coordinate: CLLocationCoordinate2D
    init(_ c: CLLocationCoordinate2D) { coordinate = c }
}

final class WaypointPinAnnotation: NSObject, MKAnnotation {
    var coordinate: CLLocationCoordinate2D
    init(_ c: CLLocationCoordinate2D) { coordinate = c }
}

// MARK: - Map picker view (UIViewRepresentable)

struct OSMMapPickerView: PlatformViewRepresentable {
    let initialCenter:    CLLocationCoordinate2D
    let vesselCoordinate: CLLocationCoordinate2D
    @Binding var pickedCoord: CLLocationCoordinate2D?
    var onPick:    (CLLocationCoordinate2D) -> Void
    var zoomProxy: MapZoomProxy
    var satellite: Bool = false

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
        map.delegate        = context.coordinator
        map.showsCompass    = true
        map.showsScale      = true
        map.isRotateEnabled = false

        // Add initial tile overlay (standard OSM)
        map.addOverlay(OSMTileOverlay(style: .standard), level: .aboveRoads)
        context.coordinator.currentSatellite = false

        // Click (macOS) / tap (iOS) to pick a coordinate.
        #if os(macOS)
        let pick = NSClickGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleTap(_:)))
        #else
        let pick = UITapGestureRecognizer(target: context.coordinator,
                                          action: #selector(Coordinator.handleTap(_:)))
        #endif
        map.addGestureRecognizer(pick)

        map.setRegion(.init(center: initialCenter,
                            span: .init(latitudeDelta: 0.04, longitudeDelta: 0.04)),
                      animated: false)
        zoomProxy.mapView = map
        return map
    }

    func syncMap(_ map: MKMapView, context: Context) {
        // Swap tile overlay only when satellite mode changes — avoids
        // flushing the tile cache on every vessel-position tick (0.5 s)
        if context.coordinator.currentSatellite != satellite {
            context.coordinator.currentSatellite = satellite
            map.removeOverlays(map.overlays)
            map.addOverlay(OSMTileOverlay(style: satellite ? .satellite : .standard),
                           level: .aboveRoads)
        }

        // Rebuild annotations
        map.removeAnnotations(map.annotations)
        map.addAnnotation(VesselAnnotation(vesselCoordinate))
        if let c = pickedCoord { map.addAnnotation(WaypointPinAnnotation(c)) }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: OSMMapPickerView
        var currentSatellite: Bool = false

        init(_ p: OSMMapPickerView) { parent = p }

        @objc func handleTap(_ g: PlatformGestureRecognizer) {
            guard let map = g.view as? MKMapView else { return }
            let coord = map.convert(g.location(in: map), toCoordinateFrom: map)
            DispatchQueue.main.async {
                self.parent.pickedCoord = coord
                self.parent.onPick(coord)
            }
        }

        func mapView(_ map: MKMapView,
                     rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let t = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: t)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ map: MKMapView,
                     viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case is VesselAnnotation:
                let v = MKAnnotationView(annotation: annotation, reuseIdentifier: "vessel")
                v.image = makeVesselDot()
                v.centerOffset = .zero
                return v
            case is WaypointPinAnnotation:
                let v = MKAnnotationView(annotation: annotation, reuseIdentifier: "waypoint")
                v.image = makeWaypointFlag()
                v.centerOffset = CGPoint(x: 0, y: -12)
                return v
            default:
                return nil
            }
        }

        private func makeVesselDot() -> PlatformImage {
            let s: CGFloat = 22
            return makeIcon(size: .init(width: s, height: s)) { ctx in
                PlatformColor.systemCyan.withAlphaComponent(0.28).setFill()
                ctx.fillEllipse(in: .init(x: 0, y: 0, width: s, height: s))
                PlatformColor.systemCyan.setFill()
                ctx.fillEllipse(in: .init(x: s*0.32, y: s*0.32,
                                          width: s*0.36, height: s*0.36))
            }
        }

        private func makeWaypointFlag() -> PlatformImage {
            tintedSymbol("flag.fill", pointSize: 22, weight: .bold, color: .systemOrange)
        }
    }
}
