import SwiftUI

struct ResumeTemplate: Identifiable, Hashable {
    let id = UUID()
    let name: String
    /// Stable identifier sent to the backend's /api/v1/generate as template_id.
    let slug: String
}

// Matches resume_codes/*.tex and the Assets.xcassets imagesets 1:1 — the
// slug is both the backend template_id and the asset catalog image name.
let mockResumeTemplates: [ResumeTemplate] = [
    ResumeTemplate(name: "Jake's Resume", slug: "jakes_resume"),
    ResumeTemplate(name: "Clean Minimalist", slug: "clean_minimalist"),
    ResumeTemplate(name: "Modern Professional", slug: "modern_professional"),
    ResumeTemplate(name: "Hybrid Left Sidebar", slug: "hybrid_left_sidebar"),
    ResumeTemplate(name: "Deedy's Resume", slug: "deedys_resume"),
    ResumeTemplate(name: "Executive Serif", slug: "executive_serif"),
]

/// A Keynote-style grid for picking one of the pre-built LaTeX templates.
/// The LLM only ever injects content into these — it never writes raw LaTeX.
struct TemplateChooserView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedTemplate: ResumeTemplate?
    @State private var pendingSelection: ResumeTemplate?

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 210), spacing: 28)]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("Choose a Template").font(.title2.weight(.semibold))
                Text("Clutch fills the template with your tailored content. Double-click to use.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 28) {
                    ForEach(mockResumeTemplates) { template in
                        TemplateCard(template: template, isSelected: pendingSelection == template)
                            .onTapGesture(count: 2) {
                                selectedTemplate = template
                                dismiss()
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                withAnimation(appSpring) { pendingSelection = template }
                            })
                    }
                }
                .padding(24)
            }
            .background(.ultraThinMaterial)

            Divider()
            HStack {
                if let pendingSelection {
                    Label(pendingSelection.name, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use Template") {
                    selectedTemplate = pendingSelection
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(pendingSelection == nil)
            }
            .padding()
        }
        .frame(minWidth: 720, minHeight: 600)
        .background(.regularMaterial)
        .onAppear { pendingSelection = selectedTemplate }
    }
}

private struct TemplateCard: View {
    let template: ResumeTemplate
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 10) {
            Image(template.slug)
                .resizable()
                .aspectRatio(0.77, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 3 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(8)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .shadow(color: .black.opacity(isHovering || isSelected ? 0.25 : 0.12), radius: isHovering ? 12 : 5, y: isHovering ? 8 : 3)
                .scaleEffect(isHovering ? 1.03 : 1)

            Text(template.name)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(appSpring) { isHovering = hovering } }
    }
}

#Preview {
    TemplateChooserView(selectedTemplate: .constant(nil))
}
