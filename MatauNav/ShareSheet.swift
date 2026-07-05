import SwiftUI

/// Cross-platform share UI for exported files (GPX).
/// iOS: UIActivityViewController. macOS: a small panel with ShareLink + Save As.
struct ShareSheet: View {
    let items: [Any]

    var body: some View {
        #if canImport(UIKit)
        _ActivityView(items: items)
        #else
        _MacShareView(items: items)
        #endif
    }
}

#if canImport(UIKit)
import UIKit

private struct _ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

#elseif canImport(AppKit)
import AppKit

private struct _MacShareView: View {
    let items: [Any]
    @Environment(\.dismiss) private var dismiss

    private var fileURL: URL? { items.compactMap { $0 as? URL }.first }

    var body: some View {
        VStack(spacing: 16) {
            Text("Export GPX").font(.headline)
            if let url = fileURL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                HStack(spacing: 12) {
                    ShareLink(item: url) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        saveAs(url)
                    } label: {
                        Label("Save to…", systemImage: "folder")
                    }
                }
            } else {
                Text("Nothing to share").foregroundStyle(Color.textSecondary)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(minWidth: 340)
    }

    private func saveAs(_ url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        dismiss()
    }
}
#endif
