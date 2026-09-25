import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct LatexEditorView: View {
    @Binding var file: LatexFile
    let onSave: () -> Void
    /// Called once compilation succeeds and file.pdfURL has been updated —
    /// the parent's job is just to reveal the PDF pane for this file.
    let onCompile: () -> Void

    @AppStorage("autoSaveEnabled") private var autoSaveEnabled = true
    @AppStorage("compilerNotificationsEnabled") private var compilerNotificationsEnabled = true

    @State private var isCompiling = false
    @State private var compileLog: String?
    @State private var downloadError: String?

    var body: some View {
        VStack(spacing: 0) {
            LatexTextView(text: $file.sourceCode)

            if let compileLog {
                errorPanel(compileLog)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            statusBar
        }
        .navigationTitle(file.displayName)
        .navigationSubtitle(file.name)
        .toolbar {
            ToolbarItemGroup {
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Save .tex", systemImage: "square.and.arrow.down", action: onSave)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!file.isDirty)
                    Button("Export .tex…", systemImage: "doc.text", action: exportTex)
                }
                .help("Save or export the LaTeX source")
                Button("Download PDF", systemImage: "arrow.down.doc", action: downloadPDF)
                    .disabled(file.pdfURL == nil)
                    .help(file.pdfURL == nil ? "Compile first (⌘B)" : "Save the compiled PDF (⇧⌘S)")
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                if let pdfURL = file.pdfURL {
                    ShareLink(item: pdfURL) { Label("Share PDF", systemImage: "square.and.arrow.up") }
                        .help("Share the compiled PDF")
                }
                Button(action: compile) {
                    if isCompiling {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Compile PDF", systemImage: "hammer.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("b", modifiers: .command)
                .disabled(isCompiling)
                .help("Compile with pdflatex (⌘B)")
            }
        }
        .alert("Couldn't Save the PDF", isPresented: Binding(get: { downloadError != nil }, set: { if !$0 { downloadError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadError ?? "")
        }
        // Debounced autosave: restarts on every keystroke, fires after a pause.
        .task(id: file.sourceCode) {
            guard autoSaveEnabled, file.isDirty else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { onSave() }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            if file.isDirty {
                Label(autoSaveEnabled ? "Saving…" : "Unsaved changes", systemImage: "circle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if file.pdfURL != nil {
                Label("PDF ready", systemImage: "doc.richtext")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(lineCount) lines · \(file.sourceCode.count) characters")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .labelStyle(StatusLabelStyle())
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
        .animation(appSpring, value: file.isDirty)
    }

    private func errorPanel(_ log: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Compilation failed", systemImage: "xmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Spacer()
                Button("Dismiss", systemImage: "xmark") {
                    withAnimation(appSpring) { compileLog = nil }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            ScrollView {
                Text(log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
        }
        .padding()
        .background(.red.opacity(0.07))
        .overlay(alignment: .top) { Divider() }
    }

    private var lineCount: Int {
        file.sourceCode.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private func compile() {
        isCompiling = true
        Task {
            defer { isCompiling = false }
            do {
                let response = try await NetworkManager.shared.compilePDF(texSource: file.sourceCode)
                guard let pdfPath = response.pdfPath else {
                    throw NetworkError.serverError("The backend didn't return a PDF path.")
                }
                withAnimation(appSpring) {
                    compileLog = nil
                    file.pdfURL = URL(fileURLWithPath: pdfPath)
                    onCompile()
                }
                notifyCompiled()
            } catch {
                withAnimation(appSpring) { compileLog = error.localizedDescription }
            }
        }
    }

    /// Only worth a banner if the user has switched away while pdflatex ran.
    private func notifyCompiled() {
        guard compilerNotificationsEnabled, !NSApp.isActive else { return }
        let center = UNUserNotificationCenter.current()
        let name = file.displayName
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "PDF ready"
            content.body = "\(name) compiled successfully."
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func downloadPDF() {
        guard let pdfURL = file.pdfURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.displayName + ".pdf"
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: pdfURL, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            downloadError = error.localizedDescription
        }
    }

    private func exportTex() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.allowedContentTypes = [UTType(filenameExtension: "tex") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? file.sourceCode.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// NSTextView-backed editor with lightweight LaTeX syntax highlighting.
/// SwiftUI's TextEditor can't color ranges, and a code editor without
/// highlighting is hard to scan.
private struct LatexTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.font = Coordinator.baseFont
        textView.string = text
        scrollView.drawsBackground = false
        context.coordinator.highlight(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        context.coordinator.highlight(textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        static let baseFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        private static let rules: [(NSRegularExpression, NSColor)] = [
            (try! NSRegularExpression(pattern: #"\$[^$\n]*\$"#), .systemTeal),
            (try! NSRegularExpression(pattern: #"\\[A-Za-z@]+\*?"#), .systemPurple),
            (try! NSRegularExpression(pattern: #"\\(begin|end)\{[^}]*\}"#), .systemPink),
            (try! NSRegularExpression(pattern: #"[{}\[\]]"#), .systemOrange),
            (try! NSRegularExpression(pattern: #"(?<!\\)%.*$"#, options: .anchorsMatchLines), .secondaryLabelColor),
        ]

        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            highlight(textView)
        }

        // ponytail: re-highlights the whole document per keystroke — fine for
        // one-to-two page resumes; switch to edited-range highlighting if
        // this ever hosts long documents.
        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let range = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: Self.baseFont, .foregroundColor: NSColor.labelColor], range: range)
            for (regex, color) in Self.rules {
                regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
                    if let match { storage.addAttribute(.foregroundColor, value: color, range: match.range) }
                }
            }
            storage.endEditing()
        }
    }
}

#Preview {
    @Previewable @State var file = LatexFile(
        name: "Sample.tex",
        sourceCode: "\\documentclass{article}\n% comment\n\\begin{document}\nHello $x^2$\n\\end{document}",
        savedSource: ""
    )
    NavigationStack {
        LatexEditorView(file: $file, onSave: {}, onCompile: {})
    }
}
