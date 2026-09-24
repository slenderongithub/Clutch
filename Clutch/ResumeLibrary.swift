import AppKit
import Foundation

/// A .tex resume on disk, open in the IDE.
struct LatexFile: Identifiable {
    let id = UUID()
    var name: String
    var sourceCode: String
    /// What's currently on disk — sourceCode differs from it while unsaved.
    var savedSource: String
    var pdfURL: URL?

    var isDirty: Bool { sourceCode != savedSource }

    /// "Priya_Raman_ML_Engineer.tex" → "Priya Raman ML Engineer"
    var displayName: String {
        (name as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
    }
}

/// Every resume lives as a plain .tex file in
/// ~/Library/Application Support/Clutch/Resumes, so drafts survive relaunches
/// and can be opened in any other editor.
@Observable
@MainActor
final class ResumeLibrary {
    var files: [LatexFile] = []
    private(set) var lastError: String?

    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Clutch/Resumes", isDirectory: true)

    init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: keys)) ?? []
        // Whole seconds, so files created together tie and fall back to
        // alphabetical order.
        let created = { (url: URL) in
            ((try? url.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast).timeIntervalSince1970.rounded(.down)
        }
        files = urls
            .filter { $0.pathExtension.lowercased() == "tex" }
            // Newest first, so a freshly generated resume lands at the top;
            // creation (not modification) date keeps autosave from reshuffling.
            .sorted { created($0) != created($1) ? created($0) > created($1) : $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return LatexFile(name: url.lastPathComponent, sourceCode: source, savedSource: source)
            }
    }

    func index(of id: LatexFile.ID) -> Int? {
        files.firstIndex { $0.id == id }
    }

    func save(_ id: LatexFile.ID) {
        guard let index = index(of: id), files[index].isDirty else { return }
        do {
            try files[index].sourceCode.write(to: url(for: files[index].name), atomically: true, encoding: .utf8)
            files[index].savedSource = files[index].sourceCode
            lastError = nil
        } catch {
            lastError = "Couldn't save \(files[index].name): \(error.localizedDescription)"
        }
    }

    @discardableResult
    func add(baseName: String, source: String) -> LatexFile.ID {
        let name = uniqueName(for: baseName)
        try? source.write(to: url(for: name), atomically: true, encoding: .utf8)
        let file = LatexFile(name: name, sourceCode: source, savedSource: source)
        files.insert(file, at: 0)
        return file.id
    }

    func duplicate(_ id: LatexFile.ID) -> LatexFile.ID? {
        guard let file = files.first(where: { $0.id == id }) else { return nil }
        return add(baseName: (file.name as NSString).deletingPathExtension + "_copy", source: file.sourceCode)
    }

    /// Moves the file to the Trash (recoverable), never a hard delete.
    func delete(_ id: LatexFile.ID) {
        guard let index = index(of: id) else { return }
        try? FileManager.default.trashItem(at: url(for: files[index].name), resultingItemURL: nil)
        files.remove(at: index)
    }

    func revealInFinder(_ id: LatexFile.ID? = nil) {
        if let id, let file = files.first(where: { $0.id == id }) {
            NSWorkspace.shared.activateFileViewerSelecting([url(for: file.name)])
        } else {
            NSWorkspace.shared.open(Self.directory)
        }
    }

    private func url(for name: String) -> URL {
        Self.directory.appendingPathComponent(name)
    }

    private func uniqueName(for baseName: String) -> String {
        let taken = Set(files.map(\.name))
        var candidate = "\(baseName).tex"
        var counter = 2
        while taken.contains(candidate) || FileManager.default.fileExists(atPath: url(for: candidate).path) {
            candidate = "\(baseName)_\(counter).tex"
            counter += 1
        }
        return candidate
    }
}
