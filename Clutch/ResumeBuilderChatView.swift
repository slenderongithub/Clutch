import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatMessage: Identifiable {
    enum Role {
        case user
        case assistant
    }

    /// A file the user shared — shown as a chip; its text is parsed silently.
    struct Attachment {
        let name: String
        let url: URL
        let pageCount: Int?
        let wordCount: Int
    }

    let id = UUID()
    let role: Role
    let text: String
    var isError = false
    var attachment: Attachment?
}

struct ResumeBuilderChatView: View {
    @Binding var selectedTemplate: ResumeTemplate?
    let session: RetrievalSession
    /// Called with the compiled .tex source once generation succeeds — the
    /// parent turns it into a new LatexFile and hands off to the IDE.
    let onGenerate: (String) -> Void

    @AppStorage("inferenceMode") private var inferenceMode: InferenceMode = .cloud
    @State private var secrets = Secrets.shared
    @AppStorage("localModelID") private var localModelID: String = ""

    @State private var messages: [ChatMessage] = []
    /// The job description being tailored for — an attachment or a long
    /// paste. Short messages are instructions, never the JD.
    @State private var jobDescription: (text: String, source: String)?
    /// Short notes typed since the JD arrived ("focus on ML"), sent as style guidance.
    @State private var instructions: [String] = []
    /// Asked to generate before picking a template — resume once one is picked.
    @State private var generateAfterTemplatePick = false
    @State private var draft: String = ""
    @State private var isTemplateChooserPresented = false
    @State private var isFileImporterPresented = false
    @State private var isDropTargeted = false
    @FocusState private var isComposerFocused: Bool

    private static let allowedAttachmentTypes: [UTType] = [.pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if messages.isEmpty {
                            emptyState
                        }
                        ForEach(messages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) {
                    guard let last = messages.last else { return }
                    withAnimation(appSpring) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            composer
        }
        .background(alignment: .top) {
            BrandGradient.wash.frame(height: 320).ignoresSafeArea()
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        Label("Drop a job description", systemImage: "arrow.down.doc")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding()
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in attach(url: url) }
            }
            return true
        }
        #if DEBUG
        // Screenshot hook: `-ClutchAttach /path/jd.pdf -ClutchSay "make me a resume"`.
        .task {
            let defaults = UserDefaults.standard
            if let path = defaults.string(forKey: "ClutchAttach") { attach(url: URL(fileURLWithPath: path)) }
            if let say = defaults.string(forKey: "ClutchSay") { draft = say; send() }
        }
        #endif
        .navigationTitle("Resume Builder")
        .navigationSubtitle(selectedTemplate.map { "Template: \($0.name)" } ?? "No template selected")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    isTemplateChooserPresented = true
                } label: {
                    Label(selectedTemplate?.name ?? "Choose Template", systemImage: "square.grid.2x2")
                }
                .help("Choose the LaTeX template to fill")

                if session.hasContent {
                    Button {
                        withAnimation(appSpring) { session.isPresented.toggle() }
                    } label: {
                        Label("Context Retrieval", systemImage: "sidebar.right")
                    }
                    .help("Show or hide the retrieval panel")
                }

                Button(action: generate) {
                    Label("Generate", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isRunning || jobDescription == nil)
                .help(generateHelp)
            }
        }
        .sheet(isPresented: $isTemplateChooserPresented, onDismiss: {
            if generateAfterTemplatePick, selectedTemplate != nil { generate() }
            generateAfterTemplatePick = false
        }) {
            TemplateChooserView(selectedTemplate: $selectedTemplate)
        }
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: Self.allowedAttachmentTypes) { result in
            switch result {
            case .success(let url):
                attach(url: url)
            case .failure(let error):
                post(ChatMessage(role: .assistant, text: "Couldn't attach file: \(error.localizedDescription)", isError: true))
            }
        }
    }

    private var engineLabel: String {
        if inferenceMode == .cloud { return "Gemini (Cloud)" }
        let ready = LocalModelStore.shared.readyModels
        return "Local · " + ((ready.first { $0.id == localModelID } ?? ready.first)?.name ?? "no model downloaded")
    }

    private var generateHelp: String {
        if jobDescription == nil { return "Add a job description first" }
        return "Generate with \(engineLabel)"
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 22) {
            Image(systemName: "wand.and.stars")
                .font(.largeTitle)
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(BrandGradient.fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .accentColor.opacity(0.35), radius: 14, y: 8)
                .symbolEffect(.pulse, options: .repeating.speed(0.4))

            VStack(spacing: 6) {
                Text("Tailor a resume in three steps")
                    .font(.title.weight(.semibold))
                Text("Clutch only uses experience it can find in your own history. Nothing is invented.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                StepCard(
                    number: 1,
                    title: selectedTemplate?.name ?? "Pick a template",
                    subtitle: selectedTemplate == nil ? "Choose one of the LaTeX designs" : "Template selected",
                    icon: "square.grid.2x2",
                    isDone: selectedTemplate != nil
                ) { isTemplateChooserPresented = true }
                StepCard(
                    number: 2,
                    title: "Add the job description",
                    subtitle: "Paste it below, attach a PDF, or drop a file here",
                    icon: "doc.on.clipboard",
                    isDone: jobDescription != nil
                ) { isComposerFocused = true }
                StepCard(
                    number: 3,
                    title: "Generate",
                    subtitle: "Say “make my resume” or press Generate · \(engineLabel)",
                    icon: "sparkles",
                    isDone: false
                ) { generate() }
            }
            .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                isFileImporterPresented = true
            } label: {
                Image(systemName: "paperclip")
                    .font(.title3)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("Attach a job description (.pdf, .txt, .md)")

            TextField("Paste a job description or ask Clutch…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($isComposerFocused)
                .onSubmit(send)
                .padding(.vertical, 6)

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.body.bold())
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(
                        trimmedDraft.isEmpty ? AnyShapeStyle(Color.secondary.opacity(0.35)) : AnyShapeStyle(BrandGradient.fill),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(trimmedDraft.isEmpty)
            .help("Send (↩)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isComposerFocused ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .padding()
        .animation(appSpring, value: isComposerFocused)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Actions

    private func post(_ message: ChatMessage) {
        withAnimation(appSpring) { messages.append(message) }
    }

    private func acknowledgeJobDescription() {
        guard let jobDescription else { return }
        let words = jobDescription.text.split { $0.isWhitespace || $0.isNewline }.count
        let what = jobDescription.source == "pasted" ? "that job description" : jobDescription.source
        let next = selectedTemplate == nil
            ? "Pick a template, then say “make my resume”."
            : "Say “make my resume” when you're ready — or add notes first, like “focus on my ML projects”."
        post(ChatMessage(role: .assistant, text: "Got \(what) (\(words) words). \(next)"))
    }

    private func send() {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        draft = ""
        post(ChatMessage(role: .user, text: text))

        let wordCount = text.split { $0.isWhitespace || $0.isNewline }.count
        if wordCount >= 40 {
            jobDescription = (text, "pasted")
            instructions = []
            acknowledgeJobDescription()
        } else if ChatIntent.isGenerateRequest(text) {
            instructions.append(text)
            generate()
        } else if jobDescription == nil {
            post(ChatMessage(role: .assistant, text: "Paste the job description (or attach it with the paperclip) and I'll tailor your resume to it."))
        } else {
            instructions.append(text)
            post(ChatMessage(role: .assistant, text: "Noted — I'll keep that in mind. Say “make my resume” when you're ready."))
        }
    }

    private func attach(url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let isPDF = url.pathExtension.lowercased() == "pdf"
        let document = isPDF ? PDFDocument(url: url) : nil
        let text = isPDF ? document?.string : try? String(contentsOf: url, encoding: .utf8)
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            post(ChatMessage(role: .assistant, text: "Couldn't read any text from \(url.lastPathComponent).", isError: true))
            return
        }
        let attachment = ChatMessage.Attachment(
            name: url.lastPathComponent,
            url: url,
            pageCount: document?.pageCount,
            wordCount: text.split { $0.isWhitespace || $0.isNewline }.count
        )
        post(ChatMessage(role: .user, text: text, attachment: attachment))
        jobDescription = (text, url.lastPathComponent)
        instructions = []
        acknowledgeJobDescription()
    }

    private func generate() {
        guard let jobDescription = jobDescription?.text else {
            post(ChatMessage(role: .assistant, text: "I need the job description first — paste it here or attach the PDF, and I'll start right away."))
            isComposerFocused = true
            return
        }
        guard let template = selectedTemplate else {
            post(ChatMessage(role: .assistant, text: "Pick a template and I'll start straight away."))
            generateAfterTemplatePick = true
            isTemplateChooserPresented = true
            return
        }
        guard !session.isRunning else { return }
        post(ChatMessage(role: .assistant, text: "On it — tailoring your \(template.name) resume with \(engineLabel)…"))

        session.begin(engine: engineLabel, template: template.name)
        Task {
            do {
                let retrieval = try await NetworkManager.shared.retrieveContext(jobDescription: jobDescription)
                session.retrieved(retrieval)
                if inferenceMode == .local { session.trackLocalProgress() }

                let response = try await NetworkManager.shared.generateResume(
                    jobDescription: jobDescription,
                    templateID: template.slug,
                    inferenceMode: inferenceMode,
                    geminiAPIKey: secrets.geminiAPIKey,
                    localModelID: localModelID,
                    instructions: instructions.joined(separator: "\n")
                )
                guard let texSource = response.texSource else {
                    throw NetworkError.serverError("Generation succeeded but no LaTeX source was returned.")
                }
                session.finish()
                post(ChatMessage(role: .assistant, text: "Done — your \(template.name) resume is open in the editor. Compile it to preview the PDF."))
                onGenerate(texSource)
            } catch {
                session.fail(error.localizedDescription)
                post(ChatMessage(role: .assistant, text: error.localizedDescription, isError: true))
            }
        }
    }
}

private struct StepCard: View {
    let number: Int
    let title: String
    let subtitle: String
    let icon: String
    let isDone: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isDone ? AnyShapeStyle(BrandGradient.fill) : AnyShapeStyle(.quaternary))
                        .frame(width: 34, height: 34)
                    if isDone {
                        Image(systemName: "checkmark").font(.callout.bold()).foregroundStyle(.white)
                    } else {
                        Text("\(number)").font(.callout.bold()).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: icon)
                    .foregroundStyle(isHovering ? Color.accentColor : .secondary)
            }
            .padding(12)
            .glassCard()
            .scaleEffect(isHovering ? 1.015 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(appSpring) { isHovering = hovering } }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    @State private var isExpanded = false

    private var isUser: Bool { message.role == .user }
    /// Pasted JDs are long — collapse them so the conversation stays readable.
    private var isLong: Bool { message.text.count > 600 }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 60) } else { avatar }

            if let attachment = message.attachment {
                AttachmentChip(attachment: attachment)
            } else {
                textBubble
            }

            if !isUser { Spacer(minLength: 60) }
        }
    }

    private var textBubble: some View {
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                Text(message.text)
                    .lineLimit(isLong && !isExpanded ? 8 : nil)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(isUser ? AnyShapeStyle(.white) : AnyShapeStyle(message.isError ? .red : .primary))
                    .background {
                        if isUser {
                            UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16, style: .continuous)
                                .fill(BrandGradient.fill)
                        } else {
                            UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 16, bottomTrailingRadius: 16, topTrailingRadius: 16, style: .continuous)
                                .fill(.regularMaterial)
                        }
                    }
                    .shadow(color: .black.opacity(0.06), radius: 4, y: 2)

                if isLong {
                    Button(isExpanded ? "Show less" : "Show full job description") {
                        withAnimation(appSpring) { isExpanded.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
    }

    private var avatar: some View {
        Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "sparkles")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(message.isError ? AnyShapeStyle(Color.red) : AnyShapeStyle(BrandGradient.fill), in: Circle())
    }
}

/// A shared file, shown compactly like Messages does — the parsed text stays
/// behind the scenes. Click to open the original.
private struct AttachmentChip: View {
    let attachment: ChatMessage.Attachment
    @State private var isHovering = false

    private var isPDF: Bool { attachment.url.pathExtension.lowercased() == "pdf" }

    var body: some View {
        Button {
            NSWorkspace.shared.open(attachment.url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isPDF ? "doc.richtext.fill" : "doc.text.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 48)
                    .background(isPDF ? AnyShapeStyle(Color.red.gradient) : AnyShapeStyle(BrandGradient.fill),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(attachment.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.secondary)
                    .opacity(isHovering ? 1 : 0)
            }
            .padding(10)
            .frame(maxWidth: 340, alignment: .leading)
            .glassCard(cornerRadius: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(appSpring) { isHovering = hovering } }
        .help("Open \(attachment.name)")
    }

    private var details: String {
        var parts = [isPDF ? "PDF" : attachment.url.pathExtension.uppercased()]
        if let pages = attachment.pageCount { parts.append(pages == 1 ? "1 page" : "\(pages) pages") }
        parts.append("\(attachment.wordCount) words")
        return parts.joined(separator: " · ")
    }
}

#Preview {
    ResumeBuilderChatView(selectedTemplate: .constant(nil), session: RetrievalSession(), onGenerate: { _ in })
}
