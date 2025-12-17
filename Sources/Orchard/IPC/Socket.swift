import Foundation
import nng

/// NNG socket errors
public enum SocketError: Error, CustomStringConvertible {
    case openFailed(nng_err)
    case dialFailed(nng_err, String)
    case sendFailed(nng_err)
    case receiveFailed(nng_err)
    case subscribeFailed(nng_err)
    case timeout
    case messageAllocFailed

    public var description: String {
        switch self {
        case .openFailed(let err):
            return "Failed to open socket: \(nngError(err))"
        case .dialFailed(let err, let url):
            return "Failed to dial \(url): \(nngError(err))"
        case .sendFailed(let err):
            return "Failed to send: \(nngError(err))"
        case .receiveFailed(let err):
            return "Failed to receive: \(nngError(err))"
        case .subscribeFailed(let err):
            return "Failed to subscribe: \(nngError(err))"
        case .timeout:
            return "Operation timed out"
        case .messageAllocFailed:
            return "Failed to allocate message"
        }
    }
}

/// Convert NNG error to string
private func nngError(_ err: nng_err) -> String {
    if let cStr = nng_strerror(err) {
        return String(cString: cStr)
    }
    return "Unknown error (\(err.rawValue))"
}

/// Convert Int32 return value to nng_err
private func toError(_ rv: Int32) -> nng_err {
    nng_err(rawValue: UInt32(bitPattern: rv))
}

// MARK: - Push Socket (for sending requests)

/// NNG Push socket for sending messages to PIE
public final class PushSocket: @unchecked Sendable {
    private var socket: nng_socket
    private let lock = NSLock()

    public init() throws {
        var sock = nng_socket()
        let rv = nng_push0_open(&sock)
        guard rv == 0 else {
            throw SocketError.openFailed(toError(rv))
        }
        self.socket = sock

        // Set unlimited receive buffer size
        _ = nng_socket_set_size(socket, NNG_OPT_RECVMAXSZ, 0)
    }

    deinit {
        close()
    }

    /// Connect to a URL with retry
    public func dial(_ url: String, attempts: Int = 50, delay: TimeInterval = 0.2) throws {
        var lastError: Int32 = 0

        for attempt in 1...attempts {
            let rv = url.withCString { nng_dial(socket, $0, nil, 0) }
            if rv == 0 {
                return
            }
            lastError = rv
            if attempt < attempts {
                Thread.sleep(forTimeInterval: delay)
            }
        }

        throw SocketError.dialFailed(toError(lastError), url)
    }

    /// Send data
    public func send(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        // Allocate and populate message
        var msgPtr: OpaquePointer?
        var rv = nng_msg_alloc(&msgPtr, data.count)
        guard rv == 0, let msg = msgPtr else {
            throw SocketError.messageAllocFailed
        }

        // Copy data into message body
        if let body = nng_msg_body(msg) {
            data.copyBytes(to: body.assumingMemoryBound(to: UInt8.self), count: data.count)
        }

        // Send message (NNG takes ownership)
        rv = nng_sendmsg(socket, msg, 0)
        guard rv == 0 else {
            nng_msg_free(msg)
            throw SocketError.sendFailed(toError(rv))
        }
    }

    /// Close the socket
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        _ = nng_socket_close(socket)
    }
}

// MARK: - Sub Socket (for receiving responses)

/// NNG Sub socket for receiving messages from PIE
public final class SubSocket: @unchecked Sendable {
    private var socket: nng_socket
    private let lock = NSLock()

    public init() throws {
        var sock = nng_socket()
        let rv = nng_sub0_open(&sock)
        guard rv == 0 else {
            throw SocketError.openFailed(toError(rv))
        }
        self.socket = sock

        // Set unlimited receive buffer size
        _ = nng_socket_set_size(socket, NNG_OPT_RECVMAXSZ, 0)
    }

    deinit {
        close()
    }

    /// Connect to a URL with retry
    public func dial(_ url: String, attempts: Int = 50, delay: TimeInterval = 0.2) throws {
        var lastError: Int32 = 0

        for attempt in 1...attempts {
            let rv = url.withCString { nng_dial(socket, $0, nil, 0) }
            if rv == 0 {
                return
            }
            lastError = rv
            if attempt < attempts {
                Thread.sleep(forTimeInterval: delay)
            }
        }

        throw SocketError.dialFailed(toError(lastError), url)
    }

    /// Subscribe to a topic
    public func subscribe(_ topic: Data) throws {
        let rv = topic.withUnsafeBytes { ptr in
            nng_sub0_socket_subscribe(socket, ptr.baseAddress, ptr.count)
        }
        guard rv == 0 else {
            throw SocketError.subscribeFailed(toError(rv))
        }
    }

    /// Subscribe to a string topic
    public func subscribe(_ topic: String) throws {
        try subscribe(Data(topic.utf8))
    }

    /// Receive a message (blocking)
    public func receive() throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        var msgPtr: OpaquePointer?
        let rv = nng_recvmsg(socket, &msgPtr, 0)
        guard rv == 0, let msg = msgPtr else {
            throw SocketError.receiveFailed(toError(rv))
        }
        defer { nng_msg_free(msg) }

        let len = nng_msg_len(msg)
        guard let body = nng_msg_body(msg) else {
            return Data()
        }
        return Data(bytes: body, count: len)
    }

    /// Receive a message with timeout
    public func receive(timeout: TimeInterval) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        // Set receive timeout
        let ms = Int32(timeout * 1000)
        _ = nng_socket_set_ms(socket, NNG_OPT_RECVTIMEO, ms)

        var msgPtr: OpaquePointer?
        let rv = nng_recvmsg(socket, &msgPtr, 0)

        if toError(rv) == NNG_ETIMEDOUT {
            throw SocketError.timeout
        }
        guard rv == 0, let msg = msgPtr else {
            throw SocketError.receiveFailed(toError(rv))
        }
        defer { nng_msg_free(msg) }

        let len = nng_msg_len(msg)
        guard let body = nng_msg_body(msg) else {
            return Data()
        }
        return Data(bytes: body, count: len)
    }

    /// Close the socket
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        _ = nng_socket_close(socket)
    }
}

// MARK: - Req Socket (for management commands)

/// NNG Req socket for request/reply patterns
public final class ReqSocket: @unchecked Sendable {
    private var socket: nng_socket
    private let lock = NSLock()

    public init() throws {
        var sock = nng_socket()
        let rv = nng_req0_open(&sock)
        guard rv == 0 else {
            throw SocketError.openFailed(toError(rv))
        }
        self.socket = sock

        // Set unlimited receive buffer size
        _ = nng_socket_set_size(socket, NNG_OPT_RECVMAXSZ, 0)
    }

    deinit {
        close()
    }

    /// Connect to a URL with retry
    public func dial(_ url: String, attempts: Int = 50, delay: TimeInterval = 0.2) throws {
        var lastError: Int32 = 0

        for attempt in 1...attempts {
            let rv = url.withCString { nng_dial(socket, $0, nil, 0) }
            if rv == 0 {
                return
            }
            lastError = rv
            if attempt < attempts {
                Thread.sleep(forTimeInterval: delay)
            }
        }

        throw SocketError.dialFailed(toError(lastError), url)
    }

    /// Send a request and receive a reply
    public func request(_ data: Data, timeout: TimeInterval = 30.0) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        // Set timeouts
        let ms = Int32(timeout * 1000)
        _ = nng_socket_set_ms(socket, NNG_OPT_RECVTIMEO, ms)
        _ = nng_socket_set_ms(socket, NNG_OPT_SENDTIMEO, ms)

        // Allocate and send request message
        var reqMsgPtr: OpaquePointer?
        var rv = nng_msg_alloc(&reqMsgPtr, data.count)
        guard rv == 0, let reqMsg = reqMsgPtr else {
            throw SocketError.messageAllocFailed
        }

        if let body = nng_msg_body(reqMsg) {
            data.copyBytes(to: body.assumingMemoryBound(to: UInt8.self), count: data.count)
        }

        rv = nng_sendmsg(socket, reqMsg, 0)
        guard rv == 0 else {
            nng_msg_free(reqMsg)
            throw SocketError.sendFailed(toError(rv))
        }

        // Receive reply
        var repMsgPtr: OpaquePointer?
        rv = nng_recvmsg(socket, &repMsgPtr, 0)

        if toError(rv) == NNG_ETIMEDOUT {
            throw SocketError.timeout
        }
        guard rv == 0, let repMsg = repMsgPtr else {
            throw SocketError.receiveFailed(toError(rv))
        }
        defer { nng_msg_free(repMsg) }

        let len = nng_msg_len(repMsg)
        guard let body = nng_msg_body(repMsg) else {
            return Data()
        }
        return Data(bytes: body, count: len)
    }

    /// Close the socket
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        _ = nng_socket_close(socket)
    }
}
