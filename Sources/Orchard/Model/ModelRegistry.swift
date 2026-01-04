import Foundation

/// State machine for model loading
public enum ModelLoadState: String, Sendable {
    case idle = "IDLE"
    case downloading = "DOWNLOADING"
    case activating = "ACTIVATING"
    case loading = "LOADING"
    case ready = "READY"
    case failed = "FAILED"
}

/// Information about a loaded model
public struct ModelInfo: Sendable {
    public let modelId: String
    public let modelPath: String
    public let formatter: ChatFormatter
    public var capabilities: [String: [Int]]?

    public init(modelId: String, modelPath: String, formatter: ChatFormatter, capabilities: [String: [Int]]? = nil) {
        self.modelId = modelId
        self.modelPath = modelPath
        self.formatter = formatter
        self.capabilities = capabilities
    }
}

/// Entry tracking a model's load state
final class ModelEntry: @unchecked Sendable {
    var state: ModelLoadState = .idle
    var info: ModelInfo?
    var error: String?
    var resolved: ResolvedModel?
    var bytesDownloaded: Int?
    var bytesTotal: Int?

    private var activationContinuation: CheckedContinuation<Void, Error>?
    private let entryLock = NSLock()

    func setActivationContinuation(_ continuation: CheckedContinuation<Void, Error>?) {
        entryLock.lock()
        defer { entryLock.unlock() }
        activationContinuation = continuation
    }

    func resumeActivation(error: Error? = nil) {
        entryLock.lock()
        let continuation = activationContinuation
        activationContinuation = nil
        entryLock.unlock()

        if let error = error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}

/// Registry for tracking and managing loaded models
public final class ModelRegistry: @unchecked Sendable {
    private var entries: [String: ModelEntry] = [:]
    private let registryLock = NSLock()
    private let resolver = ModelResolver()
    private var aliasCache: [String: String] = [:]
    private weak var ipcState: IPCState?

    public init(ipcState: IPCState) {
        self.ipcState = ipcState
    }

    // MARK: - Thread-safe accessors

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        registryLock.lock()
        defer { registryLock.unlock() }
        return try body()
    }

    // MARK: - Public API

    /// Ensure a model is loaded and ready
    public func ensureLoaded(_ requestedModelId: String, timeout: TimeInterval? = nil) async throws -> ModelInfo {
        let (_, canonicalId) = try scheduleModelSync(requestedModelId)

        // Wait for local readiness
        let (loadState, info, error) = awaitModelSync(canonicalId)

        if loadState == .failed || info == nil {
            throw ModelRegistryError.loadFailed(error ?? "Model '\(canonicalId)' failed to load")
        }

        if loadState == .ready {
            return info!
        }

        // Activation phase (IPC load command)
        let entry = getEntry(canonicalId)

        if entry?.state == .ready, let info = entry?.info {
            return info
        }

        // Send load command and wait for activation
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            entry?.setActivationContinuation(continuation)
            entry?.state = .activating

            Task {
                do {
                    try await self.sendLoadModelCommand(
                        requestedId: requestedModelId,
                        canonicalId: canonicalId,
                        info: info!
                    )
                } catch {
                    entry?.state = .failed
                    entry?.error = error.localizedDescription
                    entry?.resumeActivation(error: error)
                }
            }
        }

        guard let readyInfo = getIfReady(canonicalId) else {
            throw ModelRegistryError.activationFailed(canonicalId)
        }

        return readyInfo
    }

    /// Synchronously ensure a model is ready (blocking)
    public func ensureReadySync(_ requestedModelId: String, timeout: TimeInterval? = nil) throws -> ModelInfo {
        // First try to schedule and see if it's already ready
        let (state, canonicalId) = try scheduleModelSync(requestedModelId)

        if state == .ready, let info = getIfReady(canonicalId) {
            return info
        }

        if state == .failed {
            let (_, _, error) = awaitModelSync(canonicalId)
            throw ModelRegistryError.loadFailed(error ?? "Model '\(canonicalId)' failed to load")
        }

        // For loading state, return the info if available
        let (_, info, error) = awaitModelSync(canonicalId)
        if let info = info {
            return info
        }

        throw ModelRegistryError.loadFailed(error ?? "Model '\(canonicalId)' not ready")
    }

    /// Schedule a model for loading (synchronous version for async compatibility)
    public func scheduleModelSync(_ requestedModelId: String, forceReload: Bool = false) throws -> (ModelLoadState, String) {
        let resolved = try resolver.resolve(requestedModelId)
        let canonicalId = resolved.canonicalId

        return withLock {
            aliasCache[requestedModelId.lowercased()] = canonicalId
            if aliasCache[canonicalId.lowercased()] == nil {
                aliasCache[canonicalId.lowercased()] = canonicalId
            }

            var entry = entries[canonicalId]
            if entry == nil {
                entry = ModelEntry()
                entries[canonicalId] = entry
            }

            guard let entry = entry else {
                return (.failed, canonicalId)
            }

            if entry.state == .ready && !forceReload {
                return (.ready, canonicalId)
            }

            if [.loading, .downloading, .activating].contains(entry.state) && !forceReload {
                return (entry.state, canonicalId)
            }

            if entry.state == .failed && !forceReload {
                return (.failed, canonicalId)
            }

            // Reset entry
            entry.error = nil
            entry.info = nil
            entry.resolved = resolved
            entry.bytesDownloaded = nil
            entry.bytesTotal = nil

            // If model is already local, build formatter immediately
            if resolved.source == "local" || resolved.source == "hf_cache" {
                do {
                    let formatter = try ChatFormatter(modelPath: resolved.modelPath.path)
                    let info = ModelInfo(
                        modelId: resolved.canonicalId,
                        modelPath: resolved.modelPath.path,
                        formatter: formatter
                    )
                    entry.info = info
                    entry.state = .loading
                    return (.loading, canonicalId)
                } catch {
                    entry.error = error.localizedDescription
                    entry.state = .failed
                    return (.failed, canonicalId)
                }
            }

            // Model needs download - not supported in Swift yet
            entry.state = .failed
            entry.error = "Automatic model download not supported. Use: huggingface-cli download \(requestedModelId)"
            return (.failed, canonicalId)
        }
    }

    /// Wait for a model to finish loading (synchronous)
    public func awaitModelSync(_ modelId: String) -> (ModelLoadState, ModelInfo?, String?) {
        guard let canonicalId = canonicalize(modelId) else {
            return (.idle, nil, "Model '\(modelId)' has not been scheduled")
        }

        let entry = getEntry(canonicalId)

        // For now just return current state (full async waiting would require events)
        if let entry = entry {
            return (entry.state, entry.info, entry.error)
        }

        return (.idle, nil, nil)
    }

    /// Get model info if it's ready
    public func getIfReady(_ modelId: String) -> ModelInfo? {
        guard let canonicalId = canonicalize(modelId) else { return nil }
        return withLock {
            guard let entry = entries[canonicalId], entry.state == .ready else {
                return nil
            }
            return entry.info
        }
    }

    /// Get model info (loading if needed)
    public func getInfo(_ modelId: String) async throws -> ModelInfo {
        let cached: ModelInfo? = withLock {
            if let canonicalId = aliasCache[modelId],
               let entry = entries[canonicalId],
               let info = entry.info {
                return info
            }
            return nil
        }

        if let cached = cached {
            return cached
        }

        return try await ensureLoaded(modelId)
    }

    /// List all loaded models
    public func listModels() -> [[String: Any]] {
        return withLock {
            var catalog: [[String: Any]] = []
            for (canonicalId, entry) in entries {
                guard let resolved = entry.resolved else { continue }
                let payload: [String: Any] = [
                    "canonical_id": canonicalId,
                    "model_path": resolved.modelPath.path,
                    "source": resolved.source,
                    "state": entry.state.rawValue
                ]
                catalog.append(payload)
            }
            return catalog
        }
    }

    /// Resolve a model ID to a path
    public func resolve(_ modelId: String) throws -> ResolvedModel {
        try resolver.resolve(modelId)
    }

    /// Update capabilities for a model
    public func updateCapabilities(_ modelId: String, capabilities: [String: Any]?) {
        guard let capabilities = capabilities else { return }

        let canonicalId = canonicalize(modelId) ?? modelId

        withLock {
            guard let entry = entries[canonicalId], var info = entry.info else {
                return
            }

            var normalized: [String: [Int]] = [:]
            for (name, value) in capabilities {
                if let list = value as? [Int] {
                    normalized[name] = list
                } else if let single = value as? Int {
                    normalized[name] = [single]
                }
            }

            info.capabilities = normalized
            entry.info = info
        }
    }

    /// Handle model_loaded event from engine
    public func handleModelLoaded(payload: [String: Any]) {
        guard let modelId = payload["model_id"] as? String else { return }

        if let capabilities = payload["capabilities"] as? [String: Any] {
            updateCapabilities(modelId, capabilities: capabilities)
        }

        let entry: ModelEntry? = withLock {
            guard let entry = entries[modelId] else {
                return nil
            }

            if entry.state != .activating {
                return nil
            }

            entry.state = .ready
            return entry
        }

        entry?.resumeActivation()
    }

    // MARK: - Private

    private func canonicalize(_ modelId: String) -> String? {
        return withLock {
            if entries[modelId] != nil {
                return modelId
            }
            return aliasCache[modelId.lowercased()]
        }
    }

    private func getEntry(_ modelId: String) -> ModelEntry? {
        return withLock {
            entries[modelId]
        }
    }

    private func sendLoadModelCommand(requestedId: String, canonicalId: String, info: ModelInfo) async throws {
        guard let ipcState = ipcState else {
            throw ModelRegistryError.ipcNotInitialized
        }

        let command: [String: Any] = [
            "type": "load_model",
            "requested_id": requestedId,
            "canonical_id": canonicalId,
            "model_path": info.modelPath,
            "wait_for_completion": false
        ]

        let response = try await ipcState.sendManagementCommandAsync(command)

        let status = response["status"] as? String
        if status == "ok" {
            // Immediate completion
            if let data = response["data"] as? [String: Any],
               let loadModel = data["load_model"] as? [String: Any],
               let capabilities = loadModel["capabilities"] as? [String: Any] {
                updateCapabilities(canonicalId, capabilities: capabilities)
            }

            let entry: ModelEntry? = withLock {
                let entry = entries[canonicalId]
                entry?.state = .ready
                return entry
            }
            entry?.resumeActivation()
            return
        }

        if status != "accepted" {
            let message = response["message"] as? String ?? "unknown error"
            throw ModelRegistryError.loadRejected(message)
        }

        // Accepted - wait for model_loaded event (handled by handleModelLoaded)
    }
}

// MARK: - Errors

public enum ModelRegistryError: Error, LocalizedError {
    case loadFailed(String)
    case activationFailed(String)
    case loadRejected(String)
    case ipcNotInitialized
    case internalError

    public var errorDescription: String? {
        switch self {
        case .loadFailed(let reason):
            return "Model load failed: \(reason)"
        case .activationFailed(let modelId):
            return "Model '\(modelId)' failed to activate"
        case .loadRejected(let reason):
            return "Engine rejected model load: \(reason)"
        case .ipcNotInitialized:
            return "IPC state is not initialized"
        case .internalError:
            return "Internal model registry error"
        }
    }
}
