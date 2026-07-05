//  PointerCursor.swift
//  Desktop affordance: show the pointing-hand cursor over clickable elements.
//  No-op on iOS (touch has no cursor).

import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// Pointing-hand cursor while the mouse is over this view (macOS only).
    func pointerCursor() -> some View {
        #if os(macOS)
        return self.onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #else
        return self
        #endif
    }
}
