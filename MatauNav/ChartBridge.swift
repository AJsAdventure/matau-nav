//  ChartBridge.swift
//  Lets app-level menu commands (macOS) reach the chart's zoom control, which is
//  otherwise private @State inside ChartView. ChartView registers its zoom proxy
//  here on appear; the View menu calls through it. Cross-platform (no-op on iOS).

import SwiftUI

@MainActor
@Observable
final class ChartBridge {
    weak var zoomProxy: MapZoomProxy?

    func zoomIn()  { zoomProxy?.zoomIn() }
    func zoomOut() { zoomProxy?.zoomOut() }
}
