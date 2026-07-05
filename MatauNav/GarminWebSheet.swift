import SwiftUI
import WebKit
import CoreLocation

// MARK: - GarminWebSheet
//
// Opens Garmin's marine viewer (maps.garmin.com/en-US/marine) in a WKWebView,
// deep-linked to the vessel's current position. Read-only — there's no
// integration with the rest of the app; this is just a "second opinion"
// reference for harbour entries / chart cross-check.
//
// Garmin's viewer is a public web product. We're using it as a normal user
// would; we're not scraping tiles or rendering their cartography ourselves.

struct GarminWebSheet: View {
    let center: CLLocationCoordinate2D
    let zoom: Int

    @Environment(\.dismiss) private var dismiss

    private var url: URL? {
        // Same query base as the working one, but with SonarChart selected
        // (maps=sonarchart) and the vessel lat/lon/zoom appended. We pass the
        // coords under several common parameter spellings because Garmin's
        // marine viewer doesn't document its URL API — at least one of them
        // tends to win in practice.
        let lat = String(format: "%.6f", center.latitude)
        let lon = String(format: "%.6f", center.longitude)
        var s = "https://maps.garmin.com/en-US/marine"
        s += "?maps=sonarchart"
        s += "&units=metric"
        s += "&overlay=false"
        s += "&heatmap=false"
        s += "&key=9z1fmr1ux877"
        s += "&lat=\(lat)&lon=\(lon)"           // common
        s += "&latitude=\(lat)&longitude=\(lon)" // alt spelling
        s += "&center=\(lat),\(lon)"             // comma-pair
        s += "&zoom=\(zoom)"
        return URL(string: s)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let url {
                    WebView(url: url)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    Text("Couldn't build Garmin URL.")
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .navigationTitle("Garmin (reference)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let url {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - NavionicsWebSheet
//
// Opens the Navionics web app (webapp.navionics.com) in the same in-app
// slide-over browser as the Garmin sheet, centred on the vessel — instead of
// bouncing out to Safari or the Boating app.

struct NavionicsWebSheet: View {
    let center: CLLocationCoordinate2D
    let zoom: Int

    @Environment(\.dismiss) private var dismiss

    private var url: URL? {
        let lat = String(format: "%.6f", center.latitude)
        let lon = String(format: "%.6f", center.longitude)
        // The webapp reads the view from the URL fragment: #boating@<zoom>&key=lat,lon
        let s = "https://webapp.navionics.com/?lng=en#boating@\(zoom)&key=\(lat),\(lon)"
        return URL(string: s)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let url {
                    WebView(url: url).ignoresSafeArea(edges: .bottom)
                } else {
                    Text("Couldn't build Navionics URL.")
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .navigationTitle("Navionics (reference)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let url { Link(destination: url) { Image(systemName: "arrow.up.right.square") } }
                }
            }
        }
    }
}

private struct WebView: PlatformViewRepresentable {
    let url: URL

    private func makeWeb() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        #if canImport(UIKit)
        cfg.allowsInlineMediaPlayback = true
        #endif
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.allowsBackForwardNavigationGestures = true
        wv.load(URLRequest(url: url))
        return wv
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWeb() }
    func updateNSView(_ wv: WKWebView, context: Context) {}
    #else
    func makeUIView(context: Context) -> WKWebView { makeWeb() }
    func updateUIView(_ wv: WKWebView, context: Context) {}
    #endif
}
