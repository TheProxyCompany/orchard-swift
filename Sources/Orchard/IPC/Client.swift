import Foundation

/// Response delta from PIE
public struct ResponseDelta: Sendable {
    public let requestId: UInt64
    public let content: String?
    public let isFinalDelta: Bool
    public let finishReason: String?
    public let error: String?

    public init(from json: [String: Any]) {
        self.requestId = (json["request_id"] as? UInt64) ?? 0
        self.content = json["content"] as? String
        self.isFinalDelta = (json["is_final_delta"] as? Bool) ?? false
        self.finishReason = json["finish_reason"] as? String
        self.error = json["error"] as? String
    }
}

/// IPC client for communicating with PIE
public actor IPCClient {
    private var requestSocket: PushSocket?
    private var responseSocket: SubSocket?
    private var managementSocket: ReqSocket?

    private var responseChannelId: UInt64 = 0
    private var requestIdCounter: UInt64 = 0

    private var activeRequests: [UInt64: AsyncStream<ResponseDelta>.Continuation] = [:]
    private var listenerTask: Task<Void, Never>?

    public init() {}

    /// Connect to PIE IPC endpoints
    public func connect() async throws {
        // Generate unique channel ID for this client
        responseChannelId = UInt64.random(in: 1...UInt64.max)

        // Initialize sockets
        requestSocket = try PushSocket()
        responseSocket = try SubSocket()
        managementSocket = try ReqSocket()

        // Connect to endpoints
        try requestSocket?.dial(IPCEndpoints.requestURL)
        try responseSocket?.dial(IPCEndpoints.responseURL)
        try managementSocket?.dial(IPCEndpoints.managementURL)

        // Subscribe to our response channel and global events
        let responseTopic = "resp:\(String(responseChannelId, radix: 16)):"
        try responseSocket?.subscribe(responseTopic)
        try responseSocket?.subscribe(IPCEndpoints.eventTopicPrefix)

        // Start response listener
        listenerTask = Task { [weak self] in
            await self?.runResponseListener()
        }
    }

    /// Disconnect from PIE
    public func disconnect() {
        listenerTask?.cancel()
        listenerTask = nil

        requestSocket?.close()
        responseSocket?.close()
        managementSocket?.close()

        requestSocket = nil
        responseSocket = nil
        managementSocket = nil

        // Fail all active requests
        for (_, continuation) in activeRequests {
            continuation.finish()
        }
        activeRequests.removeAll()
    }

    /// Get the next request ID
    public func nextRequestId() -> UInt64 {
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

        // Create response stream and register it
        var streamContinuation: AsyncStream<ResponseDelta>.Continuation!
        let stream = AsyncStream<ResponseDelta> { continuation in
            streamContinuation = continuation
        }
        activeRequests[requestId] = streamContinuation

        streamContinuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.unregisterRequest(requestId: requestId)
            }
        }

        // Send request
        try socket.send(payload)

        return stream
    }

    /// Send a management command (e.g., load_model)
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
        activeRequests.removeValue(forKey: requestId)
    }

    private func runResponseListener() async {
        guard let socket = responseSocket else { return }

        let responseTopic = "resp:\(String(responseChannelId, radix: 16)):".data(using: .utf8)!

        while !Task.isCancelled {
            do {
                let data = try socket.receive(timeout: 1.0)

                // Check if it's a response for us
                if data.starts(with: responseTopic) {
                    let jsonData = data.dropFirst(responseTopic.count)
                    if let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        let delta = ResponseDelta(from: json)

                        if let continuation = activeRequests[delta.requestId] {
                            continuation.yield(delta)

                            if delta.isFinalDelta {
                                continuation.finish()
                                activeRequests.removeValue(forKey: delta.requestId)
                            }
                        }
                    }
                }
                // Could also handle event topic here
            } catch SocketError.timeout {
                // Normal - just continue polling
                continue
            } catch {
                // Log and continue
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
