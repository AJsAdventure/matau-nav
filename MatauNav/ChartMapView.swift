import SwiftUI
import MapKit
import CoreLocation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Vessel / AIS / Waypoint / Measurement annotations & overlays

final class HeadedVesselAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var heading: Double
    var cog: Double
    var sog: Double
    var twa: Double          // signed deg
    var tws: Double          // knots
    init(coord: CLLocationCoordinate2D, heading: Double, cog: Double, sog: Double, twa: Double, tws: Double) {
        self.coordinate = coord; self.heading = heading; self.cog = cog
        self.sog = sog; self.twa = twa; self.tws = tws
    }
}

final class AISAnnotation: NSObject, MKAnnotation {
    private(set) var target: AISTarget
    private(set) var friend: AISFriend?
    private(set) var danger: Bool                 // CPA/TCPA under threshold → red highlight
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { friend?.name ?? target.name ?? "MMSI \(target.mmsi)" }
    init(_ t: AISTarget, friend: AISFriend? = nil, danger: Bool = false) {
        target = t; self.friend = friend; self.danger = danger
        coordinate = .init(latitude: t.latitude, longitude: t.longitude)
    }
    /// Update in place; returns true if the icon needs redrawing.
    @discardableResult
    func apply(_ t: AISTarget, friend: AISFriend?, danger: Bool) -> Bool {
        let iconChanged = danger != self.danger
            || (friend != nil) != (self.friend != nil)
            || abs(t.cog - target.cog) > 1
            || t.heading != target.heading
        target = t; self.friend = friend; self.danger = danger
        coordinate = .init(latitude: t.latitude, longitude: t.longitude)
        return iconChanged
    }
}

/// PredictWind commercial AIS from the tile API — separate from aisstream.io data.
final class PWAISAnnotation: NSObject, MKAnnotation {
    private(set) var target: PWAISTarget
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { "\(target.type) · \(String(format: "%.1f", target.speed))kn" }
    init(_ t: PWAISTarget) { target = t; coordinate = .init(latitude: t.lat, longitude: t.lon) }
    @discardableResult
    func apply(_ t: PWAISTarget) -> Bool {
        let iconChanged = t.type != target.type || abs(t.heading - target.heading) > 1
        target = t; coordinate = .init(latitude: t.lat, longitude: t.lon)
        return iconChanged
    }
}

final class RouteWaypointAnnotation: NSObject, MKAnnotation {
    let index: Int
    let isActive: Bool
    let title: String?
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(coord: CLLocationCoordinate2D, index: Int, isActive: Bool, name: String) {
        self.coordinate = coord
        self.index = index
        self.isActive = isActive
        self.title = name
    }
}

final class MOBAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(_ c: CLLocationCoordinate2D) { coordinate = c }
}

final class AnchorAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(_ c: CLLocationCoordinate2D) { coordinate = c }
}

final class WaypointAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(_ c: CLLocationCoordinate2D) { coordinate = c }
}

final class MeasureEndpointAnnotation: NSObject, MKAnnotation {
    enum Role { case from, to }
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let role: Role
    init(_ c: CLLocationCoordinate2D, role: Role) {
        self.coordinate = c; self.role = role
    }
}

// Polyline tagged with a PlatformColor so the renderer can pick per-track colors
final class ColoredPolyline: MKPolyline {
    var strokeColor: PlatformColor = .systemCyan
    var lineWidth: CGFloat = 3
    var dashed: Bool = false
}

// Filled circle used for AIS guard zone
final class ColoredCircle: MKCircle {
    var strokeColor: PlatformColor = .systemRed
    var fillColor:   PlatformColor = .systemRed.withAlphaComponent(0.06)
    var lineWidth: CGFloat = 1.5
    var dashed: Bool = true
}

// MARK: - ChartMapView

struct ChartMapView: PlatformViewRepresentable {
    let initialCenter: CLLocationCoordinate2D
    let vesselLat: Double
    let vesselLon: Double
    let heading:   Double
    let cog:       Double
    let sog:       Double
    let trueWindAngle: Double
    let trueWindSpeed: Double
    let satellite: Bool
    let seamark:   Bool
    let bathymetry: Bool
    /// Bundled depth-band + land polygons covering the visible region.
    let contourPolygons: [ContourPolygon]
    let follow:    Bool
    let northUp:   Bool
    let showAIS:   Bool
    let aisTargets: [AISTarget]
    let aisFriends: [Int: AISFriend]     // keyed by MMSI for fast lookup
    let tracks:    [Track]
    let waypoint:  CLLocationCoordinate2D?
    let mobCoord:  CLLocationCoordinate2D?
    // Tactical overlays
    let predictorMinutes: Int                                  // 0 disables
    let laylineWaypoint: CLLocationCoordinate2D?               // nil disables
    let trueWindDirection: Double                              // deg true
    let tackAngleDeg: Double
    let route: Route?
    let guardZoneRadiusNm: Double                              // 0 disables
    let dangerousMMSIs: Set<Int>                               // AIS targets to highlight red
    let showPredictWindAIS: Bool
    let pwAISTargets: [PWAISTarget]
    // Anchor mode overlays
    let anchorMode:       Bool
    let anchorActive:     Bool
    let anchorLat:        Double
    let anchorLon:        Double
    let anchorRadius:     Double
    let anchorFlash:      Bool
    let anchorInitialTWD: Double
    let anchorWindShift:  Double
    let anchorWarnRadius: Double                   // inner warning ring (m); 0 hides
    let anchorSwingTrack: [CLLocationCoordinate2D]  // recent swing breadcrumb fan
    let anchorSwinging:   Bool                     // false ⇒ fixed mooring (no swing sector)
    /// Called when the user drags the anchor pin to a new position.
    let onAnchorMoved:    (CLLocationCoordinate2D) -> Void
    let onAnnotationLongPress: (CLLocationCoordinate2D) -> Void
    let onUserGesture: () -> Void          // Fired when the user pans/pinches; chart turns off Follow.
    let onRegionChange: (MKCoordinateRegion) -> Void   // Fired after pan/zoom; triggers contour refresh.
    let measureMode: Bool
    @Binding var measureFrom: CLLocationCoordinate2D?
    @Binding var measureTo:   CLLocationCoordinate2D?
    let onMapTap:  (CLLocationCoordinate2D) -> Void
    let onAISTap:  (AISTarget) -> Void
    let zoomProxy: MapZoomProxy

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    #if os(macOS)
    func makeNSView(context: Context) -> MKMapView { makeMap(context) }
    func updateNSView(_ map: MKMapView, context: Context) { syncMap(map, context: context) }
    #else
    func makeUIView(context: Context) -> MKMapView { makeMap(context) }
    func updateUIView(_ map: MKMapView, context: Context) { syncMap(map, context: context) }
    #endif

    /// Install the platform input stack. iOS: tap / long-press / pan+pinch
    /// observers. macOS: left-click, right-click context menu, pan+magnify
    /// observers so the chart drops Follow on user manipulation.
    private func installGestures(on map: MKMapView, coordinator c: Coordinator) {
        #if os(macOS)
        let click = NSClickGestureRecognizer(target: c, action: #selector(Coordinator.handleClick(_:)))
        click.delegate = c
        map.addGestureRecognizer(click)

        let rightClick = NSClickGestureRecognizer(target: c, action: #selector(Coordinator.handleRightClick(_:)))
        rightClick.buttonMask = 0x2          // right mouse button → context menu
        rightClick.delegate = c
        map.addGestureRecognizer(rightClick)

        let pan = NSPanGestureRecognizer(target: c, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = c
        map.addGestureRecognizer(pan)
        // NOTE: do NOT add an NSMagnificationGestureRecognizer here — it competes
        // with and suppresses MKMapView's built-in pinch zoom. Native pinch zooms
        // around the vessel while Follow is on (camera recenters at the new span),
        // or freely once Follow is off via pan/scroll.
        #else
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = c
        map.addGestureRecognizer(tap)

        let press = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.handleLongPress(_:)))
        press.minimumPressDuration = 0.5
        press.delegate = c
        map.addGestureRecognizer(press)

        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handleUserGesture(_:)))
        pan.delegate = c
        pan.cancelsTouchesInView = false
        map.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.handleUserGesture(_:)))
        pinch.delegate = c
        pinch.cancelsTouchesInView = false
        map.addGestureRecognizer(pinch)
        #endif
    }

    func makeMap(_ context: Context) -> MKMapView {
        #if os(macOS)
        let map = ScrollZoomMapView()
        // Mouse-wheel zoom counts as user interaction → drop Follow.
        map.onScrollZoom = { [weak c = context.coordinator] in c?.parent.onUserGesture() }
        #else
        let map = MKMapView()
        #endif
        map.delegate = context.coordinator
        map.showsCompass = false
        map.showsScale   = true
        map.isRotateEnabled = false           // chart is always north-up
        map.pointOfInterestFilter = .excludingAll

        // Layer stack from bottom to top:
        //   base → bathymetry → seamark
        // mean_multicolour has transparent land so the OSM coastlines still
        // read through it; seamarks stay on top so buoys remain legible.
        let base = OSMTileOverlay(style: satellite ? .satellite : .standard)
        map.addOverlay(base, level: .aboveRoads)
        context.coordinator.baseOverlay = base
        if bathymetry {
            let bm = OSMTileOverlay(style: .bathymetry)
            map.addOverlay(bm, level: .aboveLabels)
            context.coordinator.bathymetryOverlay = bm
        }
        if seamark {
            let sm = OSMTileOverlay(style: .seamark)
            map.addOverlay(sm, level: .aboveLabels)
            context.coordinator.seamarkOverlay = sm
        }

        // Detect direct user manipulation so the chart can turn off Follow as
        // soon as the user pans, plus tap / context-menu input. Platform stack
        // installed here (mouse + keyboard on macOS, touch on iOS).
        installGestures(on: map, coordinator: context.coordinator)

        let initial = (vesselLat != 0 || vesselLon != 0)
            ? CLLocationCoordinate2D(latitude: vesselLat, longitude: vesselLon)
            : initialCenter
        map.setRegion(.init(center: initial,
                            span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)),
                      animated: false)
        zoomProxy.mapView = map
        return map
    }

    func syncMap(_ map: MKMapView, context: Context) {
        let coord = context.coordinator
        coord.parent = self        // keep coordinator closures in sync with current state

        // Base style is now picked by the regionDidChange delegate so that
        // z≥16 can force satellite imagery for harbour pilotage. We just
        // nudge it here when the user toggle changes outside of a region
        // change (e.g. flipping Satellite in Chart Settings while standing
        // still). Threshold matches the delegate.
        let z = Int(log2(360.0 / max(0.0001, map.region.span.longitudeDelta)).rounded())
        coord.setBaseStyle(coord.desiredBaseStyle(forZoom: z), on: map)
        // Toggle bathymetry overlay (below seamarks so buoys stay legible).
        // Force insertion below the seamark overlay when both are on — MapKit
        // otherwise stacks within a level in addition order, which would put
        // bathymetry on top if it's toggled after seamarks.
        if bathymetry && coord.bathymetryOverlay == nil {
            let bm = OSMTileOverlay(style: .bathymetry)
            if let sm = coord.seamarkOverlay {
                map.insertOverlay(bm, below: sm)
            } else {
                map.addOverlay(bm, level: .aboveLabels)
            }
            coord.bathymetryOverlay = bm
        } else if !bathymetry, let bm = coord.bathymetryOverlay {
            map.removeOverlay(bm)
            coord.bathymetryOverlay = nil
        }
        // Toggle seamark overlay (on top)
        if seamark && coord.seamarkOverlay == nil {
            let sm = OSMTileOverlay(style: .seamark)
            map.addOverlay(sm, level: .aboveLabels)
            coord.seamarkOverlay = sm
        } else if !seamark, let sm = coord.seamarkOverlay {
            map.removeOverlay(sm)
            coord.seamarkOverlay = nil
        }

        // Local depth-band + land polygons. Rendered between the bathymetry
        // tile layer and the seamark layer so buoys/lights stay readable on
        // top. We skip the rebuild when the polygon set is identical to the
        // one already on the map — without this guard, every pan inside a
        // single region would teardown+rebuild hundreds of MKPolygons.
        let wantHash = contourPolygons.map(\.identityHash).reduce(into: 0) { $0 ^= $1 }
        if wantHash != coord.contourHash {
            if !coord.contourOverlays.isEmpty {
                map.removeOverlays(coord.contourOverlays)
                coord.contourOverlays.removeAll()
            }
            if !coord.contourLines.isEmpty {
                map.removeOverlays(coord.contourLines)
                coord.contourLines.removeAll()
            }
            if !contourPolygons.isEmpty {
                var polys: [ContourMKPolygon] = []
                var lines: [ContourMKPolyline] = []
                polys.reserveCapacity(contourPolygons.count / 4)
                lines.reserveCapacity(contourPolygons.count)
                // Draw depth bands first (deeper water underneath), then land
                // on top, so the coast masks the shallowest band edge cleanly.
                let ordered = contourPolygons.sorted { a, b in
                    func rank(_ p: ContourPolygon) -> Int { if case .land = p.band { return 1 } else { return 0 } }
                    return rank(a) < rank(b)
                }
                for cp in ordered {
                    switch cp.band {
                    case .land:
                        // Land is a filled polygon (so the satellite is
                        // masked under it), with a stroked coast outline.
                        let poly = ContourMKPolygon.from(cp)
                        if let sm = coord.seamarkOverlay {
                            map.insertOverlay(poly, below: sm)
                        } else {
                            map.addOverlay(poly, level: .aboveLabels)
                        }
                        polys.append(poly)
                    case .depth:
                        // One isobath = one outline-only polygon, traced from
                        // the band's outer ring (= contour at depth_min). We
                        // deliberately drop the inner ring so each level is
                        // drawn exactly once (no per-band smoothing mismatch
                        // can show up as a gap or overlap), and we render via
                        // MKPolygon (clear fill + stroke) rather than
                        // MKPolyline — the polygon path is the one already
                        // proven to render correctly for the coast.
                        let outline = ContourMKPolygon.outline(for: cp)
                        if let sm = coord.seamarkOverlay {
                            map.insertOverlay(outline, below: sm)
                        } else {
                            map.addOverlay(outline, level: .aboveLabels)
                        }
                        polys.append(outline)
                    }
                }
                coord.contourOverlays = polys
                coord.contourLines    = lines
            }
            coord.contourHash = wantHash
        }

        // Chart is always north-up — rotation gesture is permanently off.

        // Annotations are reconciled in place (move existing, add new, remove
        // gone) keyed by identity — never wholesale removed and re-added — so
        // markers don't flicker when SwiftUI re-runs updateUIView at GPS rate.

        // Vessel
        let oldVessel = map.annotations.first(where: { $0 is HeadedVesselAnnotation }) as? HeadedVesselAnnotation
        if vesselLat != 0 || vesselLon != 0 {
            let c = CLLocationCoordinate2D(latitude: vesselLat, longitude: vesselLon)
            if let v = oldVessel {
                v.coordinate = c
                v.heading = heading; v.cog = cog; v.sog = sog
                v.twa = trueWindAngle; v.tws = trueWindSpeed
                if let view = map.view(for: v) { coord.refreshVessel(view: view, ann: v) }
            } else {
                map.addAnnotation(HeadedVesselAnnotation(
                    coord: c, heading: heading, cog: cog, sog: sog,
                    twa: trueWindAngle, tws: trueWindSpeed))
            }
        } else if let v = oldVessel {
            map.removeAnnotation(v)
        }

        // AIS targets (aisstream.io) — reconcile by MMSI
        if showAIS {
            var seen = Set<Int>()
            for t in aisTargets {
                seen.insert(t.mmsi)
                let danger = dangerousMMSIs.contains(t.mmsi)
                let friend = aisFriends[t.mmsi]
                if let ann = coord.aisAnnotations[t.mmsi] {
                    if ann.apply(t, friend: friend, danger: danger), let view = map.view(for: ann) {
                        coord.refreshAIS(view: view, ann: ann)
                    }
                } else {
                    let ann = AISAnnotation(t, friend: friend, danger: danger)
                    coord.aisAnnotations[t.mmsi] = ann
                    map.addAnnotation(ann)
                }
            }
            for (mmsi, ann) in coord.aisAnnotations where !seen.contains(mmsi) {
                map.removeAnnotation(ann); coord.aisAnnotations[mmsi] = nil
            }
        } else if !coord.aisAnnotations.isEmpty {
            map.removeAnnotations(Array(coord.aisAnnotations.values))
            coord.aisAnnotations.removeAll()
        }

        // PredictWind commercial AIS — reconcile by MMSI
        if showPredictWindAIS {
            var seen = Set<String>()
            for t in pwAISTargets {
                seen.insert(t.mmsi)
                if let ann = coord.pwAnnotations[t.mmsi] {
                    if ann.apply(t), let view = map.view(for: ann) { coord.refreshPWAIS(view: view, ann: ann) }
                } else {
                    let ann = PWAISAnnotation(t); coord.pwAnnotations[t.mmsi] = ann; map.addAnnotation(ann)
                }
            }
            for (k, ann) in coord.pwAnnotations where !seen.contains(k) {
                map.removeAnnotation(ann); coord.pwAnnotations[k] = nil
            }
        } else if !coord.pwAnnotations.isEmpty {
            map.removeAnnotations(Array(coord.pwAnnotations.values)); coord.pwAnnotations.removeAll()
        }

        // Anchor — single annotation moved in place (skip while the user drags it)
        if anchorMode && (anchorActive || anchorLat != 0) {
            let c = CLLocationCoordinate2D(latitude: anchorLat, longitude: anchorLon)
            if let a = coord.anchorAnnotation {
                if !coord.isDraggingAnnotation { a.coordinate = c }
            } else {
                let a = AnchorAnnotation(c); coord.anchorAnnotation = a; map.addAnnotation(a)
            }
        } else if let a = coord.anchorAnnotation {
            map.removeAnnotation(a); coord.anchorAnnotation = nil
        }

        // Waypoint
        if let wp = waypoint {
            if let w = coord.waypointAnnotation { w.coordinate = wp }
            else { let w = WaypointAnnotation(wp); coord.waypointAnnotation = w; map.addAnnotation(w) }
        } else if let w = coord.waypointAnnotation {
            map.removeAnnotation(w); coord.waypointAnnotation = nil
        }

        // MOB
        if let mob = mobCoord {
            if let m = coord.mobAnnotation { m.coordinate = mob }
            else { let m = MOBAnnotation(mob); coord.mobAnnotation = m; map.addAnnotation(m) }
        } else if let m = coord.mobAnnotation {
            map.removeAnnotation(m); coord.mobAnnotation = nil
        }

        // Route waypoints — rebuild only when the route actually changes
        let routeSig = route.map { r in
            "\(r.legIndex)|" + r.waypoints.map { "\($0.lat),\($0.lon),\($0.name)" }.joined(separator: ";")
        } ?? ""
        if routeSig != coord.routeSignature {
            if !coord.routeAnnotations.isEmpty {
                map.removeAnnotations(coord.routeAnnotations); coord.routeAnnotations = []
            }
            if let route, !route.waypoints.isEmpty {
                for (idx, wp) in route.waypoints.enumerated() {
                    let a = RouteWaypointAnnotation(coord: .init(latitude: wp.lat, longitude: wp.lon),
                                                    index: idx, isActive: idx == route.legIndex, name: wp.name)
                    coord.routeAnnotations.append(a); map.addAnnotation(a)
                }
            }
            coord.routeSignature = routeSig
        }

        // Measurement endpoints
        if let from = measureFrom {
            if let f = coord.measureFromAnn { if !coord.isDraggingAnnotation { f.coordinate = from } }
            else { let f = MeasureEndpointAnnotation(from, role: .from); coord.measureFromAnn = f; map.addAnnotation(f) }
        } else if let f = coord.measureFromAnn { map.removeAnnotation(f); coord.measureFromAnn = nil }
        if let to = measureTo {
            if let t = coord.measureToAnn { if !coord.isDraggingAnnotation { t.coordinate = to } }
            else { let t = MeasureEndpointAnnotation(to, role: .to); coord.measureToAnn = t; map.addAnnotation(t) }
        } else if let t = coord.measureToAnn { map.removeAnnotation(t); coord.measureToAnn = nil }

        // Vector overlays (tracks/route/predictor/laylines/anchor rings/guard/
        // measure) are rebuilt ONLY when their inputs change. Removing+re-adding
        // them on every GPS tick makes MapKit recreate each renderer and visibly
        // blink (badly on macOS, which shows the empty inter-frame). Positions are
        // quantized so float jitter can't defeat the guard. The camera-follow
        // block below still runs every tick.
        func r5(_ v: Double) -> Int { Int((v * 1e5).rounded()) }   // ~1 m
        func sc(_ c: CLLocationCoordinate2D?) -> String {
            c.map { "\(r5($0.latitude)),\(r5($0.longitude))" } ?? "-"
        }
        var sig = "v\(r5(vesselLat)),\(r5(vesselLon));c\(Int(cog.rounded())),s\(Int((sog * 10).rounded()));"
        sig += "tr" + tracks.map { "\($0.points.count)|\($0.colorHex)|\($0.source)" }.joined(separator: ",") + ";"
        sig += "wp\(sc(waypoint));mob\(sc(mobCoord));pm\(predictorMinutes);"
        sig += "ll\(sc(laylineWaypoint)),twd\(Int(trueWindDirection.rounded())),ta\(Int(tackAngleDeg.rounded()));"
        sig += "rt\(routeSig);gz\(r5(guardZoneRadiusNm));"
        sig += "an\(anchorMode ? 1 : 0)\(anchorActive ? 1 : 0),\(r5(anchorLat)),\(r5(anchorLon)),r\(r5(anchorRadius)),w\(r5(anchorWarnRadius)),f\(anchorFlash ? 1 : 0),sw\(anchorSwinging ? 1 : 0),swt\(anchorSwingTrack.count),itwd\(Int(anchorInitialTWD.rounded())),sh\(Int(anchorWindShift.rounded()));"
        sig += "mf\(sc(measureFrom)),mt\(sc(measureTo))"

        if sig != coord.overlaySignature {
            if !coord.dynamicOverlays.isEmpty {
                map.removeOverlays(coord.dynamicOverlays)
                coord.dynamicOverlays.removeAll(keepingCapacity: true)
            }
            var newOverlays: [MKOverlay] = []

            // Tracks
            for track in tracks where track.points.count > 1 {
                let coords = track.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let poly = ColoredPolyline(coordinates: coords, count: coords.count)
                poly.strokeColor = PlatformColor(hex: track.colorHex) ?? .systemCyan
                poly.lineWidth = track.source == .local ? 2.5 : 3.5
                newOverlays.append(poly)
            }
            // Waypoint route line from vessel → waypoint
            if let wp = waypoint, vesselLat != 0 || vesselLon != 0 {
                let line = ColoredPolyline(coordinates: [
                    .init(latitude: vesselLat, longitude: vesselLon), wp
                ], count: 2)
                line.strokeColor = PlatformColor.systemYellow
                line.lineWidth = 3
                line.dashed = true
                newOverlays.append(line)
            }

            // Predictor line — projects current COG/SOG `predictorMinutes` ahead
            if predictorMinutes > 0, vesselLat != 0 || vesselLon != 0, sog > 0.1 {
                let here = CLLocationCoordinate2D(latitude: vesselLat, longitude: vesselLon)
                let ahead = NavMath.predictor(from: here, cogDeg: cog, sogKn: sog,
                                              minutes: predictorMinutes)
                let pl = ColoredPolyline(coordinates: [here, ahead], count: 2)
                pl.strokeColor = PlatformColor.systemCyan.withAlphaComponent(0.85)
                pl.lineWidth = 2
                newOverlays.append(pl)
            }

            // Laylines from the active layline waypoint
            if let lwp = laylineWaypoint, trueWindDirection >= 0 {
                let pair = NavMath.laylines(toward: lwp,
                                            windFromDeg: trueWindDirection,
                                            tackAngleDeg: tackAngleDeg,
                                            lengthNm: 8)
                let port = ColoredPolyline(coordinates: [lwp, pair.port], count: 2)
                port.strokeColor = PlatformColor.systemRed.withAlphaComponent(0.9)
                port.lineWidth = 2
                port.dashed = true
                newOverlays.append(port)
                let stbd = ColoredPolyline(coordinates: [lwp, pair.stbd], count: 2)
                stbd.strokeColor = PlatformColor.systemGreen.withAlphaComponent(0.9)
                stbd.lineWidth = 2
                stbd.dashed = true
                newOverlays.append(stbd)
            }

            // Active route polyline (vessel → leg → leg → …)
            if let r = route, !r.waypoints.isEmpty {
                var pts: [CLLocationCoordinate2D] = []
                if vesselLat != 0 || vesselLon != 0 {
                    pts.append(.init(latitude: vesselLat, longitude: vesselLon))
                }
                // Skip already-passed legs visually
                for wp in r.waypoints.suffix(from: r.legIndex) {
                    pts.append(.init(latitude: wp.lat, longitude: wp.lon))
                }
                if pts.count >= 2 {
                    let rl = ColoredPolyline(coordinates: pts, count: pts.count)
                    rl.strokeColor = PlatformColor.systemPurple
                    rl.lineWidth = 3
                    newOverlays.append(rl)
                }
            }

            // MOB return-to-position line
            if let mob = mobCoord, vesselLat != 0 || vesselLon != 0 {
                let line = ColoredPolyline(coordinates: [
                    .init(latitude: vesselLat, longitude: vesselLon), mob
                ], count: 2)
                line.strokeColor = PlatformColor.systemRed
                line.lineWidth = 3
                newOverlays.append(line)
            }

            // Anchor circle + wind sector (anchor mode)
            if anchorMode && (anchorActive || anchorLat != 0) {
                let ac = CLLocationCoordinate2D(latitude: anchorLat, longitude: anchorLon)
                let ancCircle = ColoredCircle(center: ac, radius: anchorRadius)
                ancCircle.strokeColor = anchorFlash ? .systemRed : .systemOrange
                ancCircle.fillColor   = (anchorFlash ? PlatformColor.systemRed : PlatformColor.systemOrange).withAlphaComponent(anchorFlash ? 0.25 : 0.10)
                ancCircle.lineWidth   = 1.5
                ancCircle.dashed      = false
                newOverlays.append(ancCircle)

                // Inner warning ring — early heads-up before the hard drag alarm.
                if anchorWarnRadius > 0, anchorWarnRadius < anchorRadius {
                    let warn = ColoredCircle(center: ac, radius: anchorWarnRadius)
                    warn.strokeColor = PlatformColor.systemYellow.withAlphaComponent(0.75)
                    warn.fillColor   = .clear
                    warn.lineWidth   = 1.0
                    warn.dashed      = true
                    newOverlays.append(warn)
                }

                // Swing breadcrumb fan — the observed arc, to read holding vs drag.
                if anchorSwingTrack.count >= 2 {
                    let sw = ColoredPolyline(coordinates: anchorSwingTrack, count: anchorSwingTrack.count)
                    sw.strokeColor = PlatformColor.systemTeal.withAlphaComponent(0.55)
                    sw.lineWidth   = 1.5
                    newOverlays.append(sw)
                }

                // Rode line anchor → vessel — shows where the boat sits in the circle.
                if vesselLat != 0 || vesselLon != 0 {
                    let rode = ColoredPolyline(
                        coordinates: [ac, .init(latitude: vesselLat, longitude: vesselLon)], count: 2)
                    rode.strokeColor = (anchorFlash ? PlatformColor.systemRed : PlatformColor.systemOrange).withAlphaComponent(0.85)
                    rode.lineWidth   = 1.5
                    newOverlays.append(rode)
                }

                if anchorSwinging && anchorWindShift < 90 && anchorInitialTWD >= 0 {
                    let dist = max(anchorRadius * 2, 40.0)
                    let b1   = anchorInitialTWD - anchorWindShift
                    let b2   = anchorInitialTWD + anchorWindShift
                    func dest(_ b: Double) -> CLLocationCoordinate2D {
                        NavMath.destination(from: ac, bearingDeg: b, distanceM: dist)
                    }
                    let arcPts: [CLLocationCoordinate2D] = (0...24).map { i in
                        dest(b1 + (b2 - b1) * Double(i) / 24.0)
                    }
                    let ray1 = ColoredPolyline(coordinates: [ac, dest(b1)], count: 2)
                    ray1.strokeColor = PlatformColor.systemCyan.withAlphaComponent(0.55); ray1.lineWidth = 1
                    let arc = ColoredPolyline(coordinates: arcPts, count: arcPts.count)
                    arc.strokeColor = PlatformColor.systemCyan.withAlphaComponent(0.55); arc.lineWidth = 1
                    let ray2 = ColoredPolyline(coordinates: [ac, dest(b2)], count: 2)
                    ray2.strokeColor = PlatformColor.systemCyan.withAlphaComponent(0.55); ray2.lineWidth = 1
                    newOverlays.append(ray1)
                    newOverlays.append(arc)
                    newOverlays.append(ray2)
                }
            }

            // AIS guard zone circle around vessel
            if guardZoneRadiusNm > 0, vesselLat != 0 || vesselLon != 0 {
                let circle = ColoredCircle(
                    center: .init(latitude: vesselLat, longitude: vesselLon),
                    radius: guardZoneRadiusNm * 1852               // nm → m
                )
                newOverlays.append(circle)
            }
            // Measurement line
            if let from = measureFrom, let to = measureTo {
                let mline = ColoredPolyline(coordinates: [from, to], count: 2)
                mline.strokeColor = .systemYellow
                mline.lineWidth = 3
                mline.dashed = true
                newOverlays.append(mline)
            }

            if !newOverlays.isEmpty { map.addOverlays(newOverlays, level: .aboveLabels) }
            coord.dynamicOverlays = newOverlays
            coord.overlaySignature = sig
        }

        // Camera follow
        if follow, vesselLat != 0 || vesselLon != 0 {
            let target = CLLocationCoordinate2D(latitude: vesselLat, longitude: vesselLon)
            // Don't yank the camera if user is mid-pan close to vessel
            let cur = map.region.center
            let drift = abs(cur.latitude - target.latitude) + abs(cur.longitude - target.longitude)
            if drift > 0.0008 {
                let r = MKCoordinateRegion(center: target, span: map.region.span)
                map.setRegion(r, animated: true)
            }
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, PlatformGestureRecognizerDelegate {
        var parent: ChartMapView
        var baseOverlay: OSMTileOverlay?
        var seamarkOverlay: OSMTileOverlay?
        var bathymetryOverlay: OSMTileOverlay?
        /// Current land polygons drawn on the map (filled with tan, stroked
        /// at the coast).
        var contourOverlays: [ContourMKPolygon] = []
        /// Current depth-band polylines drawn on the map (no fill).
        var contourLines: [ContourMKPolyline] = []
        /// Cheap fingerprint of the polygon set last rendered, so we can
        /// skip the rebuild when SwiftUI hands us the same content.
        var contourHash: Int = 0
        /// Vector overlays (tracks/route/predictor/laylines/anchor rings/guard/
        /// measure) currently on the map, plus a signature of their inputs — so
        /// they're rebuilt only when something actually changed, never on every
        /// GPS tick (which made MapKit recreate each renderer and blink).
        var dynamicOverlays: [MKOverlay] = []
        var overlaySignature: String = ""
        private var prefetchDebounce: DispatchWorkItem?

        // Live annotation registries — reconciled in place each update so markers
        // move smoothly instead of being destroyed and recreated (which flickered).
        var aisAnnotations:   [Int: AISAnnotation]    = [:]
        var pwAnnotations:    [String: PWAISAnnotation] = [:]
        var anchorAnnotation: AnchorAnnotation?
        var waypointAnnotation: WaypointAnnotation?
        var mobAnnotation:    MOBAnnotation?
        var routeAnnotations: [RouteWaypointAnnotation] = []
        var routeSignature:   String = ""
        var measureFromAnn:   MeasureEndpointAnnotation?
        var measureToAnn:     MeasureEndpointAnnotation?
        /// True while the user is dragging a pin, so in-place coordinate
        /// updates from updateUIView don't yank it back.
        var isDraggingAnnotation = false

        init(_ p: ChartMapView) { parent = p }

        // MARK: Base layer

        /// Effective base style for a given zoom level. The user's Satellite
        /// toggle always forces imagery; otherwise we auto-swap to satellite at
        /// z≥16 for harbour pilotage. The swap-back to OSM only happens once
        /// we've zoomed out past z15 — this dead-band (z15 keeps whatever is
        /// already shown) stops tiny zoom jitter near the boundary from flipping
        /// the base back and forth, which read as the chart "jumping" between
        /// satellite and OSM.
        func desiredBaseStyle(forZoom z: Int) -> OSMTileOverlay.Style {
            if parent.satellite { return .satellite }
            if z >= 16 { return .satellite }
            if z <= 14 { return .standard }
            return baseOverlay?.style ?? .standard
        }

        /// Swap the base tile layer WITHOUT ever leaving a gap where MapKit's
        /// own "Map Data not yet available" placeholder could flash through.
        /// The new replacing overlay is added first (it renders above the old
        /// base), and the previous one is removed on the next runloop tick — so
        /// a `canReplaceMapContent` overlay always covers Apple's base map, even
        /// while the new tiles are still loading over a slow marine link. The
        /// guard makes this idempotent so syncMap and regionDidChange can both
        /// call it without double-swapping.
        func setBaseStyle(_ style: OSMTileOverlay.Style, on map: MKMapView) {
            guard baseOverlay?.style != style else { return }
            let new = OSMTileOverlay(style: style)
            map.addOverlay(new, level: .aboveRoads)
            if let old = baseOverlay {
                DispatchQueue.main.async { [weak map] in map?.removeOverlay(old) }
            }
            baseOverlay = new
        }

        // Two responsibilities on every region change:
        //   1. Auto-swap base layer to ESRI satellite at z≥16 so harbour
        //      pilotage shows real imagery under the OpenSeaMap seamarks.
        //      Below z16 we revert to the user's choice (OSM or satellite).
        //   2. Warm the cache around the visible area (debounced).
        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Tell SwiftUI to recompute contour polygons for the new bbox.
            parent.onRegionChange(map.region)

            let lonSpan = map.region.span.longitudeDelta
            let z = max(1, min(19, Int(log2(360.0 / max(0.0001, lonSpan)).rounded())))

            // Effective base style — user toggle wins, z≥16 auto-forces
            // satellite (with hysteresis on the way back out). Swapped
            // seamlessly so Apple's base never flashes through.
            let wantStyle = desiredBaseStyle(forZoom: z)
            setBaseStyle(wantStyle, on: map)
            let wantSatellite = (wantStyle == .satellite)

            // Prefetch (debounced)
            prefetchDebounce?.cancel()
            let work = DispatchWorkItem { [weak self, weak map] in
                guard let self, let map else { return }
                TilePrefetcher.shared.prefetch(
                    region: map.region, zoom: z,
                    satellite: wantSatellite,
                    seamark: self.parent.seamark,
                    bathymetry: self.parent.bathymetry
                )
            }
            prefetchDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }

        func mapView(_ map: MKMapView, annotationView view: MKAnnotationView,
                     didChange newState: MKAnnotationView.DragState,
                     fromOldState oldState: MKAnnotationView.DragState) {
            switch newState {
            case .starting, .dragging: isDraggingAnnotation = true
            default:                   isDraggingAnnotation = false
            }
            guard newState == .ending || newState == .canceling else { return }
            view.dragState = .none

            // Anchor pin drag → update anchor position
            if view.annotation is AnchorAnnotation {
                parent.onAnchorMoved(view.annotation!.coordinate)
                return
            }

            // Measurement endpoint drag → update binding
            if let ann = view.annotation as? MeasureEndpointAnnotation {
                switch ann.role {
                case .from: parent.measureFrom = ann.coordinate
                case .to:   parent.measureTo   = ann.coordinate
                }
            }
        }

        // MARK: Shared input logic (called from the platform gesture handlers)

        /// A discrete tap/click: AIS hit-test wins, otherwise a plain map tap.
        private func performTap(at pt: CGPoint, in map: MKMapView) {
            for ann in map.annotations {
                guard let view = map.view(for: ann) else { continue }
                let frame = view.convert(view.bounds, to: map)
                if frame.contains(pt), let ais = ann as? AISAnnotation {
                    parent.onAISTap(ais.target)
                    return
                }
                // anchor pin is draggable — handled by MapKit drag, not here
            }
            parent.onMapTap(map.convert(pt, toCoordinateFrom: map))
        }

        /// The position action menu (iOS long-press / macOS right-click).
        private func performContextAction(at pt: CGPoint, in map: MKMapView) {
            let coord = map.convert(pt, toCoordinateFrom: map)
            Haptics.selection()
            parent.onAnnotationLongPress(coord)
        }

        #if os(macOS)
        @objc func handleClick(_ g: NSClickGestureRecognizer) {
            guard let map = g.view as? MKMapView else { return }
            performTap(at: g.location(in: map), in: map)
        }
        @objc func handleRightClick(_ g: NSClickGestureRecognizer) {
            guard let map = g.view as? MKMapView else { return }
            performContextAction(at: g.location(in: map), in: map)
        }
        @objc func handlePan(_ g: NSPanGestureRecognizer) {
            if g.state == .began { parent.onUserGesture() }
        }
        func gestureRecognizer(_ g: NSGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool {
            true     // don't fight MKMapView's pan/zoom
        }
        #else
        @objc func handleUserGesture(_ g: UIGestureRecognizer) {
            // .began fires once at the start of a pan/pinch — enough to flip
            // Follow off without spamming on every velocity update.
            if g.state == .began { parent.onUserGesture() }
        }

        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map = g.view as? MKMapView else { return }
            performContextAction(at: g.location(in: map), in: map)
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let map = g.view as? MKMapView else { return }
            performTap(at: g.location(in: map), in: map)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true     // don't fight MKMapView's pan/zoom
        }
        #endif

        // MARK: Overlays

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let t = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: t)
            }
            if let p = overlay as? ColoredPolyline {
                let r = MKPolylineRenderer(polyline: p)
                r.strokeColor = p.strokeColor
                r.lineWidth = p.lineWidth
                if p.dashed { r.lineDashPattern = [8, 6] }
                return r
            }
            if let c = overlay as? ColoredCircle {
                let r = MKCircleRenderer(circle: c)
                r.strokeColor = c.strokeColor
                r.fillColor   = c.fillColor
                r.lineWidth   = c.lineWidth
                if c.dashed { r.lineDashPattern = [6, 4] }
                return r
            }
            if let cp = overlay as? ContourMKPolygon {
                let r = MKPolygonRenderer(polygon: cp)
                r.fillColor   = cp.fillColor
                r.strokeColor = cp.strokeColor   // coast outline for land
                r.lineWidth   = cp.lineWidth
                return r
            }
            if let cl = overlay as? ContourMKPolyline {
                let r = MKPolylineRenderer(polyline: cl)
                r.strokeColor = cl.strokeColor
                r.lineWidth   = cl.lineWidth
                r.lineCap     = .round
                r.lineJoin    = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        // MARK: Annotations

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case let v as HeadedVesselAnnotation:
                let id = "vessel"
                let view = (map.dequeueReusableAnnotationView(withIdentifier: id) as? MKAnnotationView)
                       ?? MKAnnotationView(annotation: v, reuseIdentifier: id)
                view.annotation = v
                view.canShowCallout = false
                refreshVessel(view: view, ann: v)
                return view

            case let a as AISAnnotation:
                // Reuse identifier varies so re-styling on danger flip works.
                let id = "ais-\(a.friend != nil ? "f" : "n")\(a.danger ? "d" : "n")"
                let view = (map.dequeueReusableAnnotationView(withIdentifier: id) as? MKAnnotationView)
                       ?? MKAnnotationView(annotation: a, reuseIdentifier: id)
                view.annotation = a
                view.canShowCallout = false
                view.image = a.friend != nil
                    ? Self.friendIcon(target: a.target, danger: a.danger)
                    : Self.aisIcon(target: a.target, danger: a.danger)
                return view

            case let p as PWAISAnnotation:
                let id = "pwais"
                let view = (map.dequeueReusableAnnotationView(withIdentifier: id) as? MKAnnotationView)
                       ?? MKAnnotationView(annotation: p, reuseIdentifier: id)
                view.annotation = p
                view.canShowCallout = true
                view.image = Self.pwAISIcon(target: p.target)
                return view

            case let r as RouteWaypointAnnotation:
                let id = r.isActive ? "routewp-active" : "routewp"
                let view = (map.dequeueReusableAnnotationView(withIdentifier: id) as? MKAnnotationView)
                       ?? MKAnnotationView(annotation: r, reuseIdentifier: id)
                view.annotation = r
                view.canShowCallout = false
                view.image = Self.routeWaypointIcon(index: r.index, active: r.isActive)
                view.centerOffset = .zero
                return view

            case is MOBAnnotation:
                let id = "mob"
                let view = (map.dequeueReusableAnnotationView(withIdentifier: id) as? MKAnnotationView)
                       ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.image = tintedSymbol("exclamationmark.octagon.fill",
                                          pointSize: 32, weight: .bold, color: .systemRed)
                view.canShowCallout = false
                return view

            case is WaypointAnnotation:
                let id = "wp"
                let view = (map.dequeueReusableAnnotationView(withIdentifier: id) as? MKAnnotationView)
                       ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.image = tintedSymbol("flag.fill",
                                          pointSize: 26, weight: .bold, color: .systemYellow)
                view.centerOffset = CGPoint(x: 0, y: -13)
                view.canShowCallout = false
                return view

            case is MeasureEndpointAnnotation:
                let id = "measure"
                let view = (map.dequeueReusableAnnotationView(withIdentifier: id) as? MKAnnotationView)
                       ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.image = Self.measureDot()
                view.canShowCallout = false
                view.isDraggable = true        // drag-to-reposition endpoint
                return view

            case is AnchorAnnotation:
                let id = "anchor-pin"
                let view = (map.dequeueReusableAnnotationView(withIdentifier: id) as? MKAnnotationView)
                       ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.canShowCallout = false
                view.isDraggable = true   // drag to reposition the anchor point
                view.image = Self.anchorPinImage()
                view.centerOffset = .zero   // dot is centred on the coordinate
                return view

            default: return nil
            }
        }

        // MARK: Vessel rendering

        func refreshVessel(view: MKAnnotationView, ann: HeadedVesselAnnotation) {
            view.image = Self.vesselImage(
                heading: ann.heading,
                cog: ann.cog,
                sog: ann.sog,
                twa: ann.twa,
                tws: ann.tws
            )
            view.centerOffset = .zero
        }

        func refreshAIS(view: MKAnnotationView, ann: AISAnnotation) {
            view.image = ann.friend != nil
                ? Self.friendIcon(target: ann.target, danger: ann.danger)
                : Self.aisIcon(target: ann.target, danger: ann.danger)
        }

        func refreshPWAIS(view: MKAnnotationView, ann: PWAISAnnotation) {
            view.image = Self.pwAISIcon(target: ann.target)
        }

        // MARK: Icon factories

        private static func vesselImage(heading: Double, cog: Double,
                                        sog: Double, twa: Double, tws: Double) -> PlatformImage {
            let size: CGFloat = 180     // generous canvas to accommodate COG arrow + wind triangle
            let center = CGPoint(x: size / 2, y: size / 2)
            return makeIcon(size:.init(width: size, height: size)) { ctx in

                // --- COG arrow (cyan) ---
                // Length scales 0–8 kn → 0–60 pt, capped
                let cogLen = min(70, max(14, sog * 8))
                let cogRad = (cog - 90) * .pi / 180     // 0° north = pointing up; rotate by -90
                let cogEnd = CGPoint(
                    x: center.x + cos(cogRad) * cogLen,
                    y: center.y + sin(cogRad) * cogLen
                )
                ctx.setStrokeColor(PlatformColor.systemCyan.cgColor)
                ctx.setLineWidth(3)
                ctx.setLineCap(.round)
                ctx.move(to: center)
                ctx.addLine(to: cogEnd)
                ctx.strokePath()
                // arrowhead
                let head = 8.0
                let leftAngle  = cogRad + .pi - 0.4
                let rightAngle = cogRad + .pi + 0.4
                ctx.move(to: cogEnd)
                ctx.addLine(to: .init(x: cogEnd.x + cos(leftAngle)  * head,
                                      y: cogEnd.y + sin(leftAngle)  * head))
                ctx.move(to: cogEnd)
                ctx.addLine(to: .init(x: cogEnd.x + cos(rightAngle) * head,
                                      y: cogEnd.y + sin(rightAngle) * head))
                ctx.strokePath()

                // --- Wind triangle (true wind, pointing AT the vessel from its source) ---
                if tws > 0.5 {
                    // True wind *direction* (where wind is going) = heading + twa.
                    // Wind comes FROM the opposite direction. We draw a feathered arrow
                    // outside the boat pointing inward to the bow.
                    let twd  = heading + twa
                    let from = (twd + 180 - 90) * .pi / 180
                    let radius: CGFloat = 70
                    let start = CGPoint(x: center.x + cos(from) * radius,
                                        y: center.y + sin(from) * radius)
                    // Arrow body
                    ctx.setStrokeColor(PlatformColor.white.withAlphaComponent(0.85).cgColor)
                    ctx.setLineWidth(2.5)
                    ctx.setLineCap(.round)
                    ctx.move(to: start)
                    // Inward arrow points to a spot just shy of the vessel
                    let stopRadius: CGFloat = 22
                    let stop = CGPoint(x: center.x + cos(from) * stopRadius,
                                       y: center.y + sin(from) * stopRadius)
                    ctx.addLine(to: stop)
                    ctx.strokePath()
                    // Arrowhead
                    let inward = from + .pi
                    let l = inward - 0.45, r = inward + 0.45
                    let ah: CGFloat = 9
                    ctx.move(to: stop)
                    ctx.addLine(to: .init(x: stop.x + cos(l) * ah, y: stop.y + sin(l) * ah))
                    ctx.move(to: stop)
                    ctx.addLine(to: .init(x: stop.x + cos(r) * ah, y: stop.y + sin(r) * ah))
                    ctx.strokePath()
                    // Wind speed label near the source
                    let text = String(format: "%.0fkt", tws) as NSString
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: PlatformFont.systemFont(ofSize: 10, weight: .semibold),
                        .foregroundColor: PlatformColor.white.withAlphaComponent(0.9),
                    ]
                    let tsize = text.size(withAttributes: attrs)
                    let tpoint = CGPoint(
                        x: start.x + cos(from) * 10 - tsize.width / 2,
                        y: start.y + sin(from) * 10 - tsize.height / 2
                    )
                    text.draw(at: tpoint, withAttributes: attrs)
                }

                // --- Vessel arrow (rotated to heading) ---
                ctx.saveGState()
                ctx.translateBy(x: center.x, y: center.y)
                ctx.rotate(by: heading * .pi / 180)
                // Boat shape: simple pointed triangle with a base
                let path = PlatformBezierPath()
                path.move(to: .init(x: 0,    y: -16))   // bow
                path.addLine(to: .init(x: 8,  y: 12))
                path.addLine(to: .init(x: 0,  y: 8))
                path.addLine(to: .init(x: -8, y: 12))
                path.close()
                PlatformColor.systemCyan.setFill()
                path.fill()
                PlatformColor.white.setStroke()
                path.lineWidth = 1.2
                path.stroke()
                ctx.restoreGState()
            }
        }

        private static func aisIcon(target: AISTarget, danger: Bool = false) -> PlatformImage {
            let size: CGFloat = danger ? 36 : 28
            let center = CGPoint(x: size / 2, y: size / 2)
            let cogRad = (target.cog - 90) * .pi / 180

            // Color by ship type
            let color: PlatformColor
            switch target.shipType ?? 0 {
            case 70...79: color = .systemBrown          // cargo
            case 80...89: color = .systemRed            // tanker
            case 60...69: color = .systemBlue           // passenger
            case 36:      color = .systemTeal           // sailing
            case 30:      color = .systemGreen          // fishing
            default:      color = .systemYellow
            }

            return makeIcon(size:.init(width: size, height: size)) { ctx in
                if danger {
                    // Pulsing-red ring drawn under the arrowhead
                    let ringRect = CGRect(x: 2, y: 2, width: size - 4, height: size - 4)
                    ctx.setStrokeColor(PlatformColor.systemRed.cgColor)
                    ctx.setLineWidth(2.5)
                    ctx.strokeEllipse(in: ringRect)
                    ctx.setFillColor(PlatformColor.systemRed.withAlphaComponent(0.15).cgColor)
                    ctx.fillEllipse(in: ringRect)
                }
                ctx.saveGState()
                ctx.translateBy(x: center.x, y: center.y)
                ctx.rotate(by: cogRad + .pi / 2)
                let path = PlatformBezierPath()
                path.move(to: .init(x: 0,  y: -10))
                path.addLine(to: .init(x: 6, y: 8))
                path.addLine(to: .init(x: -6, y: 8))
                path.close()
                color.setFill()
                path.fill()
                PlatformColor.black.withAlphaComponent(0.6).setStroke()
                path.lineWidth = 1
                path.stroke()
                ctx.restoreGState()
            }
        }

        private static func routeWaypointIcon(index: Int, active: Bool) -> PlatformImage {
            let size: CGFloat = active ? 32 : 24
            return makeIcon(size:.init(width: size, height: size)) { ctx in
                let rect = CGRect(x: 2, y: 2, width: size - 4, height: size - 4)
                (active ? PlatformColor.systemPurple : PlatformColor.systemPurple.withAlphaComponent(0.55)).setFill()
                ctx.fillEllipse(in: rect)
                PlatformColor.white.setStroke()
                ctx.setLineWidth(active ? 2 : 1)
                ctx.strokeEllipse(in: rect)
                // Index label
                let label = String(index + 1) as NSString
                let font: PlatformFont = .systemFont(ofSize: active ? 14 : 11, weight: .bold)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: PlatformColor.white,
                ]
                let tsize = label.size(withAttributes: attrs)
                label.draw(at: .init(x: (size - tsize.width) / 2,
                                     y: (size - tsize.height) / 2),
                           withAttributes: attrs)
            }
        }

        private static func friendIcon(target: AISTarget, danger: Bool = false) -> PlatformImage {
            // Heart wrapped around a small COG-rotated arrow so friends are
            // immediately recognisable on a busy chart.
            let size: CGFloat = 36
            let center = CGPoint(x: size / 2, y: size / 2)
            let cogRad = (target.cog - 90) * .pi / 180
            return makeIcon(size:.init(width: size, height: size)) { ctx in
                if danger {
                    ctx.setStrokeColor(PlatformColor.systemRed.cgColor)
                    ctx.setLineWidth(2.5)
                    ctx.strokeEllipse(in: .init(x: 1, y: 1, width: size - 2, height: size - 2))
                }

                // Heart background
                let heart = PlatformBezierPath()
                let w: CGFloat = size - 4, h: CGFloat = size - 6
                let x: CGFloat = 2, y: CGFloat = 3
                heart.move(to: .init(x: x + w/2, y: y + h))
                heart.addCurve(to: .init(x: x, y: y + h*0.35),
                               controlPoint1: .init(x: x + w*0.15, y: y + h*0.75),
                               controlPoint2: .init(x: x,            y: y + h*0.55))
                heart.addArc(withCenter: .init(x: x + w*0.25, y: y + h*0.3),
                             radius: w*0.25, startAngle: .pi, endAngle: 0, clockwise: true)
                heart.addArc(withCenter: .init(x: x + w*0.75, y: y + h*0.3),
                             radius: w*0.25, startAngle: .pi, endAngle: 0, clockwise: true)
                heart.addCurve(to: .init(x: x + w/2, y: y + h),
                               controlPoint1: .init(x: x + w,         y: y + h*0.55),
                               controlPoint2: .init(x: x + w*0.85,    y: y + h*0.75))
                PlatformColor.systemPink.setFill()
                heart.fill()
                PlatformColor.white.setStroke()
                heart.lineWidth = 1.5
                heart.stroke()

                // Tiny direction arrow on top
                ctx.saveGState()
                ctx.translateBy(x: center.x, y: center.y - 1)
                ctx.rotate(by: cogRad + .pi / 2)
                let arrow = PlatformBezierPath()
                arrow.move(to: .init(x: 0,  y: -5))
                arrow.addLine(to: .init(x: 3.5, y: 4))
                arrow.addLine(to: .init(x: -3.5, y: 4))
                arrow.close()
                PlatformColor.white.setFill()
                arrow.fill()
                ctx.restoreGState()
            }
        }

        private static func pwAISIcon(target: PWAISTarget) -> PlatformImage {
            // PredictWind AIS uses a smaller diamond shape with a heading tick
            // and an orange tint to distinguish it from aisstream.io AIS data.
            let size: CGFloat = 22
            let center = CGPoint(x: size / 2, y: size / 2)
            let hdgRad = (target.heading - 90) * .pi / 180

            let color: PlatformColor
            switch target.type {
            case let t where t.contains("Sail"):      color = .systemTeal
            case let t where t.contains("Cargo"):     color = .systemBrown
            case let t where t.contains("Tanker"):    color = .systemRed
            case let t where t.contains("Passenger"): color = .systemBlue
            case let t where t.contains("Fishing"):   color = .systemGreen
            default:                                   color = .systemOrange
            }

            return makeIcon(size:.init(width: size, height: size)) { ctx in
                ctx.saveGState()
                ctx.translateBy(x: center.x, y: center.y)
                ctx.rotate(by: hdgRad + .pi / 2)
                // Small arrowhead pointing in heading direction
                let path = PlatformBezierPath()
                path.move(to:    .init(x:  0, y: -8))
                path.addLine(to: .init(x:  5, y:  6))
                path.addLine(to: .init(x: -5, y:  6))
                path.close()
                color.setFill()
                path.fill()
                PlatformColor.black.withAlphaComponent(0.5).setStroke()
                path.lineWidth = 0.8
                path.stroke()
                ctx.restoreGState()
            }
        }

        /// Orange circle with anchor icon + a downward triangular pointer.
        /// The tip of the pointer aligns with the map coordinate when `centerOffset`
        /// is set to (0, -(circleRadius + pointerHeight / 2)).
        /// A small orange dot marking the anchor's exact position. Drawn in a
        /// larger transparent canvas so it stays easy to grab and drag while
        /// reading as a precise point on the chart.
        private static func anchorPinImage() -> PlatformImage {
            let canvas: CGFloat = 36      // transparent touch area
            let dot:    CGFloat = 14      // visible dot
            let rect = CGRect(x: (canvas - dot) / 2, y: (canvas - dot) / 2, width: dot, height: dot)
            return makeIcon(size:.init(width: canvas, height: canvas)) { ctx in
                ctx.setShadow(offset: .init(width: 0, height: 1), blur: 3,
                              color: PlatformColor.black.withAlphaComponent(0.4).cgColor)
                ctx.setFillColor(PlatformColor.systemOrange.cgColor)
                ctx.fillEllipse(in: rect)
                ctx.setShadow(offset: .zero, blur: 0)
                ctx.setStrokeColor(PlatformColor.white.cgColor)
                ctx.setLineWidth(2.5)
                ctx.strokeEllipse(in: rect)
            }
        }

        private static func measureDot() -> PlatformImage {
            let s: CGFloat = 16
            return makeIcon(size:.init(width: s, height: s)) { ctx in
                PlatformColor.systemYellow.setFill()
                ctx.fillEllipse(in: .init(x: 0, y: 0, width: s, height: s))
                PlatformColor.black.setStroke()
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: .init(x: 0.75, y: 0.75, width: s-1.5, height: s-1.5))
            }
        }
    }
}

// MARK: - Hex color
// (PlatformColor(hex:) now lives in Platform/PlatformColor+Hex.swift)

#if os(macOS)
// MARK: - Scroll-wheel zoom (macOS)
//
// A mouse has no pinch gesture, so the wheel becomes the primary zoom control —
// zooming toward the cursor like a desktop map app. Trackpad two-finger scroll
// (precise deltas) is left to MapKit's native pan so both input styles feel right.
final class ScrollZoomMapView: MKMapView {
    var onScrollZoom: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {   // trackpad → pan natively
            super.scrollWheel(with: event)
            return
        }
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        onScrollZoom?()

        // Keep the point under the cursor fixed across the zoom.
        let pt = convert(event.locationInWindow, from: nil)
        let before = convert(pt, toCoordinateFrom: self)

        let factor = dy > 0 ? 0.85 : 1.0 / 0.85     // wheel up = zoom in
        var region = self.region
        region.span.latitudeDelta  = min(max(region.span.latitudeDelta  * factor, 0.0008), 80)
        region.span.longitudeDelta = min(max(region.span.longitudeDelta * factor, 0.0008), 80)
        setRegion(region, animated: false)

        let after = convert(pt, toCoordinateFrom: self)
        var c = centerCoordinate
        c.latitude  += before.latitude  - after.latitude
        c.longitude += before.longitude - after.longitude
        if CLLocationCoordinate2DIsValid(c) { setCenter(c, animated: false) }
    }
}
#endif
