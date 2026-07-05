import Foundation
import Observation
import MapKit

// MARK: - Tile maths

enum TileMath {
    static func lonToTileX(_ lon: Double, z: Int) -> Int {
        Int(floor((lon + 180) / 360 * Double(1 << z)))
    }
    static func latToTileY(_ lat: Double, z: Int) -> Int {
        let r = lat * .pi / 180
        let n = Double(1 << z)
        return Int(floor((1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * n))
    }
    static func tileCount(minLat: Double, minLon: Double,
                          maxLat: Double, maxLon: Double,
                          zoom: Int) -> Int {
        let x0 = lonToTileX(minLon, z: zoom)
        let x1 = lonToTileX(maxLon, z: zoom)
        let y0 = latToTileY(maxLat, z: zoom)   // y inverted: north = smaller y
        let y1 = latToTileY(minLat, z: zoom)
        return max(0, (x1 - x0 + 1) * (y1 - y0 + 1))
    }
    static func totalTiles(minLat: Double, minLon: Double,
                           maxLat: Double, maxLon: Double,
                           minZoom: Int, maxZoom: Int) -> Int {
        (minZoom...maxZoom).reduce(0) { $0 + tileCount(
            minLat: minLat, minLon: minLon,
            maxLat: maxLat, maxLon: maxLon, zoom: $1) }
    }
}

// MARK: - Downloader

@Observable
@MainActor
final class TileDownloader {

    var inProgress: Bool = false
    var total: Int = 0
    var completed: Int = 0
    var failed: Int = 0
    var bytes: Int = 0
    var statusMessage: String = ""

    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
        inProgress = false
        statusMessage = "Cancelled"
    }

    /// Download OSM base + OpenSeaMap seamark + ESRI satellite layers for a
    /// region in one go. Each layer goes into its own disk cache; toggling
    /// layers in Chart settings reads from these caches instantly.
    func downloadAll(minLat: Double, minLon: Double,
                     maxLat: Double, maxLon: Double,
                     minZoom: Int, maxZoom: Int,
                     onFinish: @escaping @Sendable (Int, Int) -> Void) {
        if inProgress { return }
        inProgress = true
        completed = 0; failed = 0; bytes = 0
        let perLayer = TileMath.totalTiles(
            minLat: minLat, minLon: minLon,
            maxLat: maxLat, maxLon: maxLon,
            minZoom: minZoom, maxZoom: maxZoom
        )
        total = perLayer * 4   // OSM + seamark + satellite + bathymetry
        statusMessage = "Starting…"

        task = Task.detached(priority: .utility) { [weak self] in
            // Layer 1: OSM base
            await self?.runDownload(minLat: minLat, minLon: minLon,
                                    maxLat: maxLat, maxLon: maxLon,
                                    minZoom: minZoom, maxZoom: maxZoom,
                                    satellite: false, includeSeaMap: false,
                                    finalize: false, onFinish: { _, _ in })
            if Task.isCancelled { await self?.finalize(onFinish: onFinish); return }
            // Layer 2: OpenSeaMap seamarks
            await self?.runDownload(minLat: minLat, minLon: minLon,
                                    maxLat: maxLat, maxLon: maxLon,
                                    minZoom: minZoom, maxZoom: maxZoom,
                                    satellite: false, includeSeaMap: true,
                                    seamarkOnly: true,
                                    finalize: false, onFinish: { _, _ in })
            if Task.isCancelled { await self?.finalize(onFinish: onFinish); return }
            // Layer 3: satellite
            await self?.runDownload(minLat: minLat, minLon: minLon,
                                    maxLat: maxLat, maxLon: maxLon,
                                    minZoom: minZoom, maxZoom: maxZoom,
                                    satellite: true, includeSeaMap: false,
                                    finalize: false, onFinish: { _, _ in })
            if Task.isCancelled { await self?.finalize(onFinish: onFinish); return }
            // Layer 4: EMODnet bathymetry
            await self?.runDownload(minLat: minLat, minLon: minLon,
                                    maxLat: maxLat, maxLon: maxLon,
                                    minZoom: minZoom, maxZoom: maxZoom,
                                    satellite: false, includeSeaMap: false,
                                    bathyOnly: true,
                                    finalize: false, onFinish: { _, _ in })
            await self?.finalize(onFinish: onFinish)
        }
    }

    @MainActor
    private func finalize(onFinish: @Sendable (Int, Int) -> Void) {
        let cancelled = Task.isCancelled
        inProgress = false
        statusMessage = cancelled
            ? "Cancelled · \(completed) tiles cached"
            : "Done · \(completed) tiles · \(Self.fmtBytes(bytes))"
        onFinish(completed, bytes)
    }

    /// Legacy single-layer entry point — still used internally and tests.
    func download(minLat: Double, minLon: Double,
                  maxLat: Double, maxLon: Double,
                  minZoom: Int, maxZoom: Int,
                  satellite: Bool,
                  includeSeaMap: Bool,
                  onFinish: @escaping @Sendable (Int /*tiles*/, Int /*bytes*/) -> Void) {

        if inProgress { return }
        inProgress = true
        completed = 0; failed = 0; bytes = 0
        total = TileMath.totalTiles(
            minLat: minLat, minLon: minLon,
            maxLat: maxLat, maxLon: maxLon,
            minZoom: minZoom, maxZoom: maxZoom
        ) * (includeSeaMap ? 2 : 1)
        statusMessage = "Starting…"

        task = Task.detached(priority: .utility) { [weak self] in
            await self?.runDownload(
                minLat: minLat, minLon: minLon,
                maxLat: maxLat, maxLon: maxLon,
                minZoom: minZoom, maxZoom: maxZoom,
                satellite: satellite, includeSeaMap: includeSeaMap,
                onFinish: onFinish
            )
        }
    }

    private nonisolated func runDownload(minLat: Double, minLon: Double,
                                         maxLat: Double, maxLon: Double,
                                         minZoom: Int, maxZoom: Int,
                                         satellite: Bool,
                                         includeSeaMap: Bool,
                                         seamarkOnly: Bool = false,
                                         bathyOnly: Bool = false,
                                         finalize: Bool = true,
                                         onFinish: @escaping @Sendable (Int, Int) -> Void) async {

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let baseCache = caches.appendingPathComponent(
            satellite ? "matau_tiles_satellite" : "matau_tiles_standard")
        let seamCache = caches.appendingPathComponent("matau_tiles_seamark")
        let bathCache = caches.appendingPathComponent("matau_tiles_bathymetry")
        try? FileManager.default.createDirectory(at: baseCache, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: seamCache, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bathCache, withIntermediateDirectories: true)

        let sess: URLSession = {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 8
            cfg.httpMaximumConnectionsPerHost = 6
            return URLSession(configuration: cfg)
        }()

        for z in minZoom...maxZoom {
            if Task.isCancelled { break }
            let x0 = TileMath.lonToTileX(minLon, z: z)
            let x1 = TileMath.lonToTileX(maxLon, z: z)
            let y0 = TileMath.latToTileY(maxLat, z: z)
            let y1 = TileMath.latToTileY(minLat, z: z)

            // Throttled concurrency: process this zoom level in chunks of 6.
            let coords: [(Int, Int)] = (x0...x1).flatMap { x in (y0...y1).map { y in (x, y) } }
            for chunk in coords.chunked(into: 6) {
                if Task.isCancelled { break }
                await withTaskGroup(of: (Bool, Int).self) { group in
                    for (x, y) in chunk {
                        if !seamarkOnly && !bathyOnly {
                            group.addTask { [satellite] in
                                await Self.fetchOne(session: sess, z: z, x: x, y: y,
                                                   satellite: satellite, cacheRoot: baseCache)
                            }
                        }
                        if includeSeaMap || seamarkOnly {
                            group.addTask {
                                await Self.fetchSeamark(session: sess, z: z, x: x, y: y, cacheRoot: seamCache)
                            }
                        }
                        if bathyOnly, z >= 6 {
                            group.addTask {
                                await Self.fetchBathymetry(session: sess, z: z, x: x, y: y, cacheRoot: bathCache)
                            }
                        }
                    }
                    var localBytes = 0
                    var localOK = 0
                    var localFail = 0
                    for await (ok, b) in group {
                        if ok { localOK += 1; localBytes += b } else { localFail += 1 }
                    }
                    let lo = localOK, lf = localFail, lb = localBytes
                    await MainActor.run {
                        self.completed += lo
                        self.failed    += lf
                        self.bytes     += lb
                        self.statusMessage = "z\(z) · \(self.completed)/\(self.total) tiles · \(Self.fmtBytes(self.bytes))"
                    }
                }
            }
        }

        guard finalize else { return }
        let cancelled = Task.isCancelled
        let finalTiles = await self.completed
        let finalBytes = await self.bytes
        await MainActor.run {
            self.inProgress = false
            self.statusMessage = cancelled
                ? "Cancelled · \(finalTiles) tiles cached"
                : "Done · \(finalTiles) tiles · \(Self.fmtBytes(finalBytes))"
            onFinish(finalTiles, finalBytes)
        }
    }

    private static func fetchOne(session: URLSession, z: Int, x: Int, y: Int,
                                 satellite: Bool, cacheRoot: URL) async -> (Bool, Int) {
        let dir  = cacheRoot.appendingPathComponent("\(z)").appendingPathComponent("\(x)")
        let file = dir.appendingPathComponent("\(y).tile")
        if let existing = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, existing > 0 {
            return (true, 0)        // already cached; no new bytes
        }
        let url: URL = {
            if satellite {
                return URL(string: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/\(z)/\(y)/\(x)")!
            }
            let servers = ["a", "b", "c"]
            let s = servers[(x + y) % servers.count]
            return URL(string: "https://\(s).tile.openstreetmap.org/\(z)/\(x)/\(y).png")!
        }()
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("MatauNav/1.0 (sailing chart prefetch)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  TileImageValidator.looksLikeImage(data) else { return (false, 0) }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: file)
            return (true, data.count)
        } catch {
            return (false, 0)
        }
    }

    private static func fetchSeamark(session: URLSession, z: Int, x: Int, y: Int,
                                     cacheRoot: URL) async -> (Bool, Int) {
        let dir  = cacheRoot.appendingPathComponent("\(z)").appendingPathComponent("\(x)")
        let file = dir.appendingPathComponent("\(y).tile")
        if let existing = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, existing > 0 {
            return (true, 0)
        }
        // OpenSeaMap seamark transparent tiles — canonical host only (the t1/t2/t3
        // shards currently serve a default Traefik cert, which ATS blocks).
        guard let url = URL(string: "https://tiles.openseamap.org/seamark/\(z)/\(x)/\(y).png") else { return (false, 0) }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("MatauNav/1.0 (sailing chart prefetch)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  TileImageValidator.looksLikeImage(data) else { return (false, 0) }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: file)
            return (true, data.count)
        } catch {
            return (false, 0)
        }
    }

    private static func fetchBathymetry(session: URLSession, z: Int, x: Int, y: Int,
                                        cacheRoot: URL) async -> (Bool, Int) {
        let dir  = cacheRoot.appendingPathComponent("\(z)").appendingPathComponent("\(x)")
        let file = dir.appendingPathComponent("\(y).tile")
        if let existing = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, existing > 0 {
            return (true, 0)
        }
        // EMODnet Bathymetry — CC-BY 4.0 (attribution shown in app)
        guard let url = URL(string: "https://tiles.emodnet-bathymetry.eu/latest/mean_multicolour/web_mercator/\(z)/\(x)/\(y).png")
        else { return (false, 0) }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("MatauNav/1.0 (sailing chart prefetch)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  TileImageValidator.looksLikeImage(data) else { return (false, 0) }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: file)
            return (true, data.count)
        } catch {
            return (false, 0)
        }
    }

    static func fmtBytes(_ n: Int) -> String {
        let mb = Double(n) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(n) / 1024
        return String(format: "%.0f KB", kb)
    }

    /// Wipe all cached tiles. Used by the Chart settings "Clear cache" button.
    static func clearAllCaches() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for name in ["matau_tiles_standard", "matau_tiles_satellite", "matau_tiles_seamark", "matau_tiles_bathymetry"] {
            let url = caches.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func cacheSizeBytes() -> Int {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var total = 0
        for name in ["matau_tiles_standard", "matau_tiles_satellite", "matau_tiles_seamark", "matau_tiles_bathymetry"] {
            let root = caches.appendingPathComponent(name)
            guard let enumerator = FileManager.default.enumerator(at: root,
                                          includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let url as URL in enumerator {
                if let v = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += v
                }
            }
        }
        return total
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
