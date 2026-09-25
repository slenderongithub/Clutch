import AppKit
import Darwin
import Foundation

/// Launches the local FastAPI backend on app start (per ARCHITECTURE.md) and
/// tears it down on quit. If a Clutch backend is already running — e.g.
/// one started by hand from a terminal — it's reused and never killed.
@Observable
@MainActor
final class BackendController {
    enum Status: Equatable {
        case checking
        case starting
        case online
        case offline(String)
    }

    static let shared = BackendController()

    private(set) var status: Status = .checking
    private var process: Process?

    /// ponytail: resolved from this source file's location, which is right
    /// for dev builds run from the repo. Override with CLUTCH_BACKEND_DIR;
    /// bundle the backend into Resources if Clutch ever ships as a .dmg.
    static let backendDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["CLUTCH_BACKEND_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("backend")
    }()

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Clutch/backend.log")

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { BackendController.shared.process?.terminate() }
        }
    }

    func start() async {
        guard status != .starting else { return }
        status = .checking
        let network = NetworkManager.shared
        // Reuse a Clutch backend that's already up (ours, or one started by hand).
        for port in Set([network.port, Self.preferredPort]) where await network.isClutchBackend(onPort: port) {
            network.port = port
            await becameOnline()
            return
        }

        let python = Self.backendDirectory.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            status = .offline("No backend virtualenv at \(Self.backendDirectory.path). Run backend/setup_backend.sh.")
            return
        }

        status = .starting
        if process?.isRunning != true {
            // 8000 if free; otherwise any free port — another app holding
            // 8000 must never stop Clutch from starting.
            network.port = Self.isPortFree(Self.preferredPort) ? Self.preferredPort : Self.freePort()
            do {
                process = try launch(python: python, port: network.port)
            } catch {
                status = .offline("Couldn't launch the backend: \(error.localizedDescription)")
                return
            }
        }

        // First boot imports ChromaDB + an embedding model — give it time.
        for _ in 0..<90 {
            try? await Task.sleep(for: .milliseconds(500))
            if await NetworkManager.shared.isBackendHealthy() {
                await becameOnline()
                return
            }
            if process?.isRunning == false { break }
        }
        status = .offline("The backend didn't start. See \(Self.logURL.path).")
    }

    /// Starts the backend, then keeps it alive: if it stops answering (crash,
    /// killed, port freed), it's relaunched within a few seconds.
    func startAndKeepAlive() async {
        await start()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            guard status == .online else { continue }
            if await !NetworkManager.shared.isBackendHealthy() {
                await start()
            }
        }
    }

    private func becameOnline() async {
        await Self.pushGraphConfig()
        status = .online
    }

    /// Sends the Neo4j settings saved in Settings → Knowledge Graph. Skipped
    /// until the user has saved some, so env-var configuration still works.
    @discardableResult
    static func pushGraphConfig() async -> GraphResponse? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "neo4jUser") != nil || !Secrets.shared.neo4jPassword.isEmpty else { return nil }
        return try? await NetworkManager.shared.configureGraph(
            uri: defaults.string(forKey: "neo4jURI") ?? "bolt://localhost:7687",
            user: defaults.string(forKey: "neo4jUser") ?? "neo4j",
            password: Secrets.shared.neo4jPassword
        )
    }

    private static let preferredPort = 8000

    private static func isPortFree(_ port: Int) -> Bool {
        bindProbe(port: port) != nil
    }

    /// A port the OS guarantees is free right now.
    private static func freePort() -> Int {
        bindProbe(port: 0) ?? 8765
    }

    /// Binds a throwaway socket to 127.0.0.1:port; returns the bound port or nil.
    private static func bindProbe(port: Int) -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func launch(python: URL, port: Int) throws -> Process {
        let process = Process()
        process.executableURL = python
        // No access log: the keep-alive health checks would drown real errors.
        process.arguments = ["-m", "uvicorn", "main:app", "--host", "127.0.0.1", "--port", String(port), "--no-access-log"]
        process.currentDirectoryURL = Self.backendDirectory

        // GUI apps don't inherit a shell PATH, so pdflatex (MacTeX) and
        // Homebrew tools would otherwise be invisible to the backend.
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = "/Library/TeX/texbin:/opt/homebrew/bin:/usr/local/bin"
        environment["PATH"] = [extraPaths, environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        process.environment = environment

        // Append, never truncate: the log must survive relaunches to be useful.
        try FileManager.default.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Self.logURL.path) {
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: Self.logURL)
        log.seekToEndOfFile()
        log.write(Data("\n=== Clutch backend starting \(Date.now.formatted()) on port \(port) ===\n".utf8))
        process.standardOutput = log
        process.standardError = log

        try process.run()
        return process
    }
}
