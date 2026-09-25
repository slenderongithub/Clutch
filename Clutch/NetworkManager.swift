import Foundation

private struct ErrorDetail: Decodable {
    let detail: String
}

enum NetworkError: LocalizedError {
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The backend returned an unreadable response."
        case .serverError(let message):
            message
        }
    }
}

struct GenerateResumeResponse: Decodable {
    let success: Bool
    let message: String
    let texSource: String?
    let pdfPath: String?
    let chunkCount: Int?

    enum CodingKeys: String, CodingKey {
        case success, message
        case texSource = "tex_source"
        case pdfPath = "pdf_path"
        case chunkCount = "chunk_count"
    }
}

struct GraphNode: Decodable, Hashable, Identifiable {
    let id: String
    let label: String
    let type: String // "Skill" | "Project" | "Company"
}

struct GraphEdge: Decodable, Hashable {
    let source: String
    let target: String
    let relationship: String // "USED_IN" | "WORKED_AT" | "ACCOMPLISHED"
}

struct GraphResponse: Decodable {
    let available: Bool
    var reason: String?
    let nodes: [GraphNode]
    let edges: [GraphEdge]
}

struct RetrievedChunk: Decodable, Hashable {
    let text: String
    let category: String
    var source: String?
    let score: Double
}

struct GenerationProgress: Decodable {
    let active: Bool
    let tokens: Int
    let maxTokens: Int
    let model: String

    enum CodingKeys: String, CodingKey {
        case active, tokens, model
        case maxTokens = "max_tokens"
    }
}

/// One ingested file in the career library.
struct CareerDocument: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let addedAt: Double
    let chunkCount: Int
    let categories: [String: Int]

    enum CodingKeys: String, CodingKey {
        case id, name, categories
        case addedAt = "added_at"
        case chunkCount = "chunk_count"
    }
}

struct RetrievalResponse: Decodable {
    let chunks: [RetrievedChunk]
    let graphFacts: [String]
    let graphAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case chunks
        case graphFacts = "graph_facts"
        case graphAvailable = "graph_available"
    }
}

struct LocalModel: Decodable, Identifiable, Hashable {
    enum State: String, Decodable {
        case notDownloaded = "not_downloaded"
        case downloading, verifying, paused, ready, failed
    }

    let id: String
    let name: String
    let description: String
    let filename: String
    let sizeBytes: Int64
    let downloadedBytes: Int64
    let state: State
    let error: String?
    /// How well it suits this Mac: good | tight | too_big | no_disk.
    let fit: String
    let fitNote: String

    var canDownload: Bool { fit != "too_big" && fit != "no_disk" }

    var progress: Double { sizeBytes > 0 ? Double(downloadedBytes) / Double(sizeBytes) : 0 }

    enum CodingKeys: String, CodingKey {
        case id, name, description, filename, state, error, fit
        case fitNote = "fit_note"
        case sizeBytes = "size_bytes"
        case downloadedBytes = "downloaded_bytes"
    }
}

struct LocalStatus: Decodable {
    struct Device: Decodable, Hashable {
        let chip: String
        let memoryGB: Double
        let freeDiskBytes: Int64
        let appleSilicon: Bool

        enum CodingKeys: String, CodingKey {
            case chip
            case memoryGB = "memory_gb"
            case freeDiskBytes = "free_disk_bytes"
            case appleSilicon = "apple_silicon"
        }
    }

    let runtimeAvailable: Bool
    let modelsDir: String
    let models: [LocalModel]
    /// Best model for this Mac's memory and disk, if any fits.
    let recommendedID: String?
    let device: Device

    var recommended: LocalModel? { models.first { $0.id == recommendedID } }

    enum CodingKeys: String, CodingKey {
        case models, device
        case runtimeAvailable = "runtime_available"
        case modelsDir = "models_dir"
        case recommendedID = "recommended_id"
    }
}

/// Talks to the local FastAPI backend spawned alongside the app.
/// Uses "localhost" (not "127.0.0.1") so macOS App Transport Security's
/// automatic local-loopback exemption applies without any Info.plist changes.
final class NetworkManager {
    static let shared = NetworkManager()

    /// Set by BackendController — 8000 unless something else holds it.
    var port = 8000
    private var baseURL: URL { URL(string: "http://localhost:\(port)")! }

    private init() {}

    func generateResume(
        jobDescription: String,
        templateID: String,
        inferenceMode: InferenceMode,
        geminiAPIKey: String,
        localModelID: String,
        instructions: String = ""
    ) async throws -> GenerateResumeResponse {
        // Local 7B generation on a laptop can take minutes, not seconds.
        try await post(path: "api/v1/generate", timeout: 900, body: [
            "jd_text": jobDescription,
            "inference_mode": inferenceMode.rawValue,
            "template_id": templateID,
            "gemini_api_key": geminiAPIKey,
            "local_model_id": localModelID,
            "user_instructions": instructions,
        ])
    }

    /// Just the retrieval step — what the live Context Retrieval panel shows.
    func retrieveContext(jobDescription: String) async throws -> RetrievalResponse {
        try await post(path: "api/v1/retrieve", body: ["jd_text": jobDescription])
    }

    func isBackendHealthy() async -> Bool {
        await isClutchBackend(onPort: port)
    }

    /// True only for Clutch's own backend — not whatever else might be
    /// listening on the port.
    func isClutchBackend(onPort port: Int) async -> Bool {
        var request = URLRequest(url: URL(string: "http://localhost:\(port)/api/v1/health")!)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return body["app"] as? String == "clutch"
    }

    func generationProgress() async -> GenerationProgress? {
        try? await send(URLRequest(url: baseURL.appendingPathComponent("api/v1/generate/progress")))
    }

    func rebuildGraph() async throws -> GraphResponse {
        try await post(path: "api/v1/graph/rebuild", timeout: 120, body: [:])
    }

    // MARK: Local models

    func localStatus() async throws -> LocalStatus {
        try await send(URLRequest(url: baseURL.appendingPathComponent("api/v1/local/status")))
    }

    func downloadLocalModel(id: String) async throws -> LocalStatus {
        try await post(path: "api/v1/local/download", body: ["model_id": id])
    }

    func pauseLocalDownload() async throws -> LocalStatus {
        try await post(path: "api/v1/local/cancel", body: [:])
    }

    func deleteLocalModel(id: String) async throws -> LocalStatus {
        try await post(path: "api/v1/local/delete", body: ["model_id": id])
    }

    /// Compiles the given .tex source into a PDF — no LLM involved.
    func compilePDF(texSource: String) async throws -> GenerateResumeResponse {
        try await post(path: "api/v1/compile_only", body: ["tex_source": texSource])
    }

    enum IngestMode: String {
        /// Keep the library; a file with an existing name replaces its old version.
        case add
        /// Wipe the library (and its graph entities) first.
        case replace
    }

    /// Uploads several career documents (.pdf/.txt/.md) in one request.
    /// Graph extraction runs only if an engine and Neo4j are available.
    func ingestDocuments(
        fileURLs: [URL],
        mode: IngestMode,
        geminiAPIKey: String,
        inferenceMode: InferenceMode,
        localModelID: String
    ) async throws -> GenerateResumeResponse {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/ingest"))
        request.httpMethod = "POST"
        request.timeoutInterval = 1800 // graph extraction per file, possibly on the local model
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func part(_ header: String, _ data: Data) {
            body.append("--\(boundary)\r\n\(header)\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }
        for url in fileURLs {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            let filename = url.lastPathComponent.replacingOccurrences(of: "\"", with: "'")
            part(
                "Content-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType(for: url.pathExtension))",
                try Data(contentsOf: url)
            )
        }
        let fields = [
            "mode": mode.rawValue,
            "gemini_api_key": geminiAPIKey,
            "inference_mode": inferenceMode.rawValue,
            "local_model_id": localModelID,
        ]
        for (name, value) in fields where !value.isEmpty {
            part("Content-Disposition: form-data; name=\"\(name)\"", Data(value.utf8))
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        return try await send(request)
    }

    func listDocuments() async throws -> [CareerDocument] {
        try await send(URLRequest(url: baseURL.appendingPathComponent("api/v1/documents")))
    }

    func deleteDocument(id: String) async throws -> [CareerDocument] {
        try await post(path: "api/v1/documents/delete", body: ["doc_id": id])
    }

    /// Fetches the career knowledge graph. available=false means Neo4j
    /// isn't reachable server-side — never thrown as an error.
    func fetchGraph() async throws -> GraphResponse {
        let request = URLRequest(url: baseURL.appendingPathComponent("api/v1/graph"))
        return try await send(request)
    }

    /// Points the backend at the user's Neo4j; the response says whether it connected.
    func configureGraph(uri: String, user: String, password: String) async throws -> GraphResponse {
        try await post(path: "api/v1/graph/config", timeout: 15, body: ["uri": uri, "user": user, "password": password])
    }

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "pdf": "application/pdf"
        case "md": "text/markdown"
        default: "text/plain"
        }
    }

    private func post<T: Decodable>(path: String, timeout: TimeInterval = 60, body: [String: Any]) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    /// The backend writes a fresh token at every start; re-reading it per
    /// request means a restarted backend never breaks the app.
    private var tokenURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clutch/backend-\(port).token")
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        var request = request
        if let token = try? String(contentsOf: tokenURL, encoding: .utf8) {
            request.setValue(token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-Clutch-Token")
        }
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            // FastAPI errors arrive as {"detail": "..."} — show just the message.
            let message = (try? JSONDecoder().decode(ErrorDetail.self, from: data).detail)
                ?? String(data: data, encoding: .utf8)
                ?? "Server returned status \(httpResponse.statusCode)."
            throw NetworkError.serverError(message)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}
