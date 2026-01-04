import Foundation

// MARK: - Telemetry Types

/// Engine health metrics.
public struct EngineHealth: Codable, Sendable {
    public let snapshotVersion: UInt64
    public let uptimeNs: UInt64
    public let monotonicTimestampNs: UInt64
    public let pid: UInt32
    public let activeRuntimes: UInt32
    public let activeRequests: UInt32
    public let cpuUsagePercent: Float
    public let systemWattage: Float
    public let systemTemperature: Float
    public let shuttingDown: Bool
    public let healthMessage: String

    private enum CodingKeys: String, CodingKey {
        case snapshotVersion = "snapshot_version"
        case uptimeNs = "uptime_ns"
        case monotonicTimestampNs = "monotonic_timestamp_ns"
        case pid
        case activeRuntimes = "active_runtimes"
        case activeRequests = "active_requests"
        case cpuUsagePercent = "cpu_usage_percent"
        case systemWattage = "system_wattage"
        case systemTemperature = "system_temperature"
        case shuttingDown = "shutting_down"
        case healthMessage = "health_message"
    }
}

/// Queue depth metrics.
public struct QueueTelemetry: Codable, Sendable {
    public let requestSlotsUsed: UInt32
    public let requestSlotsCapacity: UInt32
    public let responseSlotsUsed: UInt32
    public let responseSlotsCapacity: UInt32
    public let rawRequestQueueDepth: UInt32
    public let processedSequenceQueueDepth: UInt32
    public let postprocessorBacklog: UInt32
    public let pendingManagementCommands: UInt32

    private enum CodingKeys: String, CodingKey {
        case requestSlotsUsed = "request_slots_used"
        case requestSlotsCapacity = "request_slots_capacity"
        case responseSlotsUsed = "response_slots_used"
        case responseSlotsCapacity = "response_slots_capacity"
        case rawRequestQueueDepth = "raw_request_queue_depth"
        case processedSequenceQueueDepth = "processed_sequence_queue_depth"
        case postprocessorBacklog = "postprocessor_backlog"
        case pendingManagementCommands = "pending_management_commands"
    }
}

/// GPU memory metrics.
public struct MemoryTelemetry: Codable, Sendable {
    public let gpuTotalBytes: UInt64
    public let gpuReservedBytes: UInt64
    public let kvCachePagesTotal: UInt64
    public let kvCachePagesUsed: UInt64
    public let promptCachePages: UInt64
    public let promptCacheEvictions: UInt64

    private enum CodingKeys: String, CodingKey {
        case gpuTotalBytes = "gpu_total_bytes"
        case gpuReservedBytes = "gpu_reserved_bytes"
        case kvCachePagesTotal = "kv_cache_pages_total"
        case kvCachePagesUsed = "kv_cache_pages_used"
        case promptCachePages = "prompt_cache_pages"
        case promptCacheEvictions = "prompt_cache_evictions"
    }

    /// GPU memory utilization as a percentage (0.0 - 1.0)
    public var gpuUtilization: Double {
        guard gpuTotalBytes > 0 else { return 0 }
        return Double(gpuReservedBytes) / Double(gpuTotalBytes)
    }
}

/// Per-model runtime metrics.
public struct ModelRuntimeTelemetry: Codable, Sendable {
    public let requestedId: String
    public let canonicalId: String
    public let loadState: String
    public let runtimeActive: Bool
    public let waitingSequences: UInt32
    public let runningSequences: UInt32
    public let overflowBuffer: UInt32
    public let tokensPerSecond: Float
    public let avgStepLatencyMs: Float

    private enum CodingKeys: String, CodingKey {
        case requestedId = "requested_id"
        case canonicalId = "canonical_id"
        case loadState = "load_state"
        case runtimeActive = "runtime_active"
        case waitingSequences = "waiting_sequences"
        case runningSequences = "running_sequences"
        case overflowBuffer = "overflow_buffer"
        case tokensPerSecond = "tokens_per_second"
        case avgStepLatencyMs = "avg_step_latency_ms"
    }
}

/// Complete telemetry snapshot from PIE.
public struct TelemetrySnapshot: Codable, Sendable {
    public let version: UInt64
    public let health: EngineHealth
    public let queues: QueueTelemetry
    public let memory: MemoryTelemetry
    public let models: [ModelRuntimeTelemetry]

    /// Aggregate tokens per second across all active models.
    public var totalTokensPerSecond: Float {
        models.reduce(0) { $0 + $1.tokensPerSecond }
    }
}

// MARK: - Telemetry Subscriber

/// Errors that can occur during telemetry subscription.
public enum TelemetryError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case subscriptionFailed(String)
    case decodingFailed(String)

    public var description: String {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .subscriptionFailed(let msg): return "Subscription failed: \(msg)"
        case .decodingFailed(let msg): return "Decoding failed: \(msg)"
        }
    }
}

/// Subscribes to PIE telemetry events.
///
/// Usage:
/// ```swift
/// let telemetry = try OrchardTelemetry()
///
/// for await snapshot in telemetry.snapshots {
///     updateHUD(
///         tokensPerSecond: snapshot.totalTokensPerSecond,
///         gpuUtilization: snapshot.memory.gpuUtilization,
///         powerWatts: snapshot.health.systemWattage
///     )
/// }
/// ```
public final class OrchardTelemetry: @unchecked Sendable {
    private let socket: SubSocket
    private let telemetryTopic: Data
    private var isRunning = true

    /// Create a new telemetry subscriber.
    ///
    /// - Parameter dialAttempts: Number of connection attempts (default: 50)
    /// - Throws: `TelemetryError.connectionFailed` if unable to connect to PIE
    public init(dialAttempts: Int = 50) throws {
        do {
            socket = try SubSocket()
            try socket.dial(IPCEndpoints.responseURL, attempts: dialAttempts)
        } catch {
            throw TelemetryError.connectionFailed(error.localizedDescription)
        }

        // Subscribe to telemetry events: __PIE_EVENT__:telemetry
        telemetryTopic = IPCEndpoints.eventTopicPrefix + Data("telemetry".utf8)
        do {
            try socket.subscribe(telemetryTopic)
        } catch {
            socket.close()
            throw TelemetryError.subscriptionFailed(error.localizedDescription)
        }
    }

    deinit {
        close()
    }

    /// Close the telemetry connection.
    public func close() {
        isRunning = false
        socket.close()
    }

    /// Async stream of telemetry snapshots.
    ///
    /// Yields a new snapshot each time PIE publishes telemetry (typically every 100ms).
    public var snapshots: AsyncStream<TelemetrySnapshot> {
        AsyncStream { continuation in
            Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                while self.isRunning {
                    do {
                        let data = try self.socket.receive(timeout: 1.0)
                        if let snapshot = self.parseTelemetry(data) {
                            continuation.yield(snapshot)
                        }
                    } catch SocketError.timeout {
                        // Normal timeout, continue polling
                        continue
                    } catch {
                        // Connection lost or socket closed
                        break
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Parse telemetry event data.
    ///
    /// Event format: `<topic>\0<json_payload>`
    private func parseTelemetry(_ data: Data) -> TelemetrySnapshot? {
        // Find null separator between topic and payload
        guard let nullIndex = data.firstIndex(of: 0) else {
            return nil
        }

        // Extract JSON payload after null separator
        let jsonData = data[(nullIndex + 1)...]

        // Decode snapshot
        do {
            return try JSONDecoder().decode(TelemetrySnapshot.self, from: Data(jsonData))
        } catch {
            // Silently ignore malformed telemetry
            return nil
        }
    }

    /// Get the last telemetry snapshot (blocking, with timeout).
    ///
    /// - Parameter timeout: Maximum time to wait
    /// - Returns: The next telemetry snapshot, or nil if timeout
    public func nextSnapshot(timeout: TimeInterval = 5.0) -> TelemetrySnapshot? {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline && isRunning {
            do {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return nil }

                let data = try socket.receive(timeout: min(remaining, 1.0))
                if let snapshot = parseTelemetry(data) {
                    return snapshot
                }
            } catch SocketError.timeout {
                continue
            } catch {
                return nil
            }
        }
        return nil
    }
}
