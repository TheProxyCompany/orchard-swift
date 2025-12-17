import Foundation
import Testing
@testable import Orchard

/// Integration tests that require a running PIE instance.
/// These tests spawn PIE, communicate via IPC, and verify end-to-end functionality.
@Suite(.serialized)
struct IntegrationTests {
    /// Test model - same as orchard-py tests
    static let testModelId = "meta-llama/Llama-3.1-8B-Instruct"

    @Test(.timeLimit(.minutes(3)))
    func testPIEConnection() async throws {
        // 1. Ensure PIE binary exists
        let fetcher = EngineFetcher()
        let piePath = try await fetcher.getEnginePath()

        // 2. Start PIE process
        let pie = PIEProcess(enginePath: piePath)
        try pie.start()

        defer {
            pie.stop()
        }

        // 3. Wait for PIE to be ready (check IPC socket exists)
        try await pie.waitForReady(timeout: 60.0)

        // 4. Connect IPC client
        let client = IPCClient()
        try await client.connect()

        defer {
            Task { await client.disconnect() }
        }

        // 5. Verify connection by checking we can allocate request IDs
        let requestId = await client.nextRequestId()
        #expect(requestId > 0)
    }

    @Test(.timeLimit(.minutes(5)))
    func testSimpleGeneration() async throws {
        // 1. Ensure PIE binary exists
        let fetcher = EngineFetcher()
        let piePath = try await fetcher.getEnginePath()

        // 2. Start PIE process
        let pie = PIEProcess(enginePath: piePath)
        try pie.start()

        defer {
            pie.stop()
        }

        // 3. Wait for PIE to be ready
        try await pie.waitForReady(timeout: 60.0)

        // 4. Connect IPC client
        let client = IPCClient()
        try await client.connect()

        defer {
            Task { await client.disconnect() }
        }

        // 5. Load model via management command
        let loadResponse = try await client.sendManagementCommand([
            "command": "load_model",
            "model_id": Self.testModelId,
        ])
        let status = loadResponse["status"] as? String
        #expect(status == "ok" || status == "already_loaded", "Model should load successfully")

        // 6. Send generation request
        let requestId = await client.nextRequestId()
        let stream = try await client.sendRequest(
            requestId: requestId,
            modelId: Self.testModelId,
            modelPath: Self.testModelId,
            prompt: "Hello!",
            maxTokens: 10,
            temperature: 0.0
        )

        // 7. Collect responses
        var content = ""
        var gotFinalDelta = false

        for await delta in stream {
            if let text = delta.content {
                content += text
            }
            if delta.isFinalDelta {
                gotFinalDelta = true
            }
        }

        // 8. Verify we got a response
        #expect(gotFinalDelta, "Should receive final delta")
        #expect(!content.isEmpty, "Should receive some generated content")
    }
}

/// Helper to manage PIE subprocess
class PIEProcess {
    private let enginePath: URL
    private var process: Process?

    init(enginePath: URL) {
        self.enginePath = enginePath
    }

    func start() throws {
        let process = Process()
        process.executableURL = enginePath
        process.arguments = []

        // Redirect output to /dev/null for cleaner test output
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        self.process = process
    }

    func stop() {
        process?.terminate()
        process?.waitUntilExit()
        process = nil
    }

    func waitForReady(timeout: TimeInterval) async throws {
        let ipcRoot = IPCEndpoints.ipcRoot
        let requestSocket = ipcRoot.appendingPathComponent("pie_requests.ipc")

        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if FileManager.default.fileExists(atPath: requestSocket.path) {
                // Socket file exists, PIE is likely ready
                // Give it a moment to finish initialization
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        throw PIEError.startupTimeout
    }
}

enum PIEError: Error {
    case startupTimeout
    case notRunning
}
