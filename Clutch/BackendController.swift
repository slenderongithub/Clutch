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
    static var backendDirectory: URL { Runtime.current.sourceDirectory }

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

        let runtime = Runtime.current
        guard FileManager.default.isExecutableFile(atPath: runtime.python.path) else {
            status = .offline(runtime.isBundled
                ? "Clutch's bundled engine is missing or damaged. Reinstall Clutch."
                : "No backend virtualenv at \(runtime.sourceDirectory.path). Run backend/setup_backend.sh.")
            return
        }

        status = .starting
        if process?.isRunning != true {
            // 8000 if free; otherwise any free port — another app holding
            // 8000 must never stop Clutch from starting.
            network.port = Self.isPortFree(Self.preferredPort) ? Self.preferredPort : Self.freePort()
            do {
                process = try launch(runtime, port: network.port)
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
        status = .online
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

    private func launch(_ runtime: Runtime, port: Int) throws -> Process {
        let process = Process()
        process.executableURL = runtime.python
        // No access log: the keep-alive health checks would drown real errors.
        process.arguments = ["-m", "uvicorn", "main:app", "--host", "127.0.0.1", "--port", String(port), "--no-access-log"]
        process.currentDirectoryURL = runtime.sourceDirectory

        // GUI apps don't inherit a shell PATH; in development this lets the
        // backend fall back to a MacTeX pdflatex if Tectonic isn't around.
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = "/Library/TeX/texbin:/opt/homebrew/bin:/usr/local/bin"
        environment["PATH"] = [extraPaths, environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        environment.merge(runtime.environment) { _, new in new }
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

/// Where the backend and its tools live. A shipped Clutch.app carries
/// everything in Contents/Resources/backend (see scripts/make_dmg.sh): a
/// standalone Python with the dependencies, the backend source, Tectonic
/// with a pre-filled package cache, and the embedding model — so nothing
/// else needs installing. In development it's the repo's backend/.venv.
struct Runtime {
    let isBundled: Bool
    let sourceDirectory: URL
    let python: URL
    let environment: [String: String]

    static let current: Runtime = bundled ?? development

    private static var bundled: Runtime? {
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("backend") else { return nil }
        let python = resources.appendingPathComponent("runtime/bin/python3")
        guard FileManager.default.fileExists(atPath: python.path) else { return nil }
        let data = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clutch")
        return Runtime(
            isBundled: true,
            sourceDirectory: resources.appendingPathComponent("app"),
            python: python,
            environment: [
                "CLUTCH_TECTONIC": resources.appendingPathComponent("bin/tectonic").path,
                "CLUTCH_TECTONIC_SEED": resources.appendingPathComponent("tectonic-cache").path,
                "TECTONIC_CACHE_DIR": data.appendingPathComponent("tectonic-cache").path,
                "CLUTCH_EMBEDDING_DIR": resources.appendingPathComponent("embedding/all-MiniLM-L6-v2").path,
                "PYTHONDONTWRITEBYTECODE": "1",  // the app bundle is read-only
                "PYTHONNOUSERSITE": "1",         // never pick up the user's own packages
            ]
        )
    }

    private static var development: Runtime {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = ProcessInfo.processInfo.environment["CLUTCH_BACKEND_DIR"].map { URL(fileURLWithPath: $0) }
            ?? repo.appendingPathComponent("backend")
        let tectonic = repo.appendingPathComponent("build/bin/tectonic")
        return Runtime(
            isBundled: false,
            sourceDirectory: source,
            python: source.appendingPathComponent(".venv/bin/python"),
            environment: FileManager.default.isExecutableFile(atPath: tectonic.path) ? ["CLUTCH_TECTONIC": tectonic.path] : [:]
        )
    }
}
