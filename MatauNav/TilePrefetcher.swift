import Foundation
import MapKit

// MARK: - TilePrefetcher
//
// Background-fetches tiles around what's currently on screen so the next pan
// or pinch hits the disk cache instead of a network round-trip. Called from
// the chart's `regionDidChangeAnimated` delegate.
//
// Strategy:
//   • For the *current* zoom level, prefetch one ring of tiles outside the
//     visible bounds (so pans of up to a screen-width feel instant).
//   • For zoom-1 and zoom+1, prefetch only the visible bounds (so zoom
//     pinches feel instant).
//   • Skip tiles already on disk and dedupe in-flight URLs so quick
//     repeated region changes don't pile up requests.
//   • Cap concurrency at 4 — we don't want to compete with MapKit's own
//     visible-tile fetches.

final class TilePrefetcher: @unchecked Sendable {

    static let shared = TilePrefetcher()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 6
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private let q = DispatchQueue(label: "matau.tile.prefetch", qos: .utility, attributes: .concurrent)
    private let stateLock = NSLock()
    private var inFlight = Set<String>()              // dedupe key: "style/z/x/y"
    private var pendingToken: UUID?                   // most-recent prefetch request

    /// Public entry. Cancels any prior batch and starts a new one for `region`.
    /// `seamark` and `satellite` mirror the current chart toggles so we only
    /// warm what the user is actually looking at.
    func prefetch(region: MKCoordinateRegion,
                  zoom: Int,
                  satellite: Bool,
                  seamark: Bool,
                  bathymetry: Bool = false) {

        // Bump the token; in-flight callbacks for older tokens will exit.
        let token = UUID()
        stateLock.lock(); pendingToken = token; stateLock.unlock()

        // Visible tile range at this zoom
        let z = max(1, min(18, zoom))
        let minLat = region.center.latitude  - region.span.latitudeDelta  / 2
        let maxLat = region.center.latitude  + region.span.latitudeDelta  / 2
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2

        // Current zoom: visible bounds + 1-tile ring
        enqueueRange(z: z, minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon,
                     pad: 1, satellite: satellite, seamark: seamark, bathymetry: bathymetry, token: token)

        // ±1 zoom (no padding — just the visible area, less data)
        if z + 1 <= 18 {
            enqueueRange(z: z + 1, minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon,
                         pad: 0, satellite: satellite, seamark: seamark, bathymetry: bathymetry, token: token)
        }
        if z - 1 >= 1 {
            enqueueRange(z: z - 1, minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon,
                         pad: 0, satellite: satellite, seamark: seamark, bathymetry: bathymetry, token: token)
        }
    }

    private func enqueueRange(z: Int,
                              minLat: Double, minLon: Double,
                              maxLat: Double, maxLon: Double,
                              pad: Int,
                              satellite: Bool, seamark: Bool, bathymetry: Bool,
                              token: UUID) {
        var x0 = TileMath.lonToTileX(minLon, z: z) - pad
        var x1 = TileMath.lonToTileX(maxLon, z: z) + pad
        var y0 = TileMath.latToTileY(maxLat, z: z) - pad
        var y1 = TileMath.latToTileY(minLat, z: z) + pad
        let lim = 1 << z
        x0 = max(0, x0); x1 = min(lim - 1, x1)
        y0 = max(0, y0); y1 = min(lim - 1, y1)
        guard x1 >= x0, y1 >= y0 else { return }

        // Hard cap per region change to avoid runaway downloads at low zoom
        var budget = 80

        for x in x0...x1 {
            for y in y0...y1 {
                if budget <= 0 { return }
                budget -= 1
                fetch(style: satellite ? "satellite" : "standard",
                      z: z, x: x, y: y, token: token)
                if bathymetry, z >= 6 {
                    fetch(style: "bathymetry", z: z, x: x, y: y, token: token)
                }
                if seamark, z >= 11 {
                    fetch(style: "seamark", z: z, x: x, y: y, token: token)
                }
            }
        }
    }

    private func fetch(style: String, z: Int, x: Int, y: Int, token: UUID) {
        let key = "\(style)/\(z)/\(x)/\(y)"
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder: String
        switch style {
        case "satellite":  folder = "matau_tiles_satellite"
        case "seamark":    folder = "matau_tiles_seamark"
        case "bathymetry": folder = "matau_tiles_bathymetry"
        default:           folder = "matau_tiles_standard"
        }
        let dir  = caches.appendingPathComponent(folder)
                         .appendingPathComponent("\(z)")
                         .appendingPathComponent("\(x)")
        let file = dir.appendingPathComponent("\(y).tile")
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 0 { return }       // already cached

        // Dedupe
        stateLock.lock()
        if inFlight.contains(key) || pendingToken != token {
            stateLock.unlock(); return
        }
        inFlight.insert(key)
        stateLock.unlock()

        let url: URL = {
            switch style {
            case "satellite":
                return URL(string: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/\(z)/\(y)/\(x)")!
            case "seamark":
                return URL(string: "https://tiles.openseamap.org/seamark/\(z)/\(x)/\(y).png")!
            case "bathymetry":
                return URL(string: "https://tiles.emodnet-bathymetry.eu/latest/mean_multicolour/web_mercator/\(z)/\(x)/\(y).png")!
            default:
                let s = ["a", "b", "c"][(x + y) % 3]
                return URL(string: "https://\(s).tile.openstreetmap.org/\(z)/\(x)/\(y).png")!
            }
        }()
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue("MatauNav/1.0 (sailing chart prefetch)", forHTTPHeaderField: "User-Agent")

        q.async { [weak self] in
            guard let self else { return }
            // Token check before issuing the request — user may have moved on
            self.stateLock.lock()
            let stillCurrent = (self.pendingToken == token)
            self.stateLock.unlock()
            guard stillCurrent else {
                self.markDone(key: key); return
            }

            self.session.dataTask(with: req) { [weak self] data, resp, _ in
                guard let self else { return }
                defer { self.markDone(key: key) }
                guard let data,
                      (resp as? HTTPURLResponse)?.statusCode == 200,
                      TileImageValidator.looksLikeImage(data) else { return }
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: file)
            }.resume()
        }
    }

    private func markDone(key: String) {
        stateLock.lock(); inFlight.remove(key); stateLock.unlock()
    }
}
