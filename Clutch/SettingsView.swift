import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let library: ResumeLibrary

    @AppStorage("autoSaveEnabled") private var autoSaveEnabled = true
    @AppStorage("compilerNotificationsEnabled") private var compilerNotificationsEnabled = true
    @State private var backend = BackendController.shared

    var body: some View {
        Form {
            Section {
                PageHeader(
                    icon: "gearshape.2",
                    title: "Settings",
                    subtitle: "Your career data, editor behavior, and the local backend."
                )
            }

            CareerDocumentsSection()

            GraphSection()

            Section("Editor") {
                Toggle("Auto-save resume drafts", isOn: $autoSaveEnabled)
                Toggle("Notify when a PDF finishes compiling in the background", isOn: $compilerNotificationsEnabled)
            }

            Section {
                LabeledContent("Resumes", value: "\(library.files.count) files")
                Button("Show in Finder", systemImage: "folder") { library.revealInFinder() }
            } header: {
                Text("Resume Library")
            } footer: {
                Text(ResumeLibrary.directory.path).textSelection(.enabled)
            }

            Section("Backend") {
                LabeledContent("Status") { backendStatus }
                LabeledContent("Location") {
                    Text(BackendController.backendDirectory.path)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Restart Check", systemImage: "arrow.clockwise") { Task { await backend.start() } }
                    Button("Open Log", systemImage: "doc.text.magnifyingglass") {
                        NSWorkspace.shared.open(BackendController.logURL)
                    }
                    .disabled(!FileManager.default.fileExists(atPath: BackendController.logURL.path))
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(.regularMaterial)
        .navigationTitle("Settings")
    }

    @ViewBuilder
    private var backendStatus: some View {
        switch backend.status {
        case .online:
            Label("Online", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .checking, .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting…")
            }
        case .offline(let reason):
            Label(reason, systemImage: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

/// The knowledge graph lives in a small database file next to the library
/// and is built from the documents themselves — nothing to set up.
private struct GraphSection: View {
    @State private var isRebuilding = false
    @State private var rebuildMessage: String?

    var body: some View {
        Section {
            HStack {
                if let rebuildMessage {
                    Text(rebuildMessage).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: rebuild) {
                    if isRebuilding {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Rebuild from Documents", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isRebuilding)
                .help("Recreate the graph from every document in your library")
            }
        } header: {
            Text("Knowledge Graph")
        } footer: {
            Text("Built automatically from your documents: projects, the skills they used, and where you worked. Stored on this Mac.")
        }
    }

    private func rebuild() {
        isRebuilding = true
        Task {
            defer { isRebuilding = false }
            do {
                let graph = try await NetworkManager.shared.rebuildGraph()
                rebuildMessage = "Rebuilt: \(graph.nodes.count) entities, \(graph.edges.count) connections."
            } catch {
                rebuildMessage = error.localizedDescription
            }
        }
    }
}

/// The career library: every document the RAG pipeline retrieves from.
/// Several files can be ingested at once, either added to what's there or
/// replacing it. Graph entities are merged across documents server-side,
/// so a skill mentioned in two files is one node.
private struct CareerDocumentsSection: View {
    @State private var secrets = Secrets.shared
    @AppStorage("inferenceMode") private var inferenceMode: InferenceMode = .cloud
    @AppStorage("localModelID") private var localModelID: String = ""

    /// nil until the backend has answered — never shown as "empty" before then.
    @State private var documents: [CareerDocument]?
    @State private var backend = BackendController.shared
    @State private var pending: [URL] = []
    @State private var isFileImporterPresented = false
    @State private var isDropTargeted = false
    @State private var isIngesting = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isConfirmingReplace = false
    @State private var pendingRemoval: CareerDocument?

    private static let allowedTypes: [UTType] = [.pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText]

    var body: some View {
        Section {
            if documents == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(backend.status == .online ? "Loading your library…" : "Waiting for the backend…")
                        .foregroundStyle(.secondary)
                }
            } else if documents?.isEmpty == true {
                Label("No documents yet — add your resume, brag document, or project notes.", systemImage: "tray")
                    .foregroundStyle(.secondary)
            }
            ForEach(documents ?? []) { document in
                DocumentRow(document: document) { pendingRemoval = document }
            }

            dropZone

            if !pending.isEmpty {
                pendingList
                actions
            }

            if isIngesting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Ingesting \(pending.count) \(pending.count == 1 ? "document" : "documents")… graph extraction can take a minute per file.")
                        .foregroundStyle(.secondary)
                }
            }

            if let statusMessage {
                Label(statusMessage, systemImage: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(statusIsError ? .red : .green)
            }
        } header: {
            HStack {
                Text("Career Documents")
                Spacer()
                if let documents, !documents.isEmpty {
                    Text("\(documents.count) in library").foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Everything Clutch may use about you. Documents are chunked and embedded on this Mac; and your knowledge graph is built from them automatically. Adding a file with the same name replaces its older version.")
        }
        // Re-runs when the backend comes online, so a slow start never
        // leaves the library looking empty.
        .task(id: backend.status) {
            if backend.status == .online { await loadDocuments() }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: Self.allowedTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): queue(urls)
            case .failure(let error):
                statusIsError = true
                statusMessage = error.localizedDescription
            }
        }
        .confirmationDialog("Replace your whole library?", isPresented: $isConfirmingReplace, titleVisibility: .visible) {
            Button("Replace \(documents?.count ?? 0) with \(pending.count)", role: .destructive) { ingest(mode: .replace) }
        } message: {
            Text("Removes \((documents ?? []).map(\.name).joined(separator: ", ")) and their knowledge-graph entities, then ingests only the new files.")
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "document")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let document = pendingRemoval { remove(document) }
            }
        } message: {
            Text("Its chunks are deleted, and graph entities no other document mentions are removed.")
        }
    }

    private var dropZone: some View {
        Button {
            isFileImporterPresented = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.title)
                    .foregroundStyle(isDropTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(BrandGradient.fill))
                    .symbolEffect(.bounce, value: isDropTargeted)
                Text("Drop documents here — several at once is fine").font(.headline)
                Text("or click to choose files (.pdf, .txt, .md)").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isIngesting)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted.animation(appSpring)) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in queue([url]) }
                }
            }
            return !providers.isEmpty
        }
    }

    private var pendingList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ready to ingest").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(pending, id: \.self) { url in
                HStack {
                    Image(systemName: url.pathExtension.lowercased() == "pdf" ? "doc.richtext.fill" : "doc.text.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    if documents?.contains(where: { $0.name == url.lastPathComponent }) == true {
                        Text("replaces existing")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Remove", systemImage: "xmark.circle.fill") {
                        withAnimation(appSpring) { pending.removeAll { $0 == url } }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(isIngesting)
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            Button("Clear") { withAnimation(appSpring) { pending = [] } }
                .disabled(isIngesting)
            Spacer()
            if documents?.isEmpty == false {
                Button("Replace Library…", systemImage: "arrow.triangle.2.circlepath") { isConfirmingReplace = true }
                    .disabled(isIngesting)
                    .help("Remove everything in the library, then ingest only these files")
            }
            Button(documents?.isEmpty == false ? "Add to Library" : "Ingest", systemImage: "plus.circle.fill") { ingest(mode: .add) }
                .buttonStyle(.borderedProminent)
                .disabled(isIngesting)
                .help("Keep the current library and add these files")
        }
    }

    private func queue(_ urls: [URL]) {
        let allowed = Set(["pdf", "txt", "md"])
        withAnimation(appSpring) {
            for url in urls where allowed.contains(url.pathExtension.lowercased()) && !pending.contains(url) {
                pending.append(url)
            }
            statusMessage = nil
        }
    }

    private func loadDocuments() async {
        if let documents = try? await NetworkManager.shared.listDocuments() {
            withAnimation(appSpring) { self.documents = documents }
        }
    }

    private func ingest(mode: NetworkManager.IngestMode) {
        isIngesting = true
        statusMessage = nil
        Task {
            defer { isIngesting = false }
            do {
                let response = try await NetworkManager.shared.ingestDocuments(
                    fileURLs: pending,
                    mode: mode,
                    geminiAPIKey: secrets.geminiAPIKey,
                    inferenceMode: inferenceMode,
                    localModelID: localModelID
                )
                withAnimation(appSpring) {
                    statusIsError = false
                    statusMessage = response.message
                    pending = []
                }
            } catch {
                withAnimation(appSpring) {
                    statusIsError = true
                    statusMessage = error.localizedDescription
                }
            }
            await loadDocuments()
        }
    }

    private func remove(_ document: CareerDocument) {
        Task {
            do {
                let remaining = try await NetworkManager.shared.deleteDocument(id: document.id)
                withAnimation(appSpring) {
                    documents = remaining
                    statusIsError = false
                    statusMessage = "Removed \(document.name)."
                }
            } catch {
                statusIsError = true
                statusMessage = error.localizedDescription
            }
        }
    }
}

private struct DocumentRow: View {
    let document: CareerDocument
    let onRemove: () -> Void

    private static let order = ["profile", "experience", "project", "skill", "education", "achievement"]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: document.name.lowercased().hasSuffix(".pdf") ? "doc.richtext.fill" : "doc.text.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 34, height: 40)
                .background(BrandGradient.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(document.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if document.addedAt > 0 {
                Text(Date(timeIntervalSince1970: document.addedAt), format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Button("Remove", systemImage: "trash", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove from library")
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let parts = Self.order.compactMap { category -> String? in
            guard let count = document.categories[category], category != "profile" else { return nil }
            let noun = category == "experience" ? "experience" : category == "skill" ? "skill group" : category
            return "\(count) \(noun)\(count == 1 || noun == "experience" ? "" : "s")"
        }
        return (["\(document.chunkCount) chunks"] + parts).joined(separator: " · ")
    }
}

#Preview {
    SettingsView(library: ResumeLibrary())
}
