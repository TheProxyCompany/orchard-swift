import Foundation

/// Process management utilities for PIE lifecycle

// MARK: - PID Management

/// Check if a process with the given PID is alive
public func pidIsAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    // kill(pid, 0) checks if process exists without sending a signal
    return kill(pid, 0) == 0 || errno == EPERM
}

/// Read PID from a file
public func readPidFile(_ path: URL) -> Int32? {
    guard let content = try? String(contentsOf: path, encoding: .utf8) else {
        return nil
    }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = Int32(trimmed), pid > 0 else {
        return nil
    }
    return pid
}

/// Write PID to a file
public func writePidFile(_ path: URL, pid: Int32) throws {
    try "\(pid)\n".write(to: path, atomically: true, encoding: .utf8)
}

/// Read reference PIDs from a JSON file
public func readRefPids(_ path: URL) -> [Int32] {
    guard FileManager.default.fileExists(atPath: path.path),
          let content = try? String(contentsOf: path, encoding: .utf8),
          !content.isEmpty,
          let data = content.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
        return []
    }

    return json.compactMap { entry -> Int32? in
        if let intValue = entry as? Int, intValue > 0 {
            return Int32(intValue)
        }
        return nil
    }
}

/// Write reference PIDs to a JSON file
public func writeRefPids(_ path: URL, pids: [Int32]) throws {
    let unique = Array(Set(pids.filter { $0 > 0 }))

    if unique.isEmpty {
        try? FileManager.default.removeItem(at: path)
        return
    }

    let json = try JSONSerialization.data(withJSONObject: unique.map { Int($0) })
    let tmpPath = path.deletingLastPathComponent().appendingPathComponent(path.lastPathComponent + ".tmp")
    try json.write(to: tmpPath)
    try FileManager.default.moveItem(at: tmpPath, to: path)
}

/// Filter PIDs to only those that are still alive
public func filterAlivePids(_ pids: [Int32]) -> [Int32] {
    var alive: [Int32] = []
    var seen = Set<Int32>()
    for pid in pids {
        guard !seen.contains(pid), pidIsAlive(pid) else { continue }
        alive.append(pid)
        seen.insert(pid)
    }
    return alive
}

// MARK: - Engine Process Control

/// Stop an engine process gracefully, escalating signals if needed
/// Returns true if the process stopped successfully
public func stopEngineProcess(pid: Int32, timeout: TimeInterval = 15.0) -> Bool {
    guard pidIsAlive(pid) else { return true }

    // Try SIGINT first
    if kill(pid, SIGINT) != 0 {
        return !pidIsAlive(pid)
    }

    // Wait for graceful shutdown
    if waitForExit(pid: pid, timeout: timeout) {
        return true
    }

    // Escalate to SIGTERM
    if kill(pid, SIGTERM) != 0 {
        return !pidIsAlive(pid)
    }

    if waitForExit(pid: pid, timeout: timeout) {
        return true
    }

    // Final escalation to SIGKILL
    _ = kill(pid, SIGKILL)
    return !pidIsAlive(pid)
}

/// Wait for a process to exit
public func waitForExit(pid: Int32, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            return true
        }
        if !pidIsAlive(pid) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    return !pidIsAlive(pid)
}

/// Reap a zombie process
public func reapEngineProcess(pid: Int32) {
    var status: Int32 = 0
    while true {
        let result = waitpid(pid, &status, 0)
        if result == pid || result == -1 {
            break
        }
    }
}

// MARK: - File Lock

/// A simple file-based lock for cross-process coordination
public class FileLock {
    private let path: URL
    private var fileDescriptor: Int32 = -1
    private let timeout: TimeInterval

    public init(path: URL, timeout: TimeInterval = 30.0) {
        self.path = path
        self.timeout = timeout
    }

    deinit {
        unlock()
    }

    /// Acquire the lock, blocking until acquired or timeout
    public func lock() throws {
        let fd = open(path.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw FileLockError.openFailed(errno)
        }

        fileDescriptor = fd

        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        close(fd)
        fileDescriptor = -1
        throw FileLockError.timeout
    }

    /// Release the lock
    public func unlock() {
        if fileDescriptor >= 0 {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    /// Execute a closure while holding the lock
    public func withLock<T>(_ body: () throws -> T) throws -> T {
        try lock()
        defer { unlock() }
        return try body()
    }
}

public enum FileLockError: Error {
    case openFailed(Int32)
    case timeout
}
