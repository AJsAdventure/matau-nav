import Foundation
import Observation
import MapKit
import CoreLocation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - ContourService
//
// Loads bundled depth-contour + land-polygon GeoJSON files (one per region:
// messinia.geojson, paros.geojson, saronic.geojson, cyclades.geojson, ...)
// and hands them to the chart as MKPolygon overlays styled by depth band.
//
// Each region file is parsed once on first access and the resulting
// polygons cached in memory. The chart calls `polygonsFor(region:)` on
// every viewport change to get only the regions actually overlapping the
// visible bbox.

@Observable
@MainActor
final class ContourService {

    /// Cached parsed regions, keyed by file basename (e.g. "paros").
    private var cache: [String: RegionData] = [:]

    /// Bumped whenever a background parse lands — the chart observes this to
    /// pull freshly-parsed polygons in without polling.
    private(set) var revision = 0
    /// Regions currently being parsed off-main (dedup guard).
    private var parsing: Set<String> = []

    /// Discovered region files in the app bundle. Populated lazily on the
    /// first call to `polygonsFor`.
    private var manifest: [RegionMeta]?

    /// Returns every depth-band + land polygon whose region bbox overlaps
    /// `region`. Lazily loads region files that haven't been parsed yet.
    func polygonsFor(region: MKCoordinateRegion) -> [ContourPolygon] {
        let names = ensureManifest()
            .filter { $0.bbox.intersects(region) }
            .map(\.name)
            .sorted()
        // Same set of regions as last call? Return the cached array so we
        // don't churn MKPolygon overlays on every pan inside one tile.
        if names == lastNames, let cached = lastResult { return cached }
        var out: [ContourPolygon] = []
        // Evict parsed regions far from the viewport once we hold more than a
        // handful — each is 10-50 MB and a season of sailing would otherwise
        // pin every visited region in memory until app relaunch.
        if cache.count > 6 {
            let keep = Set(names)
            for k in cache.keys where !keep.contains(k) { cache.removeValue(forKey: k) }
        }
        var complete = true
        for n in names {
            if let data = cache[n] { out.append(contentsOf: data.polygons); continue }
            complete = false
            if let meta = ensureManifest().first(where: { $0.name == n }) {
                scheduleParse(meta)
            }
        }
        // Memoize only complete answers — a partial set must not become the
        // cached result for this name set once the parses finish.
        if complete {
            lastNames = names
            lastResult = out
        } else {
            lastNames = []
            lastResult = nil
        }
        return out
    }

    /// Parse a region file OFF the main actor. These files are 8-36 MB of
    /// GeoJSON; parsing one synchronously inside polygonsFor (as this used
    /// to) froze the UI for seconds on the first chart display of every
    /// region — the single worst perceived-launch cost of the app.
    private func scheduleParse(_ meta: RegionMeta) {
        guard !parsing.contains(meta.name) else { return }
        parsing.insert(meta.name)
        Task.detached(priority: .userInitiated) { [weak self] in
            let parsed = Self.parse(meta)
            await MainActor.run {
                guard let self else { return }
                self.cache[meta.name] = parsed
                self.parsing.remove(meta.name)
                self.lastNames = []
                self.lastResult = nil
                self.revision += 1
            }
        }
    }

    private var lastNames: [String] = []
    private var lastResult: [ContourPolygon]?

    // MARK: Manifest discovery

    private func ensureManifest() -> [RegionMeta] {
        if let m = manifest { return m }
        // xcodegen flattens folder structure into the bundle root by default,
        // but in case someone configures a folder reference later, accept
        // both layouts. Dedupe by URL.
        var seen = Set<URL>()
        var found: [RegionMeta] = []
        let scans = [
            Bundle.main.urls(forResourcesWithExtension: "geojson", subdirectory: "Contours") ?? [],
            Bundle.main.urls(forResourcesWithExtension: "geojson", subdirectory: nil) ?? [],
        ]
        for urls in scans {
            for url in urls where !seen.contains(url) {
                seen.insert(url)
                if let meta = peekBBox(url: url) {
                    found.append(meta)
                }
            }
        }
        #if DEBUG
        print("ContourService manifest: \(found.count) regions")
        for r in found {
            print("  \(r.name): \(r.bbox.minLat),\(r.bbox.minLon) → \(r.bbox.maxLat),\(r.bbox.maxLon)")
        }
        #endif
        manifest = found
        return found
    }

    /// Read just enough of the file to know its bounding box, without
    /// parsing every coordinate. We accept that this means streaming the
    /// JSON twice on first hit — acceptable since manifest is cached.
    private func peekBBox(url: URL) -> RegionMeta? {
        guard let data = try? Data(contentsOf: url),
              let any  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feats = any["features"] as? [[String: Any]] else { return nil }
        var minLat =  90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for ft in feats {
            guard let geom = ft["geometry"] as? [String: Any] else { continue }
            walkCoords(geom) { lon, lat in
                if lat < minLat { minLat = lat }
                if lat > maxLat { maxLat = lat }
                if lon < minLon { minLon = lon }
                if lon > maxLon { maxLon = lon }
            }
        }
        guard minLat <= maxLat else { return nil }
        let bbox = BBox(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
        return RegionMeta(name: url.deletingPathExtension().lastPathComponent,
                          url: url, bbox: bbox)
    }

    private func walkCoords(_ geom: [String: Any], _ visit: (Double, Double) -> Void) {
        guard let coords = geom["coordinates"] else { return }
        recurse(coords, visit)
    }
    private func recurse(_ any: Any, _ visit: (Double, Double) -> Void) {
        if let arr = any as? [Any] {
            // A coordinate pair: [lon, lat]
            if arr.count >= 2, let lon = arr[0] as? Double, let lat = arr[1] as? Double,
               !(arr[0] is [Any]) {
                visit(lon, lat); return
            }
            for sub in arr { recurse(sub, visit) }
        }
    }

    // MARK: Parse

    nonisolated private static func parse(_ meta: RegionMeta) -> RegionData {
        guard let data = try? Data(contentsOf: meta.url),
              let any  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feats = any["features"] as? [[String: Any]] else {
            return RegionData(polygons: [])
        }
        var polys: [ContourPolygon] = []
        for ft in feats {
            guard let props = ft["properties"] as? [String: Any],
                  let geom  = ft["geometry"]   as? [String: Any] else { continue }
            let kind = props["kind"] as? String
            let depthMin = props["depth_min"] as? Double
            let depthMax = props["depth_max"] as? Double
            let band: ContourPolygon.Band
            if kind == "land" {
                band = .land
            } else if let dmax = depthMax {
                band = .depth(minM: depthMin ?? -1e9, maxM: dmax)
            } else {
                continue
            }
            // Geometry can be Polygon or MultiPolygon.
            let type = geom["type"] as? String ?? ""
            if type == "Polygon" {
                if let rings = geom["coordinates"] as? [[[Double]]] {
                    let p = makePolygon(rings: rings, band: band)
                    polys.append(p)
                }
            } else if type == "MultiPolygon" {
                if let polysRaw = geom["coordinates"] as? [[[[Double]]]] {
                    for rings in polysRaw {
                        let p = makePolygon(rings: rings, band: band)
                        polys.append(p)
                    }
                }
            }
        }
        return RegionData(polygons: polys)
    }

    nonisolated private static func makePolygon(rings: [[[Double]]],
                             band: ContourPolygon.Band) -> ContourPolygon {
        // First ring is the outer; rest are holes.
        let outer = rings.first?.compactMap { coord -> CLLocationCoordinate2D? in
            guard coord.count >= 2 else { return nil }
            return .init(latitude: coord[1], longitude: coord[0])
        } ?? []
        let holes: [[CLLocationCoordinate2D]] = rings.dropFirst().map { ring in
            ring.compactMap { coord -> CLLocationCoordinate2D? in
                guard coord.count >= 2 else { return nil }
                return .init(latitude: coord[1], longitude: coord[0])
            }
        }
        return ContourPolygon(outer: outer, holes: holes, band: band)
    }
}

// MARK: - Helpers

private struct RegionMeta {
    let name: String
    let url: URL
    let bbox: BBox
}

private struct RegionData { let polygons: [ContourPolygon] }

private struct BBox {
    let minLat, minLon, maxLat, maxLon: Double
    func intersects(_ region: MKCoordinateRegion) -> Bool {
        let rMin = region.center.latitude  - region.span.latitudeDelta  / 2
        let rMax = region.center.latitude  + region.span.latitudeDelta  / 2
        let cMin = region.center.longitude - region.span.longitudeDelta / 2
        let cMax = region.center.longitude + region.span.longitudeDelta / 2
        return !(maxLat < rMin || minLat > rMax || maxLon < cMin || minLon > cMax)
    }
}

// MARK: - ContourPolygon

struct ContourPolygon {
    let outer: [CLLocationCoordinate2D]
    let holes: [[CLLocationCoordinate2D]]
    let band: Band

    enum Band {
        case depth(minM: Double, maxM: Double)
        case land
    }

    /// Fill colour. Land is opaque tan; depth bands are translucent blue that
    /// darkens with depth, so shallow water reads pale and deep water deep —
    /// the classic chart "depth shading" look. Bands are cut with holes for
    /// the next-deeper isobath, so adjacent bands meet cleanly without stacking.
    var fillColor: PlatformColor {
        switch band {
        case .land:
            return PlatformColor(red: 0.96, green: 0.94, blue: 0.85, alpha: 0.92)
        case .depth(_, let maxM):
            // maxM is the shallow edge of the band (e.g. 0, -2, -5 … ).
            let shallow = max(0, -maxM)            // 0, 2, 5, 10, 15, 20, 25, 50…
            let t = min(1, shallow / 40)           // 0 (shore) → 1 (≥40 m)
            return PlatformColor(red:  0.78 - 0.62 * t,
                           green: 0.90 - 0.55 * t,
                           blue:  0.98 - 0.40 * t,
                           alpha: 0.55)
        }
    }

    /// Stroke colour for the contour line drawn at this band's outer ring.
    /// For a band(-X, 0), the outer ring is the X-metre isobath.
    /// For land, the outer ring is the OSM coastline (= 0 m line).
    var lineColor: PlatformColor {
        switch band {
        case .land:
            // Coast: solid dark grey-blue, contrasts on satellite.
            return PlatformColor(red: 0.10, green: 0.18, blue: 0.30, alpha: 0.95)
        case .depth(let minM, _):
            // depth_min is the deeper (more negative) bound = the contour
            // level of the band's outer ring.
            let d = max(0, -minM)        // 2, 5, 10, 15, 20, 25, 50, 100
            // Light blue across all levels; deeper isobaths a hair darker.
            let darken = min(0.35, d / 200.0)
            return PlatformColor(red: 0.20 + darken * 0.05,
                           green: 0.45 + darken * 0.10,
                           blue:  0.75 + darken * 0.10,
                           alpha: 0.85)
        }
    }

    /// Stroke width in points. Majors (10, 50, 100) drawn a touch thicker
    /// so the eye finds them, in the spirit of paper charts.
    var lineWidth: CGFloat {
        switch band {
        case .land: return 1.4
        case .depth(let minM, _):
            switch -minM {
            case 10, 50, 100: return 1.2
            default:          return 0.8
            }
        }
    }

    /// Stable but cheap fingerprint. Used by the chart's overlay cache
    /// to decide whether SwiftUI's regenerated array is actually new
    /// content or just a re-emission of the same set.
    var identityHash: Int {
        var h = Hasher()
        h.combine(outer.count)
        h.combine(holes.count)
        if let first = outer.first {
            h.combine(Int(first.latitude  * 1e6))
            h.combine(Int(first.longitude * 1e6))
        }
        switch band {
        case .land: h.combine(0)
        case .depth(let mn, let mx):
            h.combine(Int(mn * 10))
            h.combine(Int(mx * 10))
        }
        return h.finalize()
    }

    /// MapKit polygon (outer + holes).
    var mkPolygon: MKPolygon {
        if holes.isEmpty {
            return MKPolygon(coordinates: outer, count: outer.count)
        }
        let interiors = holes.map { ring in
            MKPolygon(coordinates: ring, count: ring.count)
        }
        return MKPolygon(coordinates: outer, count: outer.count,
                         interiorPolygons: interiors)
    }
}

/// Tagged subclass for depth-contour lines. The outer ring of each
/// depth-band polygon becomes one of these.
final class ContourMKPolyline: MKPolyline {
    var strokeColor: PlatformColor = .clear
    var lineWidth:   CGFloat = 1
}

/// Tagged subclass so the renderer can distinguish our polygons from
/// other MKPolygon overlays (waypoint route line etc.).
final class ContourMKPolygon: MKPolygon {
    var fillColor:   PlatformColor = .clear
    var strokeColor: PlatformColor = .clear
    var lineWidth:   CGFloat = 0

    /// Build a polyline tracing this polygon's outer ring — the contour
    /// line at the band's depth_min level (or the OSM coast for land).
    /// We pass through a Catmull-Rom interpolator before constructing the
    /// MKPolyline so each pixel-grid segment from gdal_contour becomes a
    /// short smooth curve. MapKit only knows how to draw straight segments
    /// between vertices, so we densify here.
    static func polyline(for cp: ContourPolygon) -> ContourMKPolyline {
        let smoothed = catmullRomSmoothClosed(cp.outer, subdivisions: 4)
        let line = smoothed.withUnsafeBufferPointer { buf in
            ContourMKPolyline(coordinates: buf.baseAddress!, count: smoothed.count)
        }
        line.strokeColor = cp.lineColor
        line.lineWidth   = cp.lineWidth
        return line
    }

    /// Build an outline-only polygon for a depth band — outer ring of the
    /// contour, no holes, no fill. We render isobaths this way (instead of
    /// MKPolyline) so they go through the same proven MKPolygonRenderer
    /// path that already works for the land coast. Result: one polygon
    /// per island per level, drawn as a thin stroked ring with empty fill.
    static func outline(for cp: ContourPolygon) -> ContourMKPolygon {
        let smoothed = catmullRomSmoothClosed(cp.outer, subdivisions: 4)
        let poly = smoothed.withUnsafeBufferPointer { buf in
            ContourMKPolygon(coordinates: buf.baseAddress!, count: smoothed.count)
        }
        poly.fillColor   = .clear
        poly.strokeColor = cp.lineColor
        poly.lineWidth   = cp.lineWidth
        return poly
    }

    /// Convert a `ContourPolygon` (outer ring + holes + band) into a
    /// MapKit polygon with `fillColor` pre-computed from the band.
    static func from(_ cp: ContourPolygon) -> ContourMKPolygon {
        let interiors: [MKPolygon] = cp.holes.map { ring in
            ring.withUnsafeBufferPointer { buf in
                MKPolygon(coordinates: buf.baseAddress!, count: ring.count)
            }
        }
        let poly = cp.outer.withUnsafeBufferPointer { buf in
            interiors.isEmpty
                ? ContourMKPolygon(coordinates: buf.baseAddress!, count: cp.outer.count)
                : ContourMKPolygon(coordinates: buf.baseAddress!, count: cp.outer.count,
                                   interiorPolygons: interiors)
        }
        poly.fillColor   = cp.fillColor
        poly.strokeColor = cp.lineColor
        poly.lineWidth   = cp.lineWidth
        return poly
    }
}

/// Centripetal-ish Catmull-Rom subdivision of a closed ring. Each input
/// segment is replaced by `subdivisions` short straight chords that follow
/// the spline through (P0, P1, P2, P3). Result reads as a smooth curve at
/// any zoom MapKit will render at, without us having to write a custom
/// renderer or rebuild the source GeoJSON.
///
/// Input ring may end with a duplicated first vertex (GeoJSON convention);
/// we strip that before treating it as cyclic.
func catmullRomSmoothClosed(_ pts: [CLLocationCoordinate2D],
                            subdivisions: Int = 4) -> [CLLocationCoordinate2D] {
    guard pts.count >= 4 else { return pts }
    var p = pts
    if let first = p.first, let last = p.last,
       first.latitude == last.latitude, first.longitude == last.longitude {
        p.removeLast()
    }
    let n = p.count
    if n < 4 { return pts }

    var out: [CLLocationCoordinate2D] = []
    out.reserveCapacity(n * subdivisions + 1)
    for i in 0..<n {
        let p0 = p[(i - 1 + n) % n]
        let p1 = p[i]
        let p2 = p[(i + 1) % n]
        let p3 = p[(i + 2) % n]
        for j in 0..<subdivisions {
            let t  = Double(j) / Double(subdivisions)
            let t2 = t * t
            let t3 = t2 * t
            let b0 = -0.5*t  +     t2 - 0.5*t3
            let b1 =  1.0    - 2.5*t2 + 1.5*t3
            let b2 =  0.5*t  + 2.0*t2 - 1.5*t3
            let b3 =          -0.5*t2 + 0.5*t3
            let lat = b0*p0.latitude  + b1*p1.latitude  + b2*p2.latitude  + b3*p3.latitude
            let lon = b0*p0.longitude + b1*p1.longitude + b2*p2.longitude + b3*p3.longitude
            out.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
    }
    if let first = out.first { out.append(first) }   // close the ring
    return out
}
