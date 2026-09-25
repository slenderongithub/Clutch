import SwiftUI

/// Live state of one resume-generation run, shown in the inspector while it
/// happens. Owned by ContentView so the chat (which drives it) and the
/// inspector (which shows it) see the same run.
@Observable
@MainActor
final class RetrievalSession {
    enum Stage: Int, Comparable {
        case idle, retrieving, generating, done, failed
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    private(set) var stage: Stage = .idle
    private(set) var chunks: [RetrievedChunk] = []
    private(set) var graphFacts: [String] = []
    private(set) var graphAvailable = false
    private(set) var errorMessage: String?
    private(set) var engineLabel = ""
    private(set) var templateName = ""
    private(set) var startedAt = Date()
    private(set) var finishedAt: Date?
    /// Live token count while a local model writes (polled from the backend).
    private(set) var tokensWritten = 0
    private(set) var tokenBudget = 0
    /// Where the run failed, so the step list can mark the right one red.
    private(set) var failedStage: Stage?

    /// Inspector visibility — opens automatically when a run starts.
    var isPresented = false

    var isRunning: Bool { stage == .retrieving || stage == .generating }
    var hasContent: Bool { stage != .idle }

    func begin(engine: String, template: String) {
        withAnimation(appSpring) {
            stage = .retrieving
            tokensWritten = 0
            tokenBudget = 0
            chunks = []
            graphFacts = []
            graphAvailable = false
            errorMessage = nil
            failedStage = nil
            engineLabel = engine
            templateName = template
            startedAt = .now
            finishedAt = nil
            isPresented = true
        }
    }

    /// Polls local-model progress until generation ends.
    func trackLocalProgress() {
        Task {
            while stage == .generating {
                if let progress = await NetworkManager.shared.generationProgress(), progress.active {
                    tokensWritten = progress.tokens
                    tokenBudget = progress.maxTokens
                }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    func retrieved(_ response: RetrievalResponse) {
        withAnimation(appSpring) {
            chunks = response.chunks
            graphFacts = response.graphFacts
            graphAvailable = response.graphAvailable
            stage = .generating
        }
    }

    func finish() {
        withAnimation(appSpring) {
            stage = .done
            finishedAt = .now
        }
    }

    func fail(_ message: String) {
        withAnimation(appSpring) {
            failedStage = stage
            stage = .failed
            errorMessage = message
            finishedAt = .now
        }
    }
}

/// The inspector: pipeline progress, then exactly what was retrieved from
/// the user's career history — the evidence the resume is allowed to use.
struct RAGVisualizerView: View {
    let session: RetrievalSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                steps
                if session.stage == .failed, let message = session.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if !session.chunks.isEmpty {
                    chunkList
                }
                if !session.graphFacts.isEmpty {
                    factList
                }
            }
            .padding()
        }
        .background(alignment: .top) {
            BrandGradient.wash.frame(height: 220).ignoresSafeArea()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            Label("\(session.engineLabel) · \(session.templateName)", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let end = session.finishedAt ?? context.date
                Text(String(format: "%.1fs", end.timeIntervalSince(session.startedAt)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepRow(
                icon: "doc.text.magnifyingglass",
                title: "Search career history",
                detail: session.stage > .retrieving && session.failedStage != .retrieving
                    ? "\(session.chunks.count) excerpts matched" : "Embedding the job description…",
                state: state(for: .retrieving)
            )
            StepRow(
                icon: "point.3.filled.connected.trianglepath.dotted",
                title: "Expand through knowledge graph",
                detail: graphDetail,
                state: state(for: .retrieving)
            )
            StepRow(
                icon: "text.badge.star",
                title: "Write tailored content",
                detail: writingDetail,
                state: state(for: .generating)
            )
            StepRow(
                icon: "doc.richtext",
                title: "Render LaTeX template",
                detail: session.templateName,
                state: state(for: .done),
                isLast: true
            )
        }
        .padding()
        .glassCard()
    }

    private var writingDetail: String {
        if session.stage == .generating, session.tokensWritten > 0 {
            return "\(session.engineLabel) · \(session.tokensWritten) tokens written (up to ~\(session.tokenBudget))"
        }
        if session.stage == .generating, session.engineLabel.hasPrefix("Local") {
            return "\(session.engineLabel) · loading model & reading evidence… (30–90 s on a laptop)"
        }
        return "\(session.engineLabel) · grounded only in the evidence below"
    }

    private var graphDetail: String {
        guard session.stage > .retrieving else { return "Looking for related skills & projects…" }
        if !session.graphAvailable { return "Graph unavailable — vector search only" }
        return session.graphFacts.isEmpty ? "No matching entities" : "\(session.graphFacts.count) related facts"
    }

    private func state(for step: RetrievalSession.Stage) -> StepRow.State {
        if session.stage == .failed {
            if session.failedStage == step { return .failed }
            return (session.failedStage ?? .idle) > step ? .done : .pending
        }
        if session.stage == .done { return .done }
        if session.stage == step { return .active }
        return session.stage > step ? .done : .pending
    }

    private var chunkList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Matched from your history", systemImage: "checkmark.seal")
                .font(.headline)
            ForEach(Array(session.chunks.enumerated()), id: \.offset) { index, chunk in
                ChunkCard(chunk: chunk)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .animation(appSpring.delay(Double(index) * 0.06), value: session.chunks.count)
            }
        }
    }

    private var factList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Knowledge graph", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            ForEach(session.graphFacts, id: \.self) { fact in
                Text(fact)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(cornerRadius: 8)
            }
        }
    }
}

private struct StepRow: View {
    enum State { case pending, active, done, failed }

    let icon: String
    let title: String
    let detail: String
    let state: State
    var isLast = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(circleFill)
                        .frame(width: 30, height: 30)
                    switch state {
                    case .active:
                        ProgressView().controlSize(.small)
                    case .done:
                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                    case .failed:
                        Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.white)
                    case .pending:
                        Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !isLast {
                    Rectangle()
                        .fill(state == .done ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.2))
                        .frame(width: 2, height: 22)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(state == .pending ? .secondary : .primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.top, 5)
            Spacer(minLength: 0)
        }
        .animation(appSpring, value: state)
    }

    private var circleFill: AnyShapeStyle {
        switch state {
        case .pending: AnyShapeStyle(.quaternary)
        case .active: AnyShapeStyle(Color.accentColor.opacity(0.18))
        case .done: AnyShapeStyle(BrandGradient.fill)
        case .failed: AnyShapeStyle(Color.red)
        }
    }
}

private struct ChunkCard: View {
    let chunk: RetrievedChunk
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(chunk.category.capitalized)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                if let source = chunk.source, !source.isEmpty {
                    Text(source)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text("\(Int(chunk.score * 100))% match")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: chunk.score)
                .tint(chunk.score > 0.5 ? .green : chunk.score > 0.3 ? .orange : .secondary)
            Text(chunk.text)
                .font(.callout)
                .lineLimit(isExpanded ? nil : 3)
                .textSelection(.enabled)
        }
        .padding(12)
        .glassCard(cornerRadius: 10)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(appSpring) { isExpanded.toggle() } }
        .help(isExpanded ? "Click to collapse" : "Click to expand")
    }
}

#Preview {
    RAGVisualizerView(session: RetrievalSession())
        .frame(width: 380, height: 700)
}
