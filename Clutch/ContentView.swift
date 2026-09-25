import SwiftUI

/// What the sidebar has selected.
enum AppRoute: Hashable {
    case resumeBuilder
    case graphExplorer
    case engineSelector
    case settings
    case resume(LatexFile.ID)
}

/// Two columns (sidebar + content). Secondary panels — live context
/// retrieval, node details, the PDF preview — slide in from the right only
/// when they have something to show, so pages like Settings never carry an
/// empty "nothing to preview" pane.
struct ContentView: View {
    @State private var library = ResumeLibrary()
    @State private var selection: AppRoute? = .resumeBuilder
    @State private var selectedTemplate: ResumeTemplate?
    @State private var graphViewModel = GraphViewModel()
    @State private var retrieval = RetrievalSession()
    @State private var backend = BackendController.shared
    @State private var isPDFPreviewPresented = false
    @State private var pendingDelete: LatexFile.ID?

    @AppStorage("inferenceMode") private var inferenceMode: InferenceMode = .cloud
    @AppStorage("sidePanelWidth") private var sidePanelWidth: Double = 320

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            // A hand-rolled panel rather than .inspector: the system inspector
            // picks its own width and doesn't reliably offer a resize edge.
            HStack(spacing: 0) {
                detail
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                if let title = sidePanelTitle {
                    SidePanel(title: title, width: $sidePanelWidth, onClose: closeSidePanel) {
                        sidePanelContent
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(appSpring, value: sidePanelTitle)
        }
        .onChange(of: backend.status) { _, status in
            guard status == .online else { return }
            Task { await LocalModelStore.shared.refresh() }
            if case .graphExplorer = selection { Task { await graphViewModel.load() } }
        }
        .onChange(of: selection) { isPDFPreviewPresented = currentResume?.pdfURL != nil }
        #if DEBUG
        .task { applyDebugLaunchArguments() }
        #endif
    }

    #if DEBUG
    /// Screenshot/testing hook: `-ClutchRoute graph|engine|settings|resume`
    /// (plus `-ClutchDemoGraph YES`) opens straight to a screen.
    private func applyDebugLaunchArguments() {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "ClutchRoute") {
        case "graph": selection = .graphExplorer
        case "engine": selection = .engineSelector
        case "settings": selection = .settings
        case "resume": selection = library.files.first.map { .resume($0.id) }
        default: break
        }
        if defaults.bool(forKey: "ClutchDemoGraph") { graphViewModel.loadDemo() }
        if let node = defaults.string(forKey: "ClutchSelectNode") { graphViewModel.selectedNodeID = node }
        // `-ClutchRetrievalJD "..."`: real retrieval, panel held mid-generation.
        if let jd = defaults.string(forKey: "ClutchRetrievalJD") {
            retrieval.begin(engine: "Gemini (Cloud)", template: "Jake's Resume")
            Task {
                while backend.status != .online { try? await Task.sleep(for: .milliseconds(200)) }
                if let response = try? await NetworkManager.shared.retrieveContext(jobDescription: jd) {
                    retrieval.retrieved(response)
                }
            }
        }
    }
    #endif

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            mainSidebarList
            // A second one-row list sharing the same selection: Settings gets
            // the exact native sidebar highlight while living at the bottom.
            List(selection: $selection) {
                Label("Settings", systemImage: "gearshape")
                    .tag(AppRoute.settings)
            }
            .listStyle(.sidebar)
            .scrollDisabled(true)
            .frame(height: 38)
            statusFooter
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .confirmationDialog(
            "Move this resume to the Trash?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Move to Trash", role: .destructive) {
                guard let id = pendingDelete else { return }
                withAnimation(appSpring) {
                    if selection == .resume(id) { selection = .resumeBuilder }
                    library.delete(id)
                }
            }
        }
    }

    private var mainSidebarList: some View {
        List(selection: $selection) {
            Section("Workspace") {
                Label("Resume Builder", systemImage: "wand.and.stars")
                    .tag(AppRoute.resumeBuilder)
                Label("Knowledge Graph", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    .tag(AppRoute.graphExplorer)
                Label("Engine Selector", systemImage: "cpu")
                    .tag(AppRoute.engineSelector)
            }
            Section {
                if library.files.isEmpty {
                    Text("Resumes you generate appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(library.files) { file in
                    Label {
                        HStack {
                            Text(file.displayName).lineLimit(1)
                            if file.isDirty {
                                Circle().fill(.orange).frame(width: 6, height: 6)
                            }
                        }
                    } icon: {
                        Image(systemName: file.pdfURL == nil ? "doc.text" : "doc.richtext.fill")
                    }
                    .tag(AppRoute.resume(file.id))
                    .contextMenu { resumeMenu(for: file.id) }
                }
            } header: {
                HStack {
                    Text("Resumes")
                    Spacer()
                    Text("\(library.files.count)").monospacedDigit()
                        .padding(.trailing, 6)
                }
            }
        }
        .listStyle(.sidebar)
        // Room to scroll the last resume clear of the fade below.
        .contentMargins(.bottom, 36, for: .scrollContent)
        // Resumes blur into the bottom edge instead of being cut off as the
        // list grows. An overlay rather than a mask: masking a sidebar List
        // strips the vibrancy its icons are drawn with.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.ultraThinMaterial)
                // Eased ramp: barely-there at the top, soft at the edge.
                .mask(LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.25), location: 0.45),
                    .init(color: .black.opacity(0.7), location: 1),
                ], startPoint: .top, endPoint: .bottom))
                .frame(height: 28)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func resumeMenu(for id: LatexFile.ID) -> some View {
        Button("Duplicate", systemImage: "plus.square.on.square") {
            if let copy = library.duplicate(id) {
                withAnimation(appSpring) { selection = .resume(copy) }
            }
        }
        Button("Show in Finder", systemImage: "folder") { library.revealInFinder(id) }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) { pendingDelete = id }
    }

    /// Backend + engine health at a glance, pinned under the sidebar list.
    private var statusFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.6), radius: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusText).font(.caption.weight(.medium))
                Text(engineDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if case .offline = backend.status {
                Button("Retry", systemImage: "arrow.clockwise") { Task { await backend.start() } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Start the backend again")
            }
        }
        .padding(10)
        .glassCard(cornerRadius: 10)
        .padding([.horizontal, .bottom], 10)
        .padding(.top, 4)
        .help(statusHelp)
    }

    private var statusColor: Color {
        switch backend.status {
        case .online: .green
        case .checking, .starting: .yellow
        case .offline: .red
        }
    }

    /// What actually writes the resume — the services above run in both modes.
    private var engineDescription: String {
        guard inferenceMode == .local else { return "Engine: Gemini (Cloud)" }
        let ready = LocalModelStore.shared.readyModels
        let active = ready.first { $0.id == UserDefaults.standard.string(forKey: "localModelID") } ?? ready.first
        return "Engine: \(active?.name ?? "Local model (none downloaded)")"
    }

    private var statusText: String {
        switch backend.status {
        case .online: "Local services running"
        case .checking: "Checking local services…"
        case .starting: "Starting local services…"
        case .offline: "Local services offline"
        }
    }

    private var statusHelp: String {
        if case .offline(let reason) = backend.status { return reason }
        return "Retrieval, PDF compiling and on-device models run here (localhost:\(NetworkManager.shared.port)). Needed in Cloud and Local mode."
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .resumeBuilder:
            ResumeBuilderChatView(selectedTemplate: $selectedTemplate, session: retrieval, onGenerate: appendGeneratedResume)
        case .graphExplorer:
            GraphExplorerView(viewModel: graphViewModel)
        case .engineSelector:
            EngineSelectorView()
        case .settings:
            SettingsView(library: library)
        case .resume(let id):
            if let index = library.index(of: id) {
                LatexEditorView(
                    file: $library.files[index],
                    onSave: { library.save(id) },
                    onCompile: { withAnimation(appSpring) { isPDFPreviewPresented = true } }
                )
                .id(id) // fresh editor (and undo stack) per file
                .toolbar {
                    ToolbarItem {
                        Button("PDF Preview", systemImage: "sidebar.right") {
                            withAnimation(appSpring) { isPDFPreviewPresented.toggle() }
                        }
                        .disabled(library.files[index].pdfURL == nil)
                        .help("Show or hide the PDF preview")
                    }
                }
            } else {
                ContentUnavailableView("Resume Not Found", systemImage: "questionmark.folder")
            }
        case nil:
            ContentUnavailableView(
                "No Selection",
                systemImage: "sidebar.left",
                description: Text("Choose an item from the sidebar to get started.")
            )
        }
    }

    // MARK: - Side panel

    private var currentResume: LatexFile? {
        guard case .resume(let id) = selection else { return nil }
        return library.files.first { $0.id == id }
    }

    /// The panel's title when it should be showing for this route, else nil.
    private var sidePanelTitle: String? {
        switch selection {
        case .resumeBuilder: retrieval.isPresented && retrieval.hasContent ? "Context Retrieval" : nil
        case .graphExplorer: graphViewModel.selectedNodeID != nil ? "Node Details" : nil
        case .resume: isPDFPreviewPresented && currentResume?.pdfURL != nil ? "PDF Preview" : nil
        default: nil
        }
    }

    private func closeSidePanel() {
        withAnimation(appSpring) {
            switch selection {
            case .resumeBuilder: retrieval.isPresented = false
            case .graphExplorer: graphViewModel.selectedNodeID = nil
            case .resume: isPDFPreviewPresented = false
            default: break
            }
        }
    }

    @ViewBuilder
    private var sidePanelContent: some View {
        switch selection {
        case .resumeBuilder:
            RAGVisualizerView(session: retrieval)
        case .graphExplorer:
            GraphInspectorDetailView(viewModel: graphViewModel)
        case .resume:
            if let file = currentResume {
                PDFPreviewView(fileName: file.name, pdfURL: file.pdfURL)
            }
        default:
            EmptyView()
        }
    }

    private func appendGeneratedResume(texSource: String) {
        guard let template = selectedTemplate else { return }
        let stamp = Date.now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
        let id = library.add(baseName: "Tailored_\(template.slug)_\(stamp)", source: texSource)
        withAnimation(appSpring) {
            selection = .resume(id)
        }
    }
}

/// Right-hand panel with a draggable leading edge. Width is clamped and
/// persisted by the caller.
private struct SidePanel<Content: View>: View {
    let title: String
    @Binding var width: Double
    let onClose: () -> Void
    @ViewBuilder let content: Content

    @State private var dragStartWidth: Double?
    @State private var isHoveringEdge = false

    private static var widthRange: ClosedRange<Double> { 260...700 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Close", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Close panel (Esc)")
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width.clamped(to: Self.widthRange))
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .leading) { resizeEdge }
    }

    private var resizeEdge: some View {
        Rectangle()
            .fill(isHoveringEdge || dragStartWidth != nil ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(width: isHoveringEdge || dragStartWidth != nil ? 2 : 1)
            .frame(width: 9) // generous grab area around the hairline
            .contentShape(Rectangle())
            .onHover { hovering in
                isHoveringEdge = hovering
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? width.clamped(to: Self.widthRange)
                        dragStartWidth = start
                        width = (start - value.translation.width).clamped(to: Self.widthRange)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .offset(x: -4)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

#Preview {
    ContentView()
}
