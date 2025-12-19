import Foundation

/// IPC endpoint definitions for PIE communication.
///
/// These endpoints mirror the Python implementation in orchard-py.
/// PIE uses NNG (nanomsg-next-gen) for high-performance IPC.
public enum IPCEndpoints {

    /// Root directory for IPC socket files.
    public static var ipcRoot: URL {
        if let envRoot = ProcessInfo.processInfo.environment["ORCHARD_IPC_ROOT"] {
            return URL(fileURLWithPath: envRoot).standardizedFileURL
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let macCache = home.appendingPathComponent("Library/Caches")

        let base: URL
        if FileManager.default.fileExists(atPath: macCache.path) {
            base = macCache
        } else {
            base = home.appendingPathComponent(".cache")
        }

        let path = base.appendingPathComponent("com.theproxycompany/ipc")

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

        return path
    }

    /// Endpoint for submitting inference requests to the engine.
    /// Pattern: PUSH/PULL (Many clients PUSH, one engine PULLs)
    public static var requestURL: String {
        "ipc://\(ipcRoot.appendingPathComponent("pie_requests.ipc").path)"
    }

    /// Endpoint for receiving responses and broadcast events from the engine.
    /// Pattern: PUB/SUB (One engine PUBlishes, many clients SUBscribe)
    /// Topics are used to route messages to the correct consumer.
    public static var responseURL: String {
        "ipc://\(ipcRoot.appendingPathComponent("pie_responses.ipc").path)"
    }

    /// Endpoint for synchronous management commands (e.g., load_model).
    /// Pattern: REQ/REP (One client sends a REQ, one engine sends a REP)
    public static var managementURL: String {
        "ipc://\(ipcRoot.appendingPathComponent("pie_management.ipc").path)"
    }

    // MARK: - Topic Prefixes for the PUB/SUB Channel

    /// Topic prefix for response deltas targeted at a specific client.
    /// A client subscribes to responseTopicPrefix + channelIdHex.
    public static let responseTopicPrefix = Data("resp:".utf8)

    /// Topic prefix for global, broadcast events (e.g., engine_ready).
    /// Clients subscribe to this prefix to receive all system-wide notifications.
    public static let eventTopicPrefix = Data("__PIE_EVENT__:".utf8)
}
