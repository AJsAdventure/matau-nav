//  Haptics.swift
//  Thin haptic feedback shim. No-op on macOS (the map's long-press feedback has
//  no touch analogue; trackpad haptics would fire on every right-click which is
//  more annoying than useful).

#if canImport(UIKit)
import UIKit
#endif

enum Haptics {
    /// Light selection tick — used when placing/moving map markers.
    @MainActor static func selection() {
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    /// Heavier confirmation tap — used for destructive or committing actions.
    @MainActor static func impact() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
}
