//  PlatformSymbol.swift
//  Render an SF Symbol into a tinted raster image for use as an MKAnnotationView
//  image. Replaces `UIImage(systemName:).withTintColor(.alwaysOriginal)`.

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A tinted, fixed-point-size SF Symbol image, or an empty image if the symbol
/// name is unknown.
func tintedSymbol(_ name: String,
                  pointSize: CGFloat,
                  weight: PlatformFont.Weight = .regular,
                  color: PlatformColor) -> PlatformImage {
    #if canImport(UIKit)
    let conf = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .init(weight))
    return UIImage(systemName: name, withConfiguration: conf)?
        .withTintColor(color, renderingMode: .alwaysOriginal) ?? UIImage()
    #elseif canImport(AppKit)
    let conf = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(conf) else { return NSImage() }
    let size = base.size
    let out = NSImage(size: size)
    out.lockFocus()
    color.set()
    let rect = NSRect(origin: .zero, size: size)
    base.draw(in: rect)
    rect.fill(using: .sourceAtop)   // tint the template glyph
    out.unlockFocus()
    out.isTemplate = false
    return out
    #endif
}

#if canImport(UIKit)
private extension UIImage.SymbolWeight {
    init(_ w: UIFont.Weight) {
        switch w {
        case .ultraLight: self = .ultraLight
        case .thin:       self = .thin
        case .light:      self = .light
        case .medium:     self = .medium
        case .semibold:   self = .semibold
        case .bold:       self = .bold
        case .heavy:      self = .heavy
        case .black:      self = .black
        default:          self = .regular
        }
    }
}
#endif
