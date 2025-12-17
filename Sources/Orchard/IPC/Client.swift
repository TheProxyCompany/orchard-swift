import Foundation
import nng

/// Initialize NNG library once
private let nngInitialized: Bool = {
    let rv = nng_init(nil)
    if rv != NNG_OK {
        fatalError("Failed to initialize NNG: \(rv)")
    }
    return true
}()

/// Response delta from PIE
public struct ResponseDelta: Sendable {
    public let requestId: UInt64
    public let content: String?
    public let isFinalDelta: Bool
    public let finishReason: String?
    public let error: String?

    public init(from json: [String: Any]) {
        self.requestId = (json["request_id"] as? UInt64)
            ?? (json["request_id"] as? Int).map { UInt64($0) }
            ?? 0
        self.content = json["content"] as? String
        self.isFinalDelta = (json["is_final_delta"] as? Bool) ?? false
        self.finishReason = json["finish_reason"] as? String
        self.error = json["error"] as? String
    }
}

/// High-performance IPC client for communicating with PIE
///
/// Uses a lock-based design instead of actors to minimize overhead in the hot path.
/// All socket operations are thread-safe via internal locks.
public final class IPCClient: @unchecked Sendable {
    private var requestSocket: PushSocket?
    private var responseSocket: SubSocket?
    private var managementSocket: ReqSocket?

    private var responseChannelId: UInt64 = 0
    private var requestIdCounter: UInt64 = 0

    /// Lock for protecting shared state
    private let lock = NSLock()

    /// Active request continuations - protected by lock
    private var activeRequests: [UInt64: AsyncStream<ResponseDelta>.Continuation] = [:]

    /// Listener thread
    private var listenerThread: Thread?
    private var shouldStopListener = false

    public init() {}

    deinit {
        disconnect()
    }

    /// Connect to PIE IPC endpoints
    public func connect() throws {
        // Ensure NNG is initialized
        _ = nngInitialized

        // Generate unique channel ID for this client
        responseChannelId = UInt64.random(in: 1...UInt64.max)

        // Create and connect all sockets
        // 1. Push socket (requests)
        requestSocket = try PushSocket()
        try requestSocket?.dial(IPCEndpoints.requestURL)

        // 2. Sub socket (responses) - subscribe BEFORE dial like orchard-py
        responseSocket = try SubSocket()
        let responseTopic = "resp:\(String(responseChannelId, radix: 16)):"
        try responseSocket?.subscribe(responseTopic)
        try responseSocket?.subscribe(IPCEndpoints.eventTopicPrefix)
        try responseSocket?.dial(IPCEndpoints.responseURL)

        // 3. Req socket (management)
        managementSocket = try ReqSocket()
        try managementSocket?.dial(IPCEndpoints.managementURL)

        // Start listener on a dedicated thread - minimal overhead
        shouldStopListener = false
        let thread = Thread { [weak self] in
            self?.runResponseListener()
        }
        thread.name = "orchard-ipc-listener"
        thread.qualityOfService = .userInteractive
        listenerThread = thread
        thread.start()
    }

    /// Disconnect from PIE
    public func disconnect() {
        // Signal listener to stop
        lock.lock()
        shouldStopListener = true
        lock.unlock()

        // Wait for listener thread to finish
        while listenerThread?.isFinished == false {
            Thread.sleep(forTimeInterval: 0.01)
        }
        listenerThread = nil

        // Close sockets
        requestSocket?.close()
        responseSocket?.close()
        managementSocket?.close()
        requestSocket = nil
        responseSocket = nil
        managementSocket = nil

        // Fail all active requests
        lock.lock()
        for (_, continuation) in activeRequests {
            continuation.finish()
        }
        activeRequests.removeAll()
        lock.unlock()
    }

    /// Get the next request ID - lock-free atomic would be better but this is fine
    public func nextRequestId() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        requestIdCounter += 1
        if requestIdCounter >= UInt64.max {
            requestIdCounter = 1
        }
        return requestIdCounter
    }

    /// Send an inference request and receive streaming responses
    public func sendRequest(
        requestId: UInt64,
        modelId: String,
        modelPath: String,
        prompt: String,
        maxTokens: Int = 0,
        temperature: Double = 1.0,
        topP: Double = 1.0,
        stopSequences: [String] = []
    ) throws -> AsyncStream<ResponseDelta> {
        guard let socket = requestSocket else {
            throw IPCError.notConnected
        }

        // Build request payload
        let promptPayload: [String: Any] = [
            "prompt": prompt,
            "max_generated_tokens": maxTokens,
            "sampling_params": [
                "temperature": temperature,
                "top_p": topP,
            ],
            "stop_sequences": stopSequences,
        ]

        let payload = try Serialization.buildRequestPayload(
            requestId: requestId,
            modelId: modelId,
            modelPath: modelPath,
            requestType: .generation,
            responseChannelId: responseChannelId,
            prompts: [promptPayload]
        )

        // Create response stream
        var streamContinuation: AsyncStream<ResponseDelta>.Continuation!
        let stream = AsyncStream<ResponseDelta> { continuation in
            streamContinuation = continuation
        }

        // Register the continuation - minimal lock scope
        lock.lock()
        activeRequests[requestId] = streamContinuation
        lock.unlock()

        streamContinuation.onTermination = { [weak self] _ in
            self?.unregisterRequest(requestId: requestId)
        }

        // Send request - socket is internally thread-safe
        try socket.send(payload)

        return stream
    }

    /// Send a management command (e.g., load_model)
    /// This is synchronous and blocking - appropriate for setup operations
    public func sendManagementCommand(_ command: [String: Any], timeout: TimeInterval = 30.0) throws -> [String: Any] {
        guard let socket = managementSocket else {
            throw IPCError.notConnected
        }

        let data = try JSONSerialization.data(withJSONObject: command)
        let response = try socket.request(data, timeout: timeout)

        guard let json = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw IPCError.invalidResponse
        }

        return json
    }

    // MARK: - Private

    private func unregisterRequest(requestId: UInt64) {
        lock.lock()
        activeRequests.removeValue(forKey: requestId)
        lock.unlock()
    }

    /// Response listener - runs on dedicated thread for minimal latency
    private func runResponseListener() {
        guard let socket = responseSocket else { return }

        let responseTopic = "resp:\(String(responseChannelId, radix: 16)):".data(using: .utf8)!

        while true {
            // Check stop flag
            lock.lock()
            let shouldStop = shouldStopListener
            lock.unlock()
            if shouldStop { break }

            do {
                let data = try socket.receive(timeout: 0.1)

                // Check if it's a response for us
                if data.starts(with: responseTopic) {
                    let jsonData = data.dropFirst(responseTopic.count)
                    if let json = try JSONSerialization.jsonObject(with: Data(jsonData)) as? [String: Any] {
                        let delta = ResponseDelta(from: json)

                        // Route to the appropriate continuation - minimal lock scope
                        lock.lock()
                        let continuation = activeRequests[delta.requestId]
                        lock.unlock()

                        if let continuation = continuation {
                            continuation.yield(delta)

                            if delta.isFinalDelta {
                                continuation.finish()
                                lock.lock()
                                activeRequests.removeValue(forKey: delta.requestId)
                                lock.unlock()
                            }
                        }
                    }
                }
            } catch SocketError.timeout {
                continue
            } catch {
                lock.lock()
                let shouldStop = shouldStopListener
                lock.unlock()
                if shouldStop { break }
                continue
            }
        }
    }
}

/// IPC client errors
public enum IPCError: Error, CustomStringConvertible {
    case notConnected
    case invalidResponse

    public var description: String {
        switch self {
        case .notConnected:
            return "IPC client not connected"
        case .invalidResponse:
            return "Invalid response from PIE"
        }
    }
}
