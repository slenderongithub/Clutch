// Self-check for ChatIntent.
// Run: swiftc -parse-as-library scripts/check_chat_intent.swift Clutch/ChatIntent.swift -o /tmp/intentcheck && /tmp/intentcheck
@main
enum IntentCheck {
    static func main() {
        let go = ["make me a good resume based upon this jd", "generate", "start", "tailor it", "go ahead",
                  "Create my CV for this role", "write the résumé", "let's go", "build one"]
        let stay = ["focus on my Go projects", "emphasize my build systems work", "keep it to one page please thanks",
                    "hello", "mention leadership", ""]
        for text in go { precondition(ChatIntent.isGenerateRequest(text), "should trigger: \(text)") }
        for text in stay { precondition(!ChatIntent.isGenerateRequest(text), "should not trigger: \(text)") }
        print("chat intent self-check passed")
    }
}
