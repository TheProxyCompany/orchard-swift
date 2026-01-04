import Foundation

/// Process-safe manager that launches and reference-counts the orchard engine.
public final class InferenceEngine: @unchecked Sendable {
    private let paths: EnginePaths
    private let startupTimeout: TimeInterval
    private let lock: FileLock
    private let engineBinPath: URL

    private var leaseActive = false
    private var closed = false
    private var launchProcess: Process?

    nonisolated(unsafe) private static var atExitRegistered = false
    private static let engineLock = NSLock()

    /// Create an InferenceEngine instance
    /// - Parameters:
    ///   - clientLogFile: Optional custom path for client logs
    ///   - engineLogFile: Optional custom path for engine logs
    ///   - startupTimeout: Maximum time to wait for engine startup (default: 60s)
    ///   - loadModels: Models to preload on startup
    public init(
        clientLogFile: URL? = nil,
        engineLogFile: URL? = nil,
        startupTimeout: TimeInterval = 60.0,
        loadModels modelsToLoad: [String]? = nil
    ) async throws {
        self.paths = getEngineFilePaths(clientLogFile: clientLogFile, engineLogFile: engineLogFile)
        self.startupTimeout = startupTimeout
        self.lock = FileLock(path: paths.lockFile)

        // Get engine binary path
        let fetcher = EngineFetcher()
        self.engineBinPath = try await fetcher.getEnginePath()

        // Register atexit handler once
        Self.registerAtExit()

        // Acquire lease and initialize
        try acquireLeaseAndInitGlobalContext()

        // Preload models if specified
        if let models = modelsToLoad, !models.isEmpty {
            try await preloadModels(models)
        }
    }

    private static func registerAtExit() {
        engineLock.lock()
        defer { engineLock.unlock() }
        if !atExitRegistered {
            atexit {
                try? InferenceEngine.shutdown()
            }
            atExitRegistered = true
        }
    }

    deinit {
        close()
    }

    // MARK: - Public API

    /// Load multiple models concurrently
    public func preloadModels(_ modelIds: [String]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for modelId in modelIds {
                group.addTask {
                    try await self.loadModel(modelId)
                }
            }
            try await group.waitForAll()
        }
    }

    /// Load a single model
    @discardableResult
    public func loadModel(_ modelId: String) async throws -> ModelInfo {
        guard let registry = GlobalContext.shared.modelRegistry else {
            throw InferenceEngineError.notInitialized
        }
        return try await registry.ensureLoaded(modelId)
    }

    /// Get a client for making inference requests
    public func client(modelId: String? = nil) throws -> OrchardClient {
        guard !closed else {
            throw InferenceEngineError.closed
        }
        guard let ipcState = GlobalContext.shared.ipcState else {
            throw InferenceEngineError.notInitialized
        }
        guard let registry = GlobalContext.shared.modelRegistry else {
            throw InferenceEngineError.notInitialized
        }

        return OrchardClient(ipcState: ipcState, modelRegistry: registry, defaultModelId: modelId)
    }

    /// Get the IPC state
    public func ipcState() throws -> IPCState {
        guard !closed else {
            throw InferenceEngineError.closed
        }
        guard let state = GlobalContext.shared.ipcState else {
            throw InferenceEngineError.notInitialized
        }
        return state
    }

    /// Get the model registry
    public func modelRegistry() throws -> ModelRegistry {
        guard !closed else {
            throw InferenceEngineError.closed
        }
        guard let registry = GlobalContext.shared.modelRegistry else {
            throw InferenceEngineError.notInitialized
        }
        return registry
    }

    /// Close this engine instance
    public func close() {
        guard !closed else { return }

        var releaseProcessLease = false
        if leaseActive {
            let remaining = GlobalContext.shared.decrementRefCount()
            releaseProcessLease = remaining == 0
        }

        defer {
            leaseActive = false
            closed = true
        }

        guard leaseActive && releaseProcessLease else { return }

        do {
            try lock.withLock {
                var refs = readRefPids(paths.refsFile)
                refs = filterAlivePids(refs)
                let currentPid = getpid()
                refs = refs.filter { $0 != currentPid }

                let enginePid = readPidFile(paths.pidFile)
                let engineRunning = enginePid != nil && pidIsAlive(enginePid!)

                // Shutdown global context
                GlobalContext.shared.reset()

                if refs.isEmpty {
                    if engineRunning, let pid = enginePid {
                        try stopEngineLocked(pid: pid)
                    } else {
                        try? FileManager.default.removeItem(at: paths.pidFile)
                        try? FileManager.default.removeItem(at: paths.readyFile)
                    }
                    try? writeRefPids(paths.refsFile, pids: [])
                } else {
                    try? writeRefPids(paths.refsFile, pids: refs)
                }
            }
        } catch {
            // Best effort cleanup
        }
    }

    /// Forcefully stop the shared engine process
    @discardableResult
    public static func shutdown(timeout: TimeInterval = 15.0) throws -> Bool {
        let paths = getEngineFilePaths()
        let lock = FileLock(path: paths.lockFile)

        return try lock.withLock {
            guard let pid = readPidFile(paths.pidFile), pidIsAlive(pid) else {
                try? FileManager.default.removeItem(at: paths.pidFile)
                try? FileManager.default.removeItem(at: paths.readyFile)
                try? FileManager.default.removeItem(at: paths.refsFile)
                return true
            }

            let success = stopEngineProcess(pid: pid, timeout: timeout)

            if success {
                try? FileManager.default.removeItem(at: paths.pidFile)
                try? FileManager.default.removeItem(at: paths.readyFile)
                try? FileManager.default.removeItem(at: paths.refsFile)
                reapEngineProcess(pid: pid)
                return true
            }

            throw InferenceEngineError.shutdownFailed(Int(pid))
        }
    }

    // MARK: - Private

    private func acquireLeaseAndInitGlobalContext() throws {
        guard !closed, !leaseActive else { return }

        try lock.withLock {
            var refs = readRefPids(paths.refsFile)
            refs = filterAlivePids(refs)

            var enginePid = readPidFile(paths.pidFile)
            let engineRunning = enginePid != nil && pidIsAlive(enginePid!)

            if !engineRunning {
                enginePid = nil
                try? FileManager.default.removeItem(at: paths.pidFile)
                try? FileManager.default.removeItem(at: paths.readyFile)
            }

            if !engineRunning && refs.isEmpty {
                try launchEngineLocked()
                enginePid = try waitForEngineReady()
            }

            let currentPid = getpid()
            if !refs.contains(currentPid) {
                refs.append(currentPid)
            }

            try writeRefPids(paths.refsFile, pids: refs)
        }

        do {
            try initializeGlobalContext()
        } catch {
            // Roll back PID registration
            try? lock.withLock {
                var refs = readRefPids(paths.refsFile)
                refs = filterAlivePids(refs).filter { $0 != getpid() }
                try? writeRefPids(paths.refsFile, pids: refs)
            }
            throw error
        }

        leaseActive = true
    }

    private func launchEngineLocked() throws {
        try FileManager.default.createDirectory(at: paths.cacheDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: paths.readyFile)
        try? FileManager.default.removeItem(at: paths.pidFile)

        let process = Process()
        process.executableURL = engineBinPath

        let logHandle = try FileHandle(forWritingTo: paths.engineLogFile)
        process.standardOutput = logHandle
        process.standardError = logHandle

        try process.run()
        launchProcess = process
    }

    private func waitForEngineReady() throws -> Int32 {
        // Wait for telemetry heartbeat from engine
        let tempSocket = try SubSocket()
        let telemetryTopic = "__PIE_EVENT__:telemetry"
        try tempSocket.subscribe(telemetryTopic)
        try tempSocket.dial(IPCEndpoints.responseURL)

        defer { tempSocket.close() }

        let deadline = Date().addingTimeInterval(startupTimeout)

        while Date() < deadline {
            // Check if process is still alive
            if let process = launchProcess, !process.isRunning {
                throw InferenceEngineError.startupFailed("Engine process exited before signaling readiness")
            }

            do {
                let msg = try tempSocket.receive(timeout: 0.25)

                // Parse: telemetryTopic\0{json}
                guard let nullIndex = msg.firstIndex(of: 0) else { continue }
                let jsonBody = msg[(nullIndex + 1)...]

                guard let payload = try? JSONSerialization.jsonObject(with: Data(jsonBody)) as? [String: Any],
                      let health = payload["health"] as? [String: Any],
                      let pid = health["pid"] as? Int, pid > 0 else {
                    continue
                }

                try writePidFile(paths.pidFile, pid: Int32(pid))
                return Int32(pid)
            } catch SocketError.timeout {
                continue
            }
        }

        throw InferenceEngineError.startupTimeout
    }

    private func stopEngineLocked(pid: Int32) throws {
        guard pidIsAlive(pid) else {
            try? FileManager.default.removeItem(at: paths.pidFile)
            try? FileManager.default.removeItem(at: paths.readyFile)
            return
        }

        guard stopEngineProcess(pid: pid, timeout: 5.0) else {
            throw InferenceEngineError.shutdownFailed(Int(pid))
        }

        reapEngineProcess(pid: pid)
        try? FileManager.default.removeItem(at: paths.pidFile)
        try? FileManager.default.removeItem(at: paths.readyFile)
    }

    private func initializeGlobalContext() throws {
        GlobalContext.shared.incrementRefCount()

        guard !GlobalContext.shared.initialized else { return }

        let ipcState = IPCState(globalContext: GlobalContext.shared)
        try ipcState.connect()

        let modelRegistry = ModelRegistry(ipcState: ipcState)

        GlobalContext.shared.setInitialized(
            ipcState: ipcState,
            modelRegistry: modelRegistry,
            dispatcherThread: nil // Listener is managed by IPCState
        )
    }
}

// MARK: - Errors

public enum InferenceEngineError: Error, LocalizedError {
    case notInitialized
    case closed
    case startupTimeout
    case startupFailed(String)
    case shutdownFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Inference engine is not initialized"
        case .closed:
            return "Inference engine has been closed"
        case .startupTimeout:
            return "Timed out waiting for engine to start"
        case .startupFailed(let reason):
            return "Engine startup failed: \(reason)"
        case .shutdownFailed(let pid):
            return "Failed to stop engine process \(pid)"
        }
    }
}
