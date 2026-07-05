import Foundation
import Observation
import CoreLocation

// MARK: - Track model

struct TrackPoint: Codable, Equatable {
    let lat: Double
    let lon: Double
    let t:   Double        // unix seconds
    let sog: Double?       // knots
    let cog: Double?       // degrees
}

struct Track: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var source: Source
    var points: [TrackPoint]
    var createdAt: Double = Date().timeIntervalSince1970
    var visible: Bool = true
    var colorHex: String = "#00CEDF"   // matches accent cyan; overridable per track

    enum Source: String, Codable { case pi, local, gpx }
}

// MARK: - Track service
//
// Sources:
//   • Pi recording — fetched from /tracks on the SignalK Pi (a tiny HTTP API
//     added by the Matau Pi service). Falls back silently if unavailable.
//   • Local recording — every successful SignalK position fix is appended to a
//     rolling "live track" while the app is running.
//   • GPX import — user picks a .gpx file from Files; parsed and stored.

@Observable
@MainActor
final class TrackService {

    var tracks: [Track] = []                 // imported / fetched tracks
    private(set) var liveTrack: Track = Track(name: "Live", source: .local, points: [])
    private(set) var lastError: String?

    private var lastRecordAt: Date = .distantPast
    private let storeURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storeURL = docs.appendingPathComponent("matau_tracks.json")
        load()
    }

    // MARK: Persistence

    private func load() {
        // Decode off-main: this store grows to several MB (5.2 MB observed in
        // the field) and a synchronous decode here stalled every app launch.
        let url = storeURL
        Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url),
                  let arr  = try? JSONDecoder().decode([Track].self, from: data) else { return }
            await MainActor.run {
                // Don't clobber tracks the user created before the load landed.
                if self.tracks.isEmpty { self.tracks = arr }
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: Live recording

    /// Called from the app's background polling task whenever SignalK has a fresh fix.
    /// We thin to one point every 10 s to keep the trail compact.
    func recordLive(lat: Double, lon: Double, sog: Double, cog: Double) {
        guard lat != 0 || lon != 0 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastRecordAt) >= 10 else { return }
        lastRecordAt = now
        liveTrack.points.append(.init(
            lat: lat, lon: lon,
            t: now.timeIntervalSince1970,
            sog: sog, cog: cog
        ))
        // Trim to last 24h to keep memory bounded
        let cutoff = now.addingTimeInterval(-86400).timeIntervalSince1970
        if let first = liveTrack.points.first?.t, first < cutoff {
            liveTrack.points.removeAll { $0.t < cutoff }
        }
    }

    /// Persist the live trail as a named track and start fresh.
    func saveLiveAsTrack(name: String) {
        guard liveTrack.points.count > 1 else { return }
        var copy = liveTrack
        copy.id = UUID()
        copy.name = name
        copy.createdAt = Date().timeIntervalSince1970
        tracks.insert(copy, at: 0)
        liveTrack = Track(name: "Live", source: .local, points: [])
        save()
    }

    func setVisible(_ id: UUID, visible: Bool) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].visible = visible
        save()
    }

    func delete(_ id: UUID) {
        tracks.removeAll { $0.id == id }
        save()
    }

    // MARK: Pi tracks
    //
    // The Pi exposes:
    //   GET /tracks            → [{ "id": "...", "name": "...", "points": <count>, "start": <ts>, "end": <ts> }]
    //   GET /tracks/<id>       → [{ "lat":..., "lon":..., "t":..., "sog":..., "cog":... }]

    /// `baseURL` is the SignalK base (e.g. http://matau.local:3000).
    /// The track recorder listens on a separate port (default 10113) on the
    /// same host — we derive it here.
    func fetchPiTracks(baseURL: String) async {
        guard let comps = URLComponents(string: baseURL), let host = comps.host else { return }
        let trackBase = "http://\(host):10113"
        guard let listURL = URL(string: "\(trackBase)/tracks") else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: listURL, timeoutInterval: 8))
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                lastError = "Pi /tracks returned \( (resp as? HTTPURLResponse)?.statusCode ?? 0 )"
                return
            }
            struct Summary: Decodable { let id: String; let name: String? }
            let summaries = (try? JSONDecoder().decode([Summary].self, from: data)) ?? []
            for s in summaries {
                if tracks.contains(where: { $0.name == "Pi:\(s.id)" }) { continue }
                guard let detailURL = URL(string: "\(trackBase)/tracks/\(s.id)"),
                      let (pdata, _) = try? await URLSession.shared.data(for: URLRequest(url: detailURL, timeoutInterval: 15)),
                      let points = try? JSONDecoder().decode([TrackPoint].self, from: pdata) else { continue }
                guard points.count > 1 else { continue }
                let t = Track(name: "Pi:\(s.name ?? s.id)", source: .pi, points: points)
                tracks.insert(t, at: 0)
            }
            save()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: GPX import

    func importGPX(from url: URL) throws {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let points = GPXParser.parse(data: data)
        guard points.count > 1 else { throw NSError(domain: "TrackService", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "GPX file contains no track points"]) }
        let name = url.deletingPathExtension().lastPathComponent
        let track = Track(name: name, source: .gpx, points: points)
        tracks.insert(track, at: 0)
        save()
    }
}

// MARK: - GPX parser (track points only)
//
// Minimal SAX parser that extracts <trkpt lat lon> with optional <time>, <speed>,
// <course>. Handles both <trkpt> and <rtept>/<wpt> as fallback so route exports
// also yield a trail.

final class GPXParser: NSObject, XMLParserDelegate {

    static func parse(data: Data) -> [TrackPoint] {
        let p = GPXParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.points
    }

    private var points: [TrackPoint] = []
    private var curLat: Double?
    private var curLon: Double?
    private var curTimeStr: String = ""
    private var curSpeed: Double?
    private var curCourse: Double?
    private var insidePoint = false
    private var charBuffer = ""

    private let timeFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let timeFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func parser(_ p: XMLParser, didStartElement el: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attrs: [String: String]) {
        switch el {
        case "trkpt", "rtept", "wpt":
            insidePoint = true
            curLat = Double(attrs["lat"] ?? "")
            curLon = Double(attrs["lon"] ?? "")
            curTimeStr = ""
            curSpeed = nil
            curCourse = nil
        default: break
        }
        charBuffer = ""
    }

    func parser(_ p: XMLParser, foundCharacters s: String) {
        charBuffer += s
    }

    func parser(_ p: XMLParser, didEndElement el: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let text = charBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch el {
        case "time" where insidePoint:
            curTimeStr = text
        case "speed" where insidePoint:
            curSpeed = Double(text).map { $0 * 1.94384 }   // m/s → knots
        case "course" where insidePoint:
            curCourse = Double(text)
        case "trkpt", "rtept", "wpt":
            if let lat = curLat, let lon = curLon {
                let t = timeFormatter.date(from: curTimeStr)
                      ?? timeFormatterNoFrac.date(from: curTimeStr)
                      ?? Date(timeIntervalSince1970: Double(points.count))
                points.append(.init(
                    lat: lat, lon: lon,
                    t: t.timeIntervalSince1970,
                    sog: curSpeed, cog: curCourse
                ))
            }
            insidePoint = false
        default: break
        }
        charBuffer = ""
    }
}
