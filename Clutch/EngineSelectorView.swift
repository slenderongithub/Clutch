import AppKit
import SwiftUI

enum InferenceMode: String {
    case cloud
    case local
}

/// Live view of the backend's local-model catalog. Shared so Onboarding and
/// Engine Selector show the same download progress; polls only while a
/// download or checksum verification is actually running.
@Observable
@MainActor
final class LocalModelStore {
    static let shared = LocalModelStore()

    private(set) var status: LocalStatus?
    private(set) var errorMessage: String?
    private var pollTask: Task<Void, Never>?

    private init() {}

    var isBusy: Bool {
        status?.models.contains { $0.state == .downloading || $0.state == .verifying } ?? false
    }

    var readyModels: [LocalModel] {
        status?.models.filter { $0.state == .ready } ?? []
    }

    func refresh() async {
        await apply { try await NetworkManager.shared.localStatus() }
    }

    func download(_ model: LocalModel) async {
        await apply { try await NetworkManager.shared.downloadLocalModel(id: model.id) }
    }

    func pause() async {
        await apply { try await NetworkManager.shared.pauseLocalDownload() }
    }

    func delete(_ model: LocalModel) async {
        await apply { try await NetworkManager.shared.deleteLocalModel(id: model.id) }
    }

    private func apply(_ call: () async throws -> LocalStatus) async {
        do {
            let status = try await call()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                self.status = status
                errorMessage = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        pollIfNeeded()
    }

    private func pollIfNeeded() {
        guard isBusy, pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                if let status = try? await NetworkManager.shared.localStatus() {
                    self.status = status
                }
                if !isBusy { break }
            }
            pollTask = nil
        }
    }
}

struct EngineSelectorView: View {
    @AppStorage("inferenceMode") private var inferenceMode: InferenceMode = .cloud
    @State private var secrets = Secrets.shared

    var body: some View {
        Form {
            Section {
                PageHeader(
                    icon: "cpu",
                    title: "Inference Engine",
                    subtitle: "Choose where Clutch's language model runs. Retrieval always stays on this Mac."
                )
                Picker("Engine", selection: $inferenceMode.animation(.spring(response: 0.4, dampingFraction: 0.8))) {
                    Label("Cloud · Gemini", systemImage: "cloud").tag(InferenceMode.cloud)
                    Label("Local · Private", systemImage: "lock.laptopcomputer").tag(InferenceMode.local)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            switch inferenceMode {
            case .cloud:
                cloudSection
            case .local:
                LocalModelsSection()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(.regularMaterial)
        .navigationTitle("Engine Selector")
    }

    private var cloudSection: some View {
        Section {
            SecureField("Gemini API Key", text: $secrets.geminiAPIKey, prompt: Text("Paste your key"))
            LabeledContent("Status") {
                if secrets.geminiAPIKey.isEmpty {
                    Label("No key", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                } else {
                    Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            Link(destination: URL(string: "https://aistudio.google.com/apikey")!) {
                Label("Get a free key from Google AI Studio", systemImage: "arrow.up.right.square")
            }
        } header: {
            Text("Gemini")
        } footer: {
            Text("Only the retrieved excerpts of your career history and the job description are sent. The key is stored only on this Mac.")
        }
    }
}

/// The downloadable GGUF catalog: progress, pause/resume, checksum state,
/// and which model generation uses. Reused inside Onboarding.
struct LocalModelsSection: View {
    @AppStorage("localModelID") private var localModelID: String = ""
    @State private var store = LocalModelStore.shared
    @State private var backend = BackendController.shared
    @State private var pendingDelete: LocalModel?

    var body: some View {
        Section {
            if let status = store.status {
                if !status.runtimeAvailable {
                    Label("The llama.cpp runtime isn't installed — run backend/setup_backend.sh.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                DeviceSummary(device: status.device, recommended: status.recommended)
                ForEach(status.models) { model in
                    LocalModelRow(
                        model: model,
                        isActive: activeModelID == model.id,
                        isRecommended: status.recommendedID == model.id,
                        downloadsLocked: store.isBusy,
                        onUse: { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { localModelID = model.id } },
                        onDownload: { Task { await store.download(model) } },
                        onPause: { Task { await store.pause() } },
                        onDelete: { pendingDelete = model }
                    )
                }
            } else if let errorMessage = store.errorMessage {
                Label(errorMessage, systemImage: "wifi.slash").foregroundStyle(.secondary)
                Button("Retry") { Task { await backend.start(); await store.refresh() } }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading models…").foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("On-Device Models")
                Spacer()
                if let dir = store.status?.modelsDir {
                    Button("Show in Finder", systemImage: "folder") {
                        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Show models folder in Finder")
                }
            }
        } footer: {
            Text("Quantized GGUF models run via llama.cpp with Metal acceleration. Downloads resume where they left off and are SHA-256 verified before use. Nothing leaves your Mac.")
        }
        .task { await store.refresh() }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "model")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let model = pendingDelete { Task { await store.delete(model) } }
            }
        } message: {
            Text("This frees \(ByteCountFormatter.string(fromByteCount: pendingDelete?.sizeBytes ?? 0, countStyle: .file)). You can download it again anytime.")
        }
    }

    /// The saved choice if it's downloaded, otherwise the first ready model —
    /// mirrors the backend's own fallback in local_model.ready_model_id.
    private var activeModelID: String? {
        let ready = store.readyModels
        return ready.first { $0.id == localModelID }?.id ?? ready.first?.id
    }
}

private struct LocalModelRow: View {
    let model: LocalModel
    let isActive: Bool
    let isRecommended: Bool
    let downloadsLocked: Bool
    let onUse: () -> Void
    let onDownload: () -> Void
    let onPause: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "shippingbox")
                .font(.title3)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(model.name).font(.headline)
                            if isActive {
                                badge("In Use", tint: .accentColor)
                            } else if isRecommended {
                                badge("Best for this Mac", tint: .green)
                            }
                        }
                        Text(model.description).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    actions
                }
                status
                if model.state != .ready || model.fit != "good" {
                    fitLabel
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(model.canDownload || model.state == .ready ? 1 : 0.7)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private var fitLabel: some View {
        let (icon, tint): (String, Color) = switch model.fit {
        case "good": ("checkmark.seal.fill", .green)
        case "tight": ("exclamationmark.triangle.fill", .orange)
        default: ("xmark.octagon.fill", .red)
        }
        return Label(model.fitNote, systemImage: icon)
            .font(.caption)
            .foregroundStyle(tint)
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .downloading, .paused:
            ProgressView(value: model.progress)
                .tint(model.state == .paused ? .secondary : .accentColor)
            Text(progressCaption)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case .verifying:
            ProgressView().progressViewStyle(.linear)
            Text("Verifying SHA-256 checksum…").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Label(model.error ?? "Download failed.", systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .ready, .notDownloaded:
            Text(sizeText).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch model.state {
        case .notDownloaded, .failed:
            Button("Download", systemImage: "arrow.down.circle", action: onDownload)
                .buttonStyle(.borderedProminent)
                .disabled(downloadsLocked || !model.canDownload)
                .help(model.canDownload ? "Download \(model.name)" : model.fitNote)
        case .paused:
            HStack {
                Button("Delete", systemImage: "trash", action: onDelete).labelStyle(.iconOnly)
                Button("Resume", systemImage: "play.fill", action: onDownload)
                    .buttonStyle(.borderedProminent)
                    .disabled(downloadsLocked || !model.canDownload)
            }
        case .downloading:
            Button("Pause", systemImage: "pause.fill", action: onPause)
                .buttonStyle(.bordered)
        case .verifying:
            EmptyView()
        case .ready:
            HStack {
                Button("Delete", systemImage: "trash", action: onDelete).labelStyle(.iconOnly)
                if !isActive {
                    Button("Use", action: onUse).buttonStyle(.bordered)
                }
            }
        }
    }

    private var sizeText: String {
        let size = ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file)
        return model.state == .ready ? "\(size) on disk" : "\(size) download"
    }

    private var progressCaption: String {
        let done = ByteCountFormatter.string(fromByteCount: model.downloadedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file)
        let percent = Int(model.progress * 100)
        return model.state == .paused ? "Paused · \(done) of \(total) (\(percent)%)" : "\(done) of \(total) · \(percent)%"
    }
}

/// What Clutch detected about this Mac, and what that means for local models.
private struct DeviceSummary: View {
    let device: LocalStatus.Device
    let recommended: LocalModel?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.appleSilicon ? "laptopcomputer" : "desktopcomputer")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("This Mac: \(device.chip)").font(.headline)
                Text("\(device.memoryGB.formatted()) GB memory · \(ByteCountFormatter.string(fromByteCount: device.freeDiskBytes, countStyle: .file)) free disk\(device.appleSilicon ? " · Metal" : " · CPU only")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let recommended {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Recommended").font(.caption).foregroundStyle(.secondary)
                    Text(recommended.name).font(.callout.weight(.semibold))
                }
            } else {
                Label("No model fits — free up disk space or use Cloud", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Large, friendly section header used at the top of full-page forms.
struct PageHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(BrandGradient.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .accentColor.opacity(0.3), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    EngineSelectorView()
}
