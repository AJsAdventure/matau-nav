//  Platform.swift
//  Cross-platform primitives so the iOS code compiles on macOS with minimal #if.
//
//  Strategy: typealias the UIKit/AppKit pairs, and give AppKit's NSBezierPath the
//  small slice of the UIKit API the chart icon factories use. Behaviour-level
//  splits (sleep assertions, attention requests) live in their own shim files.

import SwiftUI

#if canImport(UIKit)
import UIKit

typealias PlatformColor       = UIColor
typealias PlatformImage       = UIImage
typealias PlatformFont        = UIFont
typealias PlatformBezierPath  = UIBezierPath
typealias PlatformViewRepresentable           = UIViewRepresentable
typealias PlatformViewControllerRepresentable = UIViewControllerRepresentable
typealias PlatformGestureRecognizer           = UIGestureRecognizer
typealias PlatformGestureRecognizerDelegate   = UIGestureRecognizerDelegate
typealias PlatformKeyboardType                = UIKeyboardType

#elseif canImport(AppKit)
import AppKit

typealias PlatformColor       = NSColor
typealias PlatformImage       = NSImage
typealias PlatformFont        = NSFont
typealias PlatformBezierPath  = NSBezierPath
typealias PlatformViewRepresentable           = NSViewRepresentable
typealias PlatformViewControllerRepresentable = NSViewControllerRepresentable
typealias PlatformGestureRecognizer           = NSGestureRecognizer
typealias PlatformGestureRecognizerDelegate   = NSGestureRecognizerDelegate

// MARK: - NSBezierPath ⟶ UIBezierPath-compatible surface
//
// Only the methods the chart icon factories actually call. Angles are passed in
// radians to match UIKit; NSBezierPath wants degrees, so convert here. The icon
// images are drawn into a flipped context (see makeIcon) so the y-down
// CoreGraphics trig in ChartMapView ports unchanged.
extension NSBezierPath {
    func addLine(to point: CGPoint) { line(to: point) }

    func addCurve(to end: CGPoint, controlPoint1 c1: CGPoint, controlPoint2 c2: CGPoint) {
        curve(to: end, controlPoint1: c1, controlPoint2: c2)
    }

    func addArc(withCenter center: CGPoint, radius: CGFloat,
                startAngle: CGFloat, endAngle: CGFloat, clockwise: Bool) {
        // In a flipped drawing context the visual winding inverts, so flip the
        // clockwise flag to match what UIKit produces in the same orientation.
        appendArc(withCenter: center, radius: radius,
                  startAngle: startAngle * 180 / .pi,
                  endAngle: endAngle * 180 / .pi,
                  clockwise: !clockwise)
    }
}
#endif

// MARK: - Cross-platform raster icon rendering
//
// Replaces `UIGraphicsImageRenderer(size:).image { c in … c.cgContext … }`.
// The closure receives a CGContext; UIKit/AppKit colour `.setFill()`, bezier
// `.fill()`/`.stroke()`, and `NSString.draw(at:)` all target the pushed current
// context inside the block on both platforms. Rendering is eager (the closure
// runs synchronously on the calling thread — call from the main thread).
func makeIcon(size: CGSize, _ draw: (CGContext) -> Void) -> PlatformImage {
    #if canImport(UIKit)
    return UIGraphicsImageRenderer(size: size).image { ctx in
        draw(ctx.cgContext)
    }
    #elseif canImport(AppKit)
    let image = NSImage(size: size)
    image.lockFocusFlipped(true)
    if let cg = NSGraphicsContext.current?.cgContext { draw(cg) }
    image.unlockFocus()
    return image
    #endif
}
