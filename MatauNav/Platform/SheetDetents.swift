//  SheetDetents.swift
//  Cross-platform sheet sizing.
//
//  iOS: native drag-to-resize detents. macOS: there are no drag detents, and a
//  detent applied to content with no intrinsic height (a List/ScrollView inside a
//  greedy `ZStack { Color…ignoresSafeArea(); … }`) collapses the sheet to an
//  empty box — which is exactly why the anchor sheets wouldn't open. So on macOS
//  we ignore the detents and give the sheet an explicit, usable size instead.

import SwiftUI

extension View {
    @ViewBuilder
    func sheetDetents(_ detents: Set<PresentationDetent>,
                      macSize: CGSize = CGSize(width: 540, height: 640)) -> some View {
        #if os(macOS)
        frame(minWidth: macSize.width, idealWidth: macSize.width,
              minHeight: macSize.height, idealHeight: macSize.height)
        #else
        presentationDetents(detents)
        #endif
    }
}
