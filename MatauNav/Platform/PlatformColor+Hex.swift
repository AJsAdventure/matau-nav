//  PlatformColor+Hex.swift
//  Hex initialiser shared by both platforms (was a UIColor extension inside
//  ChartMapView; ContourService and the renderers use it too).

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import CoreGraphics

extension PlatformColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xff) / 255
        let g = CGFloat((v >> 8)  & 0xff) / 255
        let b = CGFloat(v         & 0xff) / 255
        #if canImport(UIKit)
        self.init(red: r, green: g, blue: b, alpha: 1)
        #else
        // sRGB so colours match the iOS build exactly.
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
        #endif
    }
}
