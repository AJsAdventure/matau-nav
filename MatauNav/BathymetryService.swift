import Foundation
import Observation
import CoreLocation

// MARK: - BathymetryService
//
// Looks up seabed depth at any coordinate by hitting EMODnet's WMS
// GetFeatureInfo endpoint on the raw `emodnet:mean` coverage. Returns the
// `Depth` property in metres (negative below sea level, positive above).
//
// Coverage: European seas (good Mediterranean / NE Atlantic resolution).
// Outside coverage, EMODnet returns no features → we surface nil.
//
// Two surfaces:
//   • `depth(at:) async -> Double?` — one-shot lookup, used by the long-press
//     menu / "Show depth here" action.
//   • `vesselDepth` — live readout under the boat, refreshed every 10 s when
//     the vessel position changes. Throttled because the EMODnet endpoint is
//     a shared public service.

@Observable
@MainActor
final class BathymetryService {

    /// Latest depth under the vessel, in metres (negative = below sea level).
    /// nil until first successful lookup, or if outside coverage.
    private(set) var vesselDepth: Double?
    /// When the vessel-depth lookup last succeeded.
    private(set) var lastUpdate: Date?

    private var pollTask: Task<Void, Never>?
    /// We re-query only when the vessel has drifted at least this far
    /// (≈100 m at the equator) — cheap protection against spamming the API.
    private let minMoveDeg: Double = 0.001
    private var lastQueriedLat: Double = 0
    private var lastQueriedLon: Double = 0

    /// Start watching the SignalK vessel position and update `vesselDepth`
    /// whenever the boat moves meaningfully.
    func startWatchingVessel(_ signalK: SignalKService) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let lat = signalK.latitude, lon = signalK.longitude
                if lat != 0 || lon != 0 {
                    let moved = abs(lat - self.lastQueriedLat) > self.minMoveDeg
                              || abs(lon - self.lastQueriedLon) > self.minMoveDeg
                    if moved {
                        self.lastQueriedLat = lat
                        self.lastQueriedLon = lon
                        if let d = await BathymetryService.fetchDepth(lat: lat, lon: lon) {
                            self.vesselDepth = d
                            self.lastUpdate  = Date()
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    /// One-shot lookup for an arbitrary coordinate (long-press menu).
    /// Returns metres (negative below sea level), or nil outside coverage /
    /// on error.
    static func depth(at coord: CLLocationCoordinate2D) async -> Double? {
        await fetchDepth(lat: coord.latitude, lon: coord.longitude)
    }

    // MARK: HTTP

    /// Build a 1-pixel WMS GetFeatureInfo request around (lat, lon). The
    /// `emodnet:mean` layer returns raw depth as a `Depth` property in metres.
    private static func fetchDepth(lat: Double, lon: Double) async -> Double? {
        let d = 0.0005          // ~50 m bbox around point
        // EPSG:4326 axis order in WMS 1.3 is lat,lon — minLat,minLon,maxLat,maxLon.
        let bbox = "\(lat - d),\(lon - d),\(lat + d),\(lon + d)"
        var c = URLComponents(string: "https://ows.emodnet-bathymetry.eu/wms")
        c?.queryItems = [
            URLQueryItem(name: "service",       value: "WMS"),
            URLQueryItem(name: "version",       value: "1.3.0"),
            URLQueryItem(name: "request",       value: "GetFeatureInfo"),
            URLQueryItem(name: "layers",        value: "emodnet:mean"),
            URLQueryItem(name: "query_layers",  value: "emodnet:mean"),
            URLQueryItem(name: "crs",           value: "EPSG:4326"),
            URLQueryItem(name: "bbox",          value: bbox),
            URLQueryItem(name: "width",         value: "2"),
            URLQueryItem(name: "height",        value: "2"),
            URLQueryItem(name: "i",             value: "1"),
            URLQueryItem(name: "j",             value: "1"),
            URLQueryItem(name: "info_format",   value: "application/json"),
        ]
        guard let url = c?.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue("MatauNav/1.0 (sailing depth lookup)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return decodeDepth(data)
        } catch { return nil }
    }

    private static func decodeDepth(_ data: Data) -> Double? {
        struct R: Decodable {
            struct Feature: Decodable {
                struct Props: Decodable {
                    // EMODnet returns either "Depth" or "GRAY_INDEX" depending
                    // on what GeoServer happens to publish for that mosaic
                    // version — both decoded.
                    let Depth: Double?
                    let GRAY_INDEX: Double?
                }
                let properties: Props
            }
            let features: [Feature]
        }
        guard let r = try? JSONDecoder().decode(R.self, from: data),
              let first = r.features.first else { return nil }
        return first.properties.Depth ?? first.properties.GRAY_INDEX
    }
}
