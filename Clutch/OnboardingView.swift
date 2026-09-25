import SwiftUI

/// Launch-time engine picker (shown on every launch). Writes the same
/// @AppStorage keys EngineSelectorView reads, so choosing here is exactly
/// equivalent to setting it there later.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("inferenceMode") private var inferenceMode: InferenceMode = .cloud
    @State private var secrets = Secrets.shared

    @State private var selectedMode: InferenceMode = .cloud
    @State private var draftAPIKey: String = ""
    @State private var localStore = LocalModelStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 28)
                .padding(.bottom, 20)

            HStack(spacing: 14) {
                modeCard(
                    mode: .cloud,
                    icon: "cloud.fill",
                    title: "Cloud",
                    subtitle: "Gemini · fast, needs a key"
                )
                modeCard(
                    mode: .local,
                    icon: "lock.laptopcomputer",
                    title: "Local",
                    subtitle: "On-device · fully private"
                )
            }
            .padding(.horizontal, 32)

            Group {
                switch selectedMode {
                case .cloud: cloudSetup
                case .local: localSetup
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.top, 16)
            .padding(.bottom, 24)

            Divider()

            HStack {
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue", action: commit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedMode == .cloud && trimmedKey.isEmpty)
            }
            .padding()
        }
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .background(alignment: .top) {
            BrandGradient.wash.frame(height: 260).ignoresSafeArea()
        }
        .background(.regularMaterial)
        .onAppear {
            selectedMode = inferenceMode
            draftAPIKey = secrets.geminiAPIKey
        }
    }

    private var trimmedKey: String {
        draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(BrandGradient.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .accentColor.opacity(0.35), radius: 12, y: 6)
                .symbolEffect(.bounce, value: selectedMode)
            Text("Welcome back to Clutch")
                .font(.largeTitle.weight(.bold))
            Text("Pick the engine that tailors your resumes this session.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private func modeCard(mode: InferenceMode, icon: String, title: String, subtitle: String) -> some View {
        let isSelected = selectedMode == mode
        return Button {
            withAnimation(appSpring) { selectedMode = mode }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: 44, height: 44)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isSelected ? AnyShapeStyle(BrandGradient.fill) : AnyShapeStyle(.quaternary))
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding()
            .glassCard(cornerRadius: 14)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var cloudSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Gemini API Key", text: $draftAPIKey, prompt: Text("Paste your Gemini API key"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Text("Stored only on this Mac.")
                Spacer()
                Link("Get a free key", destination: URL(string: "https://aistudio.google.com/apikey")!)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
        .transition(.opacity)
    }

    private var localSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let ready = localStore.readyModels.first {
                Label("\(ready.name) is downloaded and ready.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Label("No model downloaded yet", systemImage: "arrow.down.circle")
                    .font(.headline)
                if let status = localStore.status {
                    if let best = status.recommended {
                        Text("Best fit for this \(status.device.chip) (\(status.device.memoryGB.formatted()) GB): **\(best.name)**, \(ByteCountFormatter.string(fromByteCount: best.sizeBytes, countStyle: .file)). Download it from **Engine Selector** — it runs in the background and resumes if interrupted.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("No local model fits this Mac right now (memory or disk space). Cloud is the better choice.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
            if localStore.isBusy, let model = localStore.status?.models.first(where: { $0.state == .downloading }) {
                ProgressView(value: model.progress) {
                    Text("Downloading \(model.name)…").font(.caption)
                }
            }
        }
        .padding(.horizontal, 32)
        .transition(.opacity)
        .task { await localStore.refresh() }
    }

    private func commit() {
        guard selectedMode == .local || !trimmedKey.isEmpty else { return }
        inferenceMode = selectedMode
        if selectedMode == .cloud { secrets.geminiAPIKey = trimmedKey }
        dismiss()
    }
}

#Preview {
    OnboardingView()
}
