import Foundation

/// Paths to engine-related files
public struct EnginePaths {
    public let cacheDir: URL
    public let readyFile: URL
    public let pidFile: URL
    public let refsFile: URL
    public let lockFile: URL
    public let clientLogFile: URL
    public let engineLogFile: URL

    public init(
        cacheDir: URL,
        readyFile: URL,
        pidFile: URL,
        refsFile: URL,
        lockFile: URL,
        clientLogFile: URL,
        engineLogFile: URL
    ) {
        self.cacheDir = cacheDir
        self.readyFile = readyFile
        self.pidFile = pidFile
        self.refsFile = refsFile
        self.lockFile = lockFile
        self.clientLogFile = clientLogFile
        self.engineLogFile = engineLogFile
    }
}

/// Gets the cache root directory for Orchard files
public func cacheRoot() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let macCache = home.appendingPathComponent("Library/Caches")
    let base = FileManager.default.fileExists(atPath: macCache.path) ? macCache : home.appendingPathComponent(".cache")
    let target = base.appendingPathComponent("com.theproxycompany")

    try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    return target
}

/// Gets the engine file paths, optionally with custom log paths
public func getEngineFilePaths(
    clientLogFile: URL? = nil,
    engineLogFile: URL? = nil
) -> EnginePaths {
    let cacheDir = cacheRoot()

    let resolvedClientLog = clientLogFile ?? cacheDir.appendingPathComponent("client.log")
    let resolvedEngineLog = engineLogFile ?? cacheDir.appendingPathComponent("engine.log")

    // Ensure log directories exist
    try? FileManager.default.createDirectory(
        at: resolvedClientLog.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try? FileManager.default.createDirectory(
        at: resolvedEngineLog.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    return EnginePaths(
        cacheDir: cacheDir,
        readyFile: cacheDir.appendingPathComponent("engine.ready"),
        pidFile: cacheDir.appendingPathComponent("engine.pid"),
        refsFile: cacheDir.appendingPathComponent("engine.refs"),
        lockFile: cacheDir.appendingPathComponent("engine.lock"),
        clientLogFile: resolvedClientLog,
        engineLogFile: resolvedEngineLog
    )
}
