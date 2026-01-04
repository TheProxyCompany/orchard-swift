import Foundation
import nng

/// Holds the process-wide state for IPC components
public final class IPCState: @unchecked Sendable {
    /// NNG sockets
    private(set) var requestSocket: PushSocket?
    private(set) var responseSocket: SubSocket?
    private(set) var managementSocket: ReqSocket?

    /// Channel ID for routing responses to this client
    public private(set) var responseChannelId: UInt64 = 0

    /// Topic prefix for responses
    public private(set) var responseTopicPrefix: Data = Data()

    /// Active request queues, keyed by request ID
    private var activeRequestQueues: [UInt64: QueueRegistration] = [:]
    private let queuesLock = NSLock()

    /// Request ID counter
    private var requestIdCounter: UInt64 = 0
    private let idLock = NSLock()

    /// Weak reference to global context
    private weak var globalContext: GlobalContext?

    /// Listener thread
    private var listenerThread: Thread?
    private var shouldStopListener = false
    private let listenerLock = NSLock()

    public init(globalContext: GlobalContext? = nil) {
        self.globalContext = globalContext
    }

    // MARK: - Connection Management

    /// Connect to PIE IPC endpoints
    public func connect() throws {
        // Generate unique channel ID
        responseChannelId = generateResponseChannelId()

        // Create and connect sockets
        requestSocket = try PushSocket()
        try requestSocket?.dial(IPCEndpoints.requestURL)

        responseSocket = try SubSocket()
        let responseTopic = "resp:\(String(responseChannelId, radix: 16)):"
        responseTopicPrefix = Data(responseTopic.utf8)
        try responseSocket?.subscribe(responseTopic)
        try responseSocket?.subscribe(IPCEndpoints.eventTopicPrefix)
        try responseSocket?.dial(IPCEndpoints.responseURL)

        managementSocket = try ReqSocket()
        try managementSocket?.dial(IPCEndpoints.managementURL)

        // Start response listener
        startListener()
    }

    /// Disconnect from PIE
    public func disconnect() {
        stopListener()

        requestSocket?.close()
        responseSocket?.close()
        managementSocket?.close()
        requestSocket = nil
        responseSocket = nil
        managementSocket = nil

        queuesLock.lock()
        for (_, registration) in activeRequestQueues {
            registration.continuation.finish()
        }
        activeRequestQueues.removeAll()
        queuesLock.unlock()
    }

    // MARK: - Request Management

    /// Get the next request ID
    public func nextRequestId() -> UInt64 {
        idLock.lock()
        defer { idLock.unlock() }
        requestIdCounter += 1
        if requestIdCounter >= UInt64.max {
            requestIdCounter = 1
        }
        return requestIdCounter
    }

    /// Register a queue for receiving responses
    public func registerQueue(requestId: UInt64, continuation: AsyncStream<ResponseDelta>.Continuation) {
        queuesLock.lock()
        defer { queuesLock.unlock() }
        activeRequestQueues[requestId] = QueueRegistration(continuation: continuation)
    }

    /// Unregister a queue
    public func unregisterQueue(requestId: UInt64) {
        queuesLock.lock()
        defer { queuesLock.unlock() }
        activeRequestQueues.removeValue(forKey: requestId)
    }

    // MARK: - Management Commands

    /// Send a management command and get response
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

    /// Send a management command asynchronously
    public func sendManagementCommandAsync(_ command: [String: Any], timeout: TimeInterval = 30.0) async throws -> [String: Any] {
        // Copy command to make it sendable
        let commandData = try JSONSerialization.data(withJSONObject: command)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: IPCError.notConnected)
                    return
                }
                do {
                    let commandCopy = try JSONSerialization.jsonObject(with: commandData) as! [String: Any]
                    let result = try self.sendManagementCommand(commandCopy, timeout: timeout)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Request Submission

    /// Send an inference request
    public func sendRequest(
        requestId: UInt64,
        modelId: String,
        modelPath: String,
        prompts: [[String: Any]]
    ) throws {
        guard let socket = requestSocket else {
            throw IPCError.notConnected
        }

        let payload = try Serialization.buildRequestPayload(
            requestId: requestId,
            modelId: modelId,
            modelPath: modelPath,
            requestType: .generation,
            responseChannelId: responseChannelId,
            prompts: prompts
        )

        try socket.send(payload)
    }

    // MARK: - Private

    private func generateResponseChannelId() -> UInt64 {
        let pidComponent = UInt64(getpid()) & 0xFFFFFFFF
        let randomComponent = UInt64.random(in: 0...0xFFFFFFFF)
        var channelId = (pidComponent << 32) | randomComponent
        if channelId == 0 {
            channelId = 1
        }
        return channelId
    }

    private func startListener() {
        listenerLock.lock()
        shouldStopListener = false
        listenerLock.unlock()

        let thread = Thread { [weak self] in
            self?.runResponseListener()
        }
        thread.name = "orchard-ipc-listener"
        thread.qualityOfService = .userInteractive
        listenerThread = thread
        thread.start()
    }

    private func stopListener() {
        listenerLock.lock()
        shouldStopListener = true
        listenerLock.unlock()

        while listenerThread?.isFinished == false {
            Thread.sleep(forTimeInterval: 0.01)
        }
        listenerThread = nil
    }

    private func runResponseListener() {
        guard let socket = responseSocket else { return }

        let eventPrefix = IPCEndpoints.eventTopicPrefix

        while true {
            listenerLock.lock()
            let shouldStop = shouldStopListener
            listenerLock.unlock()
            if shouldStop { break }

            do {
                let data = try socket.receive(timeout: 0.1)

                if data.starts(with: responseTopicPrefix) {
                    handleResponseDelta(data)
                } else if data.starts(with: eventPrefix) {
                    handleEngineEvent(data)
                }
            } catch SocketError.timeout {
                continue
            } catch {
                listenerLock.lock()
                let shouldStop = shouldStopListener
                listenerLock.unlock()
                if shouldStop { break }
                continue
            }
        }
    }

    private func handleResponseDelta(_ data: Data) {
        let jsonData = data.dropFirst(responseTopicPrefix.count)
        guard let json = try? JSONSerialization.jsonObject(with: Data(jsonData)) as? [String: Any] else {
            return
        }

        let delta = ResponseDelta(from: json)

        queuesLock.lock()
        let registration = activeRequestQueues[delta.requestId]
        queuesLock.unlock()

        if let registration = registration {
            registration.continuation.yield(delta)

            if delta.isFinalDelta {
                registration.continuation.finish()
                queuesLock.lock()
                activeRequestQueues.removeValue(forKey: delta.requestId)
                queuesLock.unlock()
            }
        }
    }

    private func handleEngineEvent(_ data: Data) {
        // Parse event: __PIE_EVENT__:<event_name>\0<json_body>
        guard let nullIndex = data.firstIndex(of: 0) else { return }

        let topicPart = data[..<nullIndex]
        let jsonBody = data[(nullIndex + 1)...]

        let eventPrefix = IPCEndpoints.eventTopicPrefix
        guard topicPart.count > eventPrefix.count else { return }

        let eventNameData = topicPart.dropFirst(eventPrefix.count)
        guard let eventName = String(data: Data(eventNameData), encoding: .utf8) else { return }

        guard let payload = try? JSONSerialization.jsonObject(with: Data(jsonBody)) as? [String: Any] else {
            return
        }

        switch eventName {
        case "telemetry":
            globalContext?.lastTelemetry = payload

        case "model_loaded":
            guard payload["model_id"] is String else { return }
            globalContext?.modelRegistry?.handleModelLoaded(payload: payload)

        default:
            break
        }
    }
}

/// Registration for an active request queue
private struct QueueRegistration {
    let continuation: AsyncStream<ResponseDelta>.Continuation
}
