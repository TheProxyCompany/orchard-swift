import Foundation

/// Global singleton context for the inference engine.
/// Holds per-process state including IPC components and model registry.
public final class GlobalContext: @unchecked Sendable {
    /// Singleton instance
    public static let shared = GlobalContext()

    /// Lock for thread-safe access
    private let lock = NSLock()

    /// IPC state container
    public private(set) var ipcState: IPCState?

    /// Model registry
    public private(set) var modelRegistry: ModelRegistry?

    /// Response listener thread
    public private(set) var dispatcherThread: Thread?

    /// Whether the context has been initialized
    public private(set) var initialized: Bool = false

    /// Reference count for active InferenceEngine instances
    public private(set) var refCount: Int = 0

    /// Last received telemetry payload
    public var lastTelemetry: [String: Any]?

    private init() {}

    // MARK: - Thread-safe access

    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public func incrementRefCount() {
        lock.lock()
        defer { lock.unlock() }
        refCount += 1
    }

    public func decrementRefCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        if refCount > 0 {
            refCount -= 1
        }
        return refCount
    }

    public func setInitialized(
        ipcState: IPCState,
        modelRegistry: ModelRegistry,
        dispatcherThread: Thread?
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.ipcState = ipcState
        self.modelRegistry = modelRegistry
        self.dispatcherThread = dispatcherThread
        self.initialized = true
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }

        if let thread = dispatcherThread, thread.isExecuting {
            thread.cancel()
        }

        ipcState?.disconnect()

        dispatcherThread = nil
        ipcState = nil
        modelRegistry = nil
        initialized = false
        lastTelemetry = nil
    }
}
