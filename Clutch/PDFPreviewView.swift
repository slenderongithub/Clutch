import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct PDFPreviewView: View {
    let fileName: String
    let pdfURL: URL?

    var body: some View {
        Group {
            if let pdfURL, let document = PDFDocument(url: pdfURL) {
                PDFKitRepresentedView(document: document)
                    .overlay(alignment: .bottomTrailing) { actions(for: pdfURL) }
            } else {
                ContentUnavailableView(
                    "No PDF Yet",
                    systemImage: "doc.richtext",
                    description: Text("Compile the resume (⌘B) to preview it here.")
                )
            }
        }
    }

    /// Just "open in Preview" — downloading lives in the main toolbar.
    private func actions(for url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label("Open in Preview", systemImage: "arrow.up.forward.app")
                .labelStyle(.iconOnly)
                .padding(8)
        }
        .buttonStyle(.borderless)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding()
        .help("Open in Preview")
    }
}

/// Wraps AppKit's native PDFView so SwiftUI can host it.
private struct PDFKitRepresentedView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .clear
        pdfView.document = document
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != document.documentURL {
            nsView.document = document
        }
    }
}

#Preview {
    PDFPreviewView(fileName: "Sample.tex", pdfURL: nil)
}
