//  ViewModifiers+Platform.swift
//  macOS no-op stand-ins for iOS-only SwiftUI modifiers, so the shared view code
//  compiles unchanged. Each shimmed modifier is genuinely unavailable on macOS
//  (verified), so there's no ambiguity with a real symbol.

import SwiftUI

#if os(macOS)

// MARK: - navigationBarTitleDisplayMode

enum NavBarTitleDisplayModeCompat { case automatic, inline, large }

extension View {
    func navigationBarTitleDisplayMode(_ mode: NavBarTitleDisplayModeCompat) -> some View { self }
}

// MARK: - keyboardType

enum KeyboardTypeCompat {
    case `default`, asciiCapable, numbersAndPunctuation, URL
    case numberPad, phonePad, namePhonePad, emailAddress, decimalPad, webSearch
}

typealias PlatformKeyboardType = KeyboardTypeCompat

extension View {
    func keyboardType(_ type: KeyboardTypeCompat) -> some View { self }
}

// MARK: - textInputAutocapitalization

struct TextInputAutocapitalizationCompat {
    static let never      = TextInputAutocapitalizationCompat()
    static let words      = TextInputAutocapitalizationCompat()
    static let sentences  = TextInputAutocapitalizationCompat()
    static let characters = TextInputAutocapitalizationCompat()
}

extension View {
    func textInputAutocapitalization(_ a: TextInputAutocapitalizationCompat?) -> some View { self }
}

// (presentationDetents / presentationDragIndicator are available on macOS — no shim needed.)

// MARK: - toolbar placements
//
// The iOS placements don't exist on macOS. Map them to the SEMANTIC actions
// (cancellation / confirmation) rather than .navigation/.primaryAction: those
// render as real buttons at the bottom of a macOS sheet AND wire up to Esc /
// Return. `.primaryAction` toolbar items do NOT render inside a sheet on macOS,
// which would leave sheets (e.g. the instrument detail panels) with no visible
// Done button and no way to dismiss — there is no swipe-to-dismiss on the Mac.
// Leading is conventionally Cancel/Close, trailing conventionally Done/Save.

extension ToolbarItemPlacement {
    static var topBarLeading:  ToolbarItemPlacement { .cancellationAction }
    static var topBarTrailing: ToolbarItemPlacement { .confirmationAction }
    static var bottomBar:      ToolbarItemPlacement { .automatic }
}

#endif
