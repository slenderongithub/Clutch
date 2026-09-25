import AppKit
import SwiftUI

/// Shared between GraphExplorerView (canvas) and GraphInspectorDetailView
/// (inspector) — owned by ContentView so both see the same selection.
@Observable
@MainActor
final class GraphViewModel {
    static let labelFontSize: CGFloat = 11
    static let nodeTypes = ["Skill", "Project", "Company"]

    private(set) var response: GraphResponse?
    private(set) var isLoading = false
    private(set) var loadErrorMessage: String?
    private(set) var isDemo = false
    private(set) var positions: [String: CGPoint] = [:]
    private(set) var degree: [String: Int] = [:]
    private(set) var labelSizes: [String: CGSize] = [:]
    /// Bumped whenever a new layout lands, so the canvas refits.
    private(set) var layoutVersion = 0
    /// Set to ask the canvas to pan a node into the center.
    private(set) var focusRequest: (id: String, token: Int)?

    var selectedNodeID: String?
    var hoveredNodeID: String?
    var hiddenTypes: Set<String> = []

    var visibleNodes: [GraphNode] {
        response?.nodes.filter { !hiddenTypes.contains($0.type) } ?? []
    }

    var hasGraph: Bool { !(response?.nodes.isEmpty ?? true) }

    func load() async {
        isLoading = true
        loadErrorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await NetworkManager.shared.fetchGraph()
            // Don't swap a sample graph the user is exploring for an empty state.
            if isDemo && response.nodes.isEmpty { return }
            isDemo = false
            apply(response)
        } catch {
            if !isDemo { loadErrorMessage = error.localizedDescription }
        }
    }

    func loadDemo() {
        isDemo = true
        loadErrorMessage = nil
        apply(DemoGraph.response)
    }

    func radius(for id: String) -> CGFloat {
        7 + min(CGFloat(degree[id] ?? 0), 10) * 0.9
    }

    func neighbors(of id: String) -> Set<String> {
        guard let edges = response?.edges else { return [] }
        var result: Set<String> = []
        for edge in edges {
            if edge.source == id { result.insert(edge.target) }
            if edge.target == id { result.insert(edge.source) }
        }
        return result
    }

    func node(_ id: String) -> GraphNode? {
        response?.nodes.first { $0.id == id }
    }

    // MARK: - Live physics (Obsidian-style)
    //
    // Springs along connections, repulsion between all nodes, weak pull to
    // the centre and box collision on each node's dot + label footprint.
    // Runs only while there's energy ("alpha", as in d3-force): after a
    // load, and while a node is being dragged — then it cools and stops.

    private var velocities: [String: CGVector] = [:]
    private var footprints: [String: CGSize] = [:]
    private var pinned: Set<String> = []
    private var alpha: CGFloat = 0
    private var alphaTarget: CGFloat = 0
    private var simulation: Task<Void, Never>?
    /// Bumped each time the simulation comes to rest (the view refits).
    private(set) var settleVersion = 0

    /// Grabs a node: it follows the cursor, and its connections are pulled
    /// along elastically.
    func beginDrag(_ id: String) {
        pinned.insert(id)
        alphaTarget = 0.3
        reheat(0.3)
    }

    func drag(_ id: String, to point: CGPoint) {
        positions[id] = point
        velocities[id] = .zero
    }

    func endDrag(_ id: String) {
        pinned.remove(id)
        alphaTarget = 0
    }

    private func reheat(_ energy: CGFloat) {
        alpha = max(alpha, energy)
        guard simulation == nil else { return }
        simulation = Task { [weak self] in
            while let self, !Task.isCancelled, self.alpha > 0.003 || self.alphaTarget > 0 {
                self.tick()
                try? await Task.sleep(for: .milliseconds(16))
            }
            self?.simulation = nil
            self?.settleVersion += 1
        }
    }

    private func tick() {
        guard let response else { return }
        let ids = visibleNodes.map(\.id).filter { positions[$0] != nil }
        var force: [String: CGVector] = [:]
        func push(_ id: String, _ dx: CGFloat, _ dy: CGFloat) {
            force[id, default: .zero].dx += dx
            force[id, default: .zero].dy += dy
        }

        // Springs: connected nodes settle at a comfortable distance.
        let visible = Set(ids)
        for edge in response.edges where visible.contains(edge.source) && visible.contains(edge.target) {
            guard let a = positions[edge.source], let b = positions[edge.target] else { continue }
            let dx = b.x - a.x, dy = b.y - a.y
            let distance = max(hypot(dx, dy), 1)
            let rest: CGFloat = 70 + ((footprints[edge.source]?.width ?? 60) + (footprints[edge.target]?.width ?? 60)) / 4
            let strength = (distance - rest) / distance * 0.12 * alpha
            push(edge.source, dx * strength, dy * strength)
            push(edge.target, -dx * strength, -dy * strength)
        }
        // Repulsion between every pair, plus hard box collision.
        // ponytail: O(n²) per frame — fine for a career graph's tens of
        // nodes; add a quadtree (Barnes–Hut) if it ever needs hundreds.
        for i in ids.indices {
            for j in (i + 1)..<ids.count {
                let a = ids[i], b = ids[j]
                guard let pa = positions[a], let pb = positions[b] else { continue }
                var dx = pb.x - pa.x, dy = pb.y - pa.y
                if dx == 0 && dy == 0 { dx = 0.5; dy = 0.5 }
                let d2 = max(dx * dx + dy * dy, 25)
                let repel = -2600 * alpha / d2
                push(a, dx * repel, dy * repel)
                push(b, -dx * repel, -dy * repel)

                let sa = footprints[a] ?? CGSize(width: 60, height: 40)
                let sb = footprints[b] ?? CGSize(width: 60, height: 40)
                let overlapX = (sa.width + sb.width) / 2 + 6 - abs(dx)
                let overlapY = (sa.height + sb.height) / 2 + 6 - abs(dy)
                if overlapX > 0 && overlapY > 0 {
                    if overlapX < overlapY {
                        let shove = overlapX * 0.5 * (dx < 0 ? 1 : -1)
                        push(a, shove, 0); push(b, -shove, 0)
                    } else {
                        let shove = overlapY * 0.5 * (dy < 0 ? 1 : -1)
                        push(a, 0, shove); push(b, 0, -shove)
                    }
                }
            }
        }
        // Integrate with friction; pinned (dragged) nodes stay under the cursor.
        for id in ids where !pinned.contains(id) {
            guard var point = positions[id] else { continue }
            var velocity = velocities[id] ?? .zero
            let f = force[id] ?? .zero
            // Unconnected nodes get a stronger pull, or repulsion alone
            // would drift them to the far edges (Obsidian keeps orphans near).
            let gravity: CGFloat = (degree[id] ?? 0) == 0 ? 0.06 : 0.02
            velocity.dx = (velocity.dx + f.dx - point.x * gravity * alpha) * 0.6
            velocity.dy = (velocity.dy + f.dy - point.y * gravity * alpha) * 0.6
            point.x += velocity.dx
            point.y += velocity.dy
            positions[id] = point
            velocities[id] = velocity
        }
        alpha += (alphaTarget - alpha) * 0.03
    }

    func focus(on id: String) {
        selectedNodeID = id
        focusRequest = (id, (focusRequest?.token ?? 0) + 1)
    }

    private func apply(_ response: GraphResponse) {
        self.response = response
        selectedNodeID = nil
        hoveredNodeID = nil

        var degree: [String: Int] = [:]
        for edge in response.edges {
            degree[edge.source, default: 0] += 1
            degree[edge.target, default: 0] += 1
        }
        self.degree = degree

        let font = NSFont.systemFont(ofSize: Self.labelFontSize, weight: .medium)
        labelSizes = Dictionary(uniqueKeysWithValues: response.nodes.map { node in
            let size = (node.label as NSString).size(withAttributes: [.font: font])
            return (node.id, CGSize(width: ceil(size.width) + 12, height: ceil(size.height) + 4))
        })

        // Footprint = dot + gap + label pill below it, as a box centered on
        // the node (height doubled so the box stays symmetric around it).
        let footprints = Dictionary(uniqueKeysWithValues: response.nodes.map { node in
            let r = radius(for: node.id)
            let label = labelSizes[node.id] ?? .zero
            return (node.id, CGSize(width: max(label.width, r * 2) + 6, height: (r + 4 + label.height) * 2))
        })
        self.footprints = footprints
        velocities = [:]
        positions = ForceDirectedLayout.computePositions(nodes: response.nodes, edges: response.edges, footprints: footprints)
        layoutVersion += 1
        reheat(0.5)  // settle into the live physics with a gentle animation
    }
}

func graphColor(for type: String) -> Color {
    switch type {
    case "Skill": .blue
    case "Project": .green
    case "Company": .orange
    default: .gray
    }
}

func graphIcon(for type: String) -> String {
    switch type {
    case "Skill": "wrench.and.screwdriver.fill"
    case "Project": "hammer.fill"
    case "Company": "building.2.fill"
    default: "circle.fill"
    }
}

struct GraphExplorerView: View {
    @Bindable var viewModel: GraphViewModel

    // Live vs. committed transform: gestures update the live value and
    // write back on release so pan and zoom compose from the last rest.
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var gestureStartScale: CGFloat?
    @State private var gestureStartOffset: CGSize?
    /// The node being dragged and where it started (world units).
    @State private var draggedNode: (id: String, origin: CGPoint)?
    @State private var viewportSize: CGSize = .zero
    /// Until the user pans/zooms, the view keeps refitting as the window settles.
    @State private var userMovedView = false
    @State private var searchText = ""

    private let minScale: CGFloat = 0.15
    private let maxScale: CGFloat = 4

    var body: some View {
        Group {
            if viewModel.isLoading && !viewModel.hasGraph {
                ProgressView("Loading knowledge graph…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.hasGraph {
                graphCanvas
            } else if let loadErrorMessage = viewModel.loadErrorMessage {
                unavailable(
                    title: "Couldn't Reach Clutch Backend",
                    icon: "wifi.slash",
                    message: loadErrorMessage
                )
            } else if let response = viewModel.response, !response.available {
                unavailable(
                    title: "Knowledge Graph Offline",
                    icon: "point.3.connected.trianglepath.dotted",
                    message: (response.reason ?? "Neo4j isn't reachable.")
                        + " Check the connection in Settings → Knowledge Graph, then ingest your Master Brag Document."
                )
            } else {
                unavailable(
                    title: "No Graph Data Yet",
                    icon: "sparkles",
                    message: "Ingest a Master Brag Document in Settings to extract your skills, projects, and companies."
                )
            }
        }
        .navigationTitle("Knowledge Graph")
        .navigationSubtitle(subtitle)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Find a node")
        .searchSuggestions {
            ForEach(searchMatches.prefix(8)) { node in
                Label(node.label, systemImage: graphIcon(for: node.type))
                    .searchCompletion(node.label)
            }
        }
        .onSubmit(of: .search) {
            if let match = searchMatches.first { viewModel.focus(on: match.id) }
        }
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await viewModel.load() }
                }
                .disabled(viewModel.isLoading)
                .help("Reload the graph from Neo4j")
            }
        }
        .task {
            if viewModel.response == nil { await viewModel.load() }
        }
    }

    private var subtitle: String {
        guard let response = viewModel.response, viewModel.hasGraph else { return "" }
        return "\(response.nodes.count) nodes · \(response.edges.count) connections" + (viewModel.isDemo ? " · sample data" : "")
    }

    private var searchMatches: [GraphNode] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return viewModel.visibleNodes.filter { $0.label.localizedCaseInsensitiveContains(query) }
    }

    private func unavailable(title: String, icon: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await viewModel.load() } }
            Button("Explore a Sample Graph") {
                withAnimation(appSpring) { viewModel.loadDemo() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Canvas

    private var graphCanvas: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                drawGrid(in: context, size: size)
                drawEdges(in: context)
                drawNodes(in: context)
            }
            .contentShape(Rectangle())
            .gesture(dragOrTapGesture)
            .simultaneousGesture(magnifyGesture)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let hit = nodeHit(at: location)
                    if hit != viewModel.hoveredNodeID { viewModel.hoveredNodeID = hit }
                    if hit == nil {
                        NSCursor.arrow.set()
                    } else {
                        NSCursor.openHand.set()
                    }
                case .ended:
                    viewModel.hoveredNodeID = nil
                    NSCursor.arrow.set()
                }
            }
            .background(ScrollWheelCatcher(onScroll: handleScroll))
            .onAppear {
                viewportSize = geometry.size
                fitToView(animated: false)
            }
            .onChange(of: geometry.size) { _, newSize in
                viewportSize = newSize
                if !userMovedView { fitToView(animated: false) }
            }
            .onChange(of: viewModel.layoutVersion) {
                userMovedView = false
                fitToView(animated: true)
            }
            .onChange(of: viewModel.settleVersion) {
                if !userMovedView { fitToView(animated: true) }
            }
            .onChange(of: viewModel.focusRequest?.token) { center(on: viewModel.focusRequest?.id) }
        }
        .overlay(alignment: .topLeading) { legend.padding() }
        .overlay(alignment: .bottomTrailing) { zoomControls.padding() }
        .overlay(alignment: .bottomLeading) {
            if let id = viewModel.hoveredNodeID, id != viewModel.selectedNodeID, let node = viewModel.node(id) {
                hoverCard(node).padding().transition(.opacity)
            }
        }
        .animation(appSpring, value: viewModel.hoveredNodeID)
    }

    /// The node whose neighborhood is emphasized: selection wins over hover.
    private var focusID: String? {
        viewModel.selectedNodeID ?? viewModel.hoveredNodeID
    }

    private func drawGrid(in context: GraphicsContext, size: CGSize) {
        let spacing = 28 * scale
        guard spacing > 8 else { return }
        let startX = offset.width.truncatingRemainder(dividingBy: spacing)
        let startY = offset.height.truncatingRemainder(dividingBy: spacing)
        var dots = Path()
        var x = startX
        while x < size.width {
            var y = startY
            while y < size.height {
                dots.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                y += spacing
            }
            x += spacing
        }
        context.fill(dots, with: .color(.secondary.opacity(0.18)))
    }

    private func drawEdges(in context: GraphicsContext) {
        guard let response = viewModel.response else { return }
        let focus = focusID
        for edge in response.edges {
            guard isVisible(edge.source), isVisible(edge.target),
                  let a = viewModel.positions[edge.source], let b = viewModel.positions[edge.target] else { continue }
            let touchesFocus = focus != nil && (edge.source == focus || edge.target == focus)
            let dimmed = focus != nil && !touchesFocus

            let start = screenPoint(for: a)
            let end = screenPoint(for: b)
            // Slight curve reads as "connection" rather than a ruler line and
            // separates edges that would otherwise run parallel.
            let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let normal = CGPoint(x: -(end.y - start.y) * 0.08, y: (end.x - start.x) * 0.08)
            var path = Path()
            path.move(to: start)
            path.addQuadCurve(to: end, control: CGPoint(x: mid.x + normal.x, y: mid.y + normal.y))

            context.stroke(
                path,
                with: .color(touchesFocus ? .accentColor : .secondary.opacity(dimmed ? 0.1 : 0.35)),
                lineWidth: touchesFocus ? 2 : 1
            )
        }
    }

    private func drawNodes(in context: GraphicsContext) {
        let focus = focusID
        let neighborhood = focus.map { viewModel.neighbors(of: $0).union([$0]) }
        let nodes = viewModel.visibleNodes.filter { viewModel.positions[$0.id] != nil }

        var dotRects: [String: CGRect] = [:]
        for node in nodes {
            let point = screenPoint(for: viewModel.positions[node.id]!)
            let isSelected = viewModel.selectedNodeID == node.id
            let isHovered = viewModel.hoveredNodeID == node.id
            let dimmed = neighborhood.map { !$0.contains(node.id) } ?? false
            let radius = viewModel.radius(for: node.id) * max(scale, 0.6) * (isHovered ? 1.15 : 1)
            let color = graphColor(for: node.type)
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            dotRects[node.id] = rect

            var nodeContext = context
            nodeContext.opacity = dimmed ? 0.25 : 1
            if isSelected || isHovered {
                nodeContext.fill(Path(ellipseIn: rect.insetBy(dx: -6, dy: -6)), with: .color(color.opacity(0.22)))
            }
            nodeContext.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [color.opacity(0.75), color]),
                    center: CGPoint(x: rect.midX - radius * 0.3, y: rect.midY - radius * 0.3),
                    startRadius: 0,
                    endRadius: radius * 1.4
                )
            )
            nodeContext.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.85)), lineWidth: 1.5)
            if isSelected {
                nodeContext.stroke(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)), with: .color(.accentColor), lineWidth: 2)
            }
        }

        // Greedy label placement: most important first; any label that would
        // collide with an already-placed label or another node is skipped.
        // Labels therefore never overlap, and zooming in reveals more.
        func priority(_ node: GraphNode) -> Int {
            if node.id == viewModel.selectedNodeID || node.id == viewModel.hoveredNodeID { return 10_000 }
            if neighborhood?.contains(node.id) == true { return 5_000 + (viewModel.degree[node.id] ?? 0) }
            return viewModel.degree[node.id] ?? 0
        }
        let fontSize = max(GraphViewModel.labelFontSize * min(scale, 1.6), 10)
        var placed: [CGRect] = []
        for node in nodes.sorted(by: { priority($0) > priority($1) }) {
            guard let dot = dotRects[node.id] else { continue }
            let dimmed = neighborhood.map { !$0.contains(node.id) } ?? false
            let label = context.resolve(Text(node.label).font(.system(size: fontSize, weight: .medium)).foregroundStyle(.primary))
            let textSize = label.measure(in: CGSize(width: 1000, height: 100))
            let pill = CGRect(
                x: dot.midX - textSize.width / 2 - 6,
                y: dot.maxY + 4,
                width: textSize.width + 12,
                height: textSize.height + 4
            )
            let isForced = priority(node) >= 10_000
            let isNeighbor = priority(node) >= 5_000
            if !isForced {
                if placed.contains(where: { $0.insetBy(dx: -2, dy: -1).intersects(pill) }) { continue }
                if !isNeighbor, dotRects.contains(where: { $0.key != node.id && $0.value.intersects(pill) }) { continue }
            }
            placed.append(pill)

            var labelContext = context
            labelContext.opacity = dimmed ? 0.3 : 1
            labelContext.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .style(.background.opacity(0.85)))
            labelContext.draw(label, at: CGPoint(x: pill.midX, y: pill.midY))
        }
    }

    private func isVisible(_ id: String) -> Bool {
        guard let node = viewModel.node(id) else { return false }
        return !viewModel.hiddenTypes.contains(node.type)
    }

    // MARK: - Overlays

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(GraphViewModel.nodeTypes, id: \.self) { type in
                let count = viewModel.response?.nodes.filter { $0.type == type }.count ?? 0
                let isHidden = viewModel.hiddenTypes.contains(type)
                Button {
                    withAnimation(appSpring) {
                        if isHidden { viewModel.hiddenTypes.remove(type) } else { viewModel.hiddenTypes.insert(type) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(isHidden ? Color.secondary.opacity(0.3) : graphColor(for: type))
                            .frame(width: 10, height: 10)
                        Text(type == "Company" ? "Companies" : "\(type)s")
                            .foregroundStyle(isHidden ? .secondary : .primary)
                            .strikethrough(isHidden)
                        Spacer(minLength: 12)
                        Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isHidden ? "Show \(type.lowercased()) nodes" : "Hide \(type.lowercased()) nodes")
            }
        }
        .font(.caption)
        .padding(10)
        .frame(width: 150)
        .glassCard(cornerRadius: 10)
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button("Zoom Out", systemImage: "minus") { zoom(by: 1 / 1.3, around: viewportCenter) }
                .keyboardShortcut("-", modifiers: .command)
            Text("\(Int(scale * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 44)
            Button("Zoom In", systemImage: "plus") { zoom(by: 1.3, around: viewportCenter) }
                .keyboardShortcut("=", modifiers: .command)
            Divider().frame(height: 16)
            Button("Fit", systemImage: "arrow.up.left.and.arrow.down.right") { fitToView(animated: true) }
                .keyboardShortcut("0", modifiers: .command)
                .help("Fit graph to window (⌘0)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassCard(cornerRadius: 10)
    }

    private func hoverCard(_ node: GraphNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: graphIcon(for: node.type)).foregroundStyle(graphColor(for: node.type))
            VStack(alignment: .leading, spacing: 1) {
                Text(node.label).font(.callout.weight(.semibold))
                Text("\(node.type) · \(viewModel.degree[node.id] ?? 0) connections · click to inspect · drag to move")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .glassCard(cornerRadius: 10)
    }

    // MARK: - Transform math (manual, so hit-testing and drawing share it)

    private var viewportCenter: CGPoint {
        CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
    }

    private func screenPoint(for world: CGPoint) -> CGPoint {
        CGPoint(x: world.x * scale + offset.width, y: world.y * scale + offset.height)
    }

    private func worldPoint(for screen: CGPoint) -> CGPoint {
        CGPoint(x: (screen.x - offset.width) / scale, y: (screen.y - offset.height) / scale)
    }

    /// Zooms keeping `anchor` (a screen point) fixed under the cursor.
    private func zoom(by factor: CGFloat, around anchor: CGPoint, from base: (scale: CGFloat, offset: CGSize)? = nil) {
        let baseScale = base?.scale ?? scale
        let baseOffset = base?.offset ?? offset
        let newScale = min(max(baseScale * factor, minScale), maxScale)
        let world = CGPoint(x: (anchor.x - baseOffset.width) / baseScale, y: (anchor.y - baseOffset.height) / baseScale)
        scale = newScale
        offset = CGSize(width: anchor.x - world.x * newScale, height: anchor.y - world.y * newScale)
    }

    private func fitToView(animated: Bool) {
        let points = viewModel.visibleNodes.compactMap { viewModel.positions[$0.id] }
        guard !points.isEmpty, viewportSize.width > 0, viewportSize.height > 0 else { return }
        // Margins in *screen* points (labels hang below dots and keep their
        // size when zoomed out); the left inset clears the legend card.
        let inset = (left: CGFloat(190), right: CGFloat(80), top: CGFloat(50), bottom: CGFloat(90))
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let usableWidth = max(viewportSize.width - inset.left - inset.right, 100)
        let usableHeight = max(viewportSize.height - inset.top - inset.bottom, 100)
        let fit = min(usableWidth / max(maxX - minX, 1), usableHeight / max(maxY - minY, 1))
        let newScale = min(max(fit, minScale), 1.4)
        let newOffset = CGSize(
            width: inset.left + usableWidth / 2 - (minX + maxX) / 2 * newScale,
            height: inset.top + usableHeight / 2 - (minY + maxY) / 2 * newScale
        )
        withAnimation(animated ? appSpring : nil) {
            scale = newScale
            offset = newOffset
        }
    }

    private func center(on id: String?) {
        guard let id, let world = viewModel.positions[id] else { return }
        if let node = viewModel.node(id) { viewModel.hiddenTypes.remove(node.type) }
        let newScale = max(scale, 1)
        withAnimation(appSpring) {
            scale = newScale
            offset = CGSize(width: viewportSize.width / 2 - world.x * newScale, height: viewportSize.height / 2 - world.y * newScale)
        }
    }

    // MARK: - Gestures

    /// One DragGesture(minimumDistance: 0) serves both pan and click: a
    /// near-zero movement on release is a click (node hit-test), otherwise a
    /// pan — avoids stacked tap/drag gesture conflicts.
    private var dragOrTapGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // First event decides the mode: grabbing a node moves it (its
                // connections follow through the physics); otherwise pan.
                if draggedNode == nil, gestureStartOffset == nil {
                    if let hit = nodeHit(at: value.startLocation), let origin = viewModel.positions[hit] {
                        draggedNode = (hit, origin)
                        viewModel.beginDrag(hit)
                        viewModel.hoveredNodeID = hit
                    } else {
                        gestureStartOffset = offset
                    }
                }
                guard hypot(value.translation.width, value.translation.height) > 3 else { return }
                NSCursor.closedHand.set()
                if let (id, origin) = draggedNode {
                    viewModel.drag(id, to: CGPoint(x: origin.x + value.translation.width / scale, y: origin.y + value.translation.height / scale))
                } else if let start = gestureStartOffset {
                    userMovedView = true
                    offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                }
            }
            .onEnded { value in
                gestureStartOffset = nil
                if let (id, _) = draggedNode {
                    viewModel.endDrag(id)
                    userMovedView = true  // don't refit away from what the user just arranged
                }
                draggedNode = nil
                NSCursor.arrow.set()
                guard hypot(value.translation.width, value.translation.height) <= 3 else { return }
                let hit = nodeHit(at: value.location)
                withAnimation(appSpring) {
                    viewModel.selectedNodeID = (hit == viewModel.selectedNodeID) ? nil : hit
                }
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = (gestureStartScale ?? scale, gestureStartOffset ?? offset)
                gestureStartScale = base.0
                gestureStartOffset = base.1
                userMovedView = true
                zoom(by: value.magnification, around: value.startLocation, from: (base.0, base.1))
            }
            .onEnded { _ in
                gestureStartScale = nil
                gestureStartOffset = nil
            }
    }

    private func handleScroll(_ event: NSEvent, at location: CGPoint) {
        userMovedView = true
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            // Trackpad two-finger scroll pans, like Maps.
            offset.width += event.scrollingDeltaX
            offset.height += event.scrollingDeltaY
        } else {
            // Mouse wheel (or ⌘ + scroll) zooms around the cursor.
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            zoom(by: exp(delta), around: location)
        }
    }

    /// Nearest visible node whose dot or label contains the point.
    private func nodeHit(at screen: CGPoint) -> String? {
        let world = worldPoint(for: screen)
        var best: (id: String, distance: CGFloat)?
        for node in viewModel.visibleNodes {
            guard let position = viewModel.positions[node.id] else { continue }
            let radius = viewModel.radius(for: node.id)
            let distance = hypot(position.x - world.x, position.y - world.y)
            let label = viewModel.labelSizes[node.id] ?? .zero
            let labelRect = CGRect(x: position.x - label.width / 2, y: position.y + radius + 4, width: label.width, height: label.height)
            let slop = 6 / scale // a few screen points of forgiveness
            guard distance <= radius + slop || labelRect.insetBy(dx: -2, dy: -2).contains(world) else { continue }
            if best == nil || distance < best!.distance { best = (node.id, distance) }
        }
        return best?.id
    }
}

/// Delivers scroll-wheel events over this view (SwiftUI on macOS 14 has no
/// scroll-wheel gesture). Uses a local event monitor so clicks and drags
/// still reach the SwiftUI canvas above.
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (NSEvent, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((NSEvent, CGPoint) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true } // top-left origin, like SwiftUI

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let location = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(location) else { return event }
                self.onScroll?(event, location)
                return nil
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}

// MARK: - Inspector

/// Inspector companion to GraphExplorerView — what the selected node
/// connects to, grouped by relationship. Clicking a connection jumps to it.
struct GraphInspectorDetailView: View {
    let viewModel: GraphViewModel

    var body: some View {
        if let id = viewModel.selectedNodeID, let node = viewModel.node(id) {
            NodeInspector(node: node, viewModel: viewModel)
        } else {
            ContentUnavailableView(
                "No Node Selected",
                systemImage: "cursorarrow.click.2",
                description: Text("Click a node in the graph to see how it connects to the rest of your career.")
            )
        }
    }
}

private struct NodeInspector: View {
    let node: GraphNode
    let viewModel: GraphViewModel

    private var connections: [(relationship: String, others: [GraphNode])] {
        guard let edges = viewModel.response?.edges else { return [] }
        var grouped: [String: [GraphNode]] = [:]
        for edge in edges {
            let otherID = edge.source == node.id ? edge.target : edge.target == node.id ? edge.source : nil
            if let otherID, let other = viewModel.node(otherID) {
                grouped[edge.relationship, default: []].append(other)
            }
        }
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted { $0.label < $1.label }) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: graphIcon(for: node.type))
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                        .background(graphColor(for: node.type).gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(node.label).font(.title3.weight(.semibold))
                        Text("\(node.type) · \(viewModel.degree[node.id] ?? 0) connections")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if connections.isEmpty {
                    Text("No connections found.").foregroundStyle(.secondary)
                }

                ForEach(connections, id: \.relationship) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.relationship.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(group.others) { other in
                            Button {
                                withAnimation(appSpring) { viewModel.focus(on: other.id) }
                            } label: {
                                HStack {
                                    Circle().fill(graphColor(for: other.type)).frame(width: 8, height: 8)
                                    Text(other.label)
                                    Spacer()
                                    Text(other.type).font(.caption).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .glassCard(cornerRadius: 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding()
        }
    }
}

// MARK: - Sample data

/// A realistic sample career graph so the explorer can be tried before
/// Neo4j is set up. Only shown when the user explicitly asks for it.
private enum DemoGraph {
    static let response: GraphResponse = {
        let companies = ["Stripe", "Datadog", "UIUC Systems Lab"]
        let projects = ["Payout Webhooks", "Ledger Streams", "Trace Sampler", "Quill Editor", "TinyKV", "Tracing Ring Buffer", "SLO Paging", "Usage Dashboard"]
        let skills = ["Go", "Python", "TypeScript", "Rust", "C++", "Kafka", "PostgreSQL", "Redis", "Kubernetes", "Terraform",
                      "React", "gRPC", "Raft", "WebAssembly", "CRDTs", "AWS", "Distributed Systems", "Observability"]
        let slug = { (label: String) in label.lowercased().replacingOccurrences(of: " ", with: "-") }

        var nodes = companies.map { GraphNode(id: slug($0), label: $0, type: "Company") }
        nodes += projects.map { GraphNode(id: slug($0), label: $0, type: "Project") }
        nodes += skills.map { GraphNode(id: slug($0), label: $0, type: "Skill") }

        let usedIn: [String: [String]] = [
            "Payout Webhooks": ["Go", "Kafka", "PostgreSQL", "Distributed Systems"],
            "Ledger Streams": ["Go", "Kafka", "PostgreSQL", "Kubernetes"],
            "Trace Sampler": ["Python", "Observability", "AWS"],
            "Quill Editor": ["Rust", "WebAssembly", "CRDTs", "TypeScript"],
            "TinyKV": ["Go", "Raft", "gRPC", "Distributed Systems"],
            "Tracing Ring Buffer": ["C++", "Observability"],
            "SLO Paging": ["Observability", "Terraform", "Kubernetes"],
            "Usage Dashboard": ["React", "TypeScript", "Redis"],
        ]
        let builtAt: [String: String] = [
            "Payout Webhooks": "Stripe", "Ledger Streams": "Stripe", "SLO Paging": "Stripe",
            "Trace Sampler": "Datadog", "Usage Dashboard": "Datadog", "Tracing Ring Buffer": "UIUC Systems Lab",
        ]

        var edges: [GraphEdge] = []
        for (project, skillList) in usedIn {
            edges += skillList.map { GraphEdge(source: slug($0), target: slug(project), relationship: "USED_IN") }
        }
        for (project, company) in builtAt {
            edges.append(GraphEdge(source: slug(project), target: slug(company), relationship: "WORKED_AT"))
        }
        edges.append(GraphEdge(source: "stripe", target: "slo-paging", relationship: "ACCOMPLISHED"))
        edges.append(GraphEdge(source: "aws", target: "stripe", relationship: "WORKED_AT"))
        return GraphResponse(available: true, nodes: nodes, edges: edges)
    }()
}

#Preview {
    GraphExplorerView(viewModel: GraphViewModel())
}
