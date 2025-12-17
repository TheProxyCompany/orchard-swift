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

        // 3. Wait for PIE to be ready
        try await pie.waitForReady(timeout: 60.0)

        // 4. Connect IPC client
        let client = IPCClient()
        try client.connect()

        defer {
            client.disconnect()
        }

        // 5. Verify connection by checking we can allocate request IDs
        let requestId = client.nextRequestId()
        #expect(requestId > 0)
    }

    @Test(.timeLimit(.minutes(2)))
    func testSimpleGeneration() async throws {
        // 1. Resolve model to local path first
        let resolver = ModelResolver()
        let resolved = try resolver.resolve(Self.testModelId)

        // 2. Ensure PIE binary exists
        let fetcher = EngineFetcher()
        let piePath = try await fetcher.getEnginePath()

        // 3. Start PIE process
        let pie = PIEProcess(enginePath: piePath)
        try pie.start()

        defer {
            pie.stop()
        }

        // 4. Wait for PIE to be ready
        try await pie.waitForReady(timeout: 15.0)

        // 5. Connect IPC client
        let client = IPCClient()
        try client.connect()

        defer {
            client.disconnect()
        }

        // 6. Load model with resolved local path
        let loadResponse = try client.sendManagementCommand([
            "type": "load_model",
            "requested_id": Self.testModelId,
            "canonical_id": resolved.canonicalId,
            "model_path": resolved.modelPath.path,
            "wait_for_completion": false,
        ], timeout: 10.0)

        let status = loadResponse["status"] as? String
        #expect(status == "ok" || status == "accepted", "Model load should be accepted")

        // 7. Poll until model is ready
        var modelReady = false
        for _ in 1...30 {
            let listResponse = try client.sendManagementCommand(["type": "list_models"], timeout: 5.0)
            if let data = listResponse["data"] as? [String: Any],
               let listModels = data["list_models"] as? [String: Any],
               let models = listModels["models"] as? [[String: Any]] {
                for model in models {
                    if let id = model["requested_id"] as? String,
                       let state = model["load_state"] as? String,
                       id == Self.testModelId {
                        if state == "ready" || state == "Ready" {
                            modelReady = true
                            break
                        } else if state == "failed" {
                            let error = model["error"] as? String ?? "unknown"
                            throw TestError.modelLoadFailed(error)
                        }
                    }
                }
            }
            if modelReady { break }
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }

        #expect(modelReady, "Model should become ready")

        // 8. Send generation request
        let requestId = client.nextRequestId()
        let stream = try client.sendRequest(
            requestId: requestId,
            modelId: Self.testModelId,
            modelPath: resolved.modelPath.path,
            prompt: "Hello!",
            maxTokens: 10,
            temperature: 0.0
        )

        // 9. Collect responses
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

        // 10. Verify we got a response
        #expect(gotFinalDelta, "Should receive final delta")
        #expect(!content.isEmpty, "Should receive some generated content")
    }
}

enum TestError: Error {
    case modelLoadFailed(String)
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
        let responseSocket = ipcRoot.appendingPathComponent("pie_responses.ipc")
        let managementSocket = ipcRoot.appendingPathComponent("pie_management.ipc")

        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let requestExists = FileManager.default.fileExists(atPath: requestSocket.path)
            let responseExists = FileManager.default.fileExists(atPath: responseSocket.path)
            let managementExists = FileManager.default.fileExists(atPath: managementSocket.path)

            if requestExists && responseExists && managementExists {
                // All socket files exist, give PIE time to finish init
                try await Task.sleep(nanoseconds: 500_000_000)
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        throw PIEError.startupTimeout
    }
}

enum PIEError: Error {
    case startupTimeout
    case notRunning
}
