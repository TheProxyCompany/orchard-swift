import Foundation
import Testing
@testable import Orchard

/// IPC layer tests
@Suite
struct IPCTests {
    @Test
    func testRequestIdGeneration() {
        let state = IPCState()

        let id1 = state.nextRequestId()
        let id2 = state.nextRequestId()
        let id3 = state.nextRequestId()

        #expect(id1 > 0, "First ID should be positive")
        #expect(id2 == id1 + 1, "IDs should be sequential")
        #expect(id3 == id2 + 1, "IDs should be sequential")
    }

    @Test
    func testResponseDeltaParsing() {
        let json: [String: Any] = [
            "request_id": 42,
            "content": "Hello, world!",
            "is_final_delta": true,
            "finish_reason": "stop",
            "prompt_token_count": 10,
            "generation_len": 5
        ]

        let delta = ClientDelta(from: json)

        #expect(delta.requestId == 42)
        #expect(delta.content == "Hello, world!")
        #expect(delta.isFinal == true)
        #expect(delta.finishReason == "stop")
        #expect(delta.promptTokenCount == 10)
        #expect(delta.generationLen == 5)
    }

    @Test
    func testResponseDeltaMissingFields() {
        let json: [String: Any] = [
            "request_id": 1
        ]

        let delta = ClientDelta(from: json)

        #expect(delta.requestId == 1)
        #expect(delta.content == nil)
        #expect(delta.isFinal == false)
        #expect(delta.finishReason == nil)
    }
}
