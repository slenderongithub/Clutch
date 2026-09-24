import Foundation

/// Reads intent from short chat messages in the Resume Builder.
enum ChatIntent {
    private static let verbs: Set = ["generate", "make", "create", "build", "tailor", "write", "craft", "draft", "prepare", "produce", "start", "begin"]
    private static let targets: Set = ["resume", "résumé", "cv", "it", "this", "one", "jd"]
    private static let phrases = ["do it", "go ahead", "let's go", "lets go", "yes please", "go for it"]

    /// "make me a good resume based on this jd" → true. "focus on my Go
    /// projects" → false: a verb needs a target (resume / it / this…) unless
    /// the whole message is a bare command like "generate".
    static func isGenerateRequest(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let words = lowered.split { !$0.isLetter && $0 != "'" && $0 != "é" }.map(String.init)
        guard !words.isEmpty, words.count <= 30 else { return false }
        if phrases.contains(where: lowered.contains) { return true }
        guard !verbs.isDisjoint(with: words) else { return false }
        return words.count <= 3 || !targets.isDisjoint(with: words)
    }
}
