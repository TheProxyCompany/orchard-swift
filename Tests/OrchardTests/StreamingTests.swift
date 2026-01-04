import Foundation
import Testing
@testable import Orchard

/// Streaming chat completion tests
@Suite(.serialized)
struct StreamingTests {
    static let testModelId = "meta-llama/Llama-3.1-8B-Instruct"

    @Test(.timeLimit(.minutes(2)))
    func testStreamingChatCompletion() async throws {
        let engine = try await TestFixtures.sharedEngine()
        let client = try engine.client()

        let stream = try await client.achatStream(
            modelId: Self.testModelId,
            messages: [["role": "user", "content": "Respond with your favorite musical artist."]],
            params: ChatParameters(
                maxGeneratedTokens: 96,
                temperature: 0.7
            )
        )

        var deltas: [ClientDelta] = []
        var content = ""

        for await delta in stream {
            deltas.append(delta)
            if let text = delta.content {
                content += text
            }
        }

        #expect(deltas.count > 1, "Should receive multiple deltas")
        #expect(!content.trimmingCharacters(in: .whitespaces).isEmpty, "Should have content")
        #expect(deltas.last?.isFinal == true, "Last delta should be final")

        print("Streamed content: \(content)")
    }

    @Test(.timeLimit(.minutes(2)))
    func testStreamingReceivesAllTokens() async throws {
        let engine = try await TestFixtures.sharedEngine()
        let client = try engine.client()

        let maxTokens = 20
        let stream = try await client.achatStream(
            modelId: Self.testModelId,
            messages: [["role": "user", "content": "Count from 1 to 10."]],
            params: ChatParameters(
                maxGeneratedTokens: maxTokens,
                temperature: 0.0
            )
        )

        var tokenCount = 0
        for await delta in stream {
            if let count = delta.numTokensInDelta {
                tokenCount += count
            }
        }

        #expect(tokenCount > 0, "Should have generated tokens")
        #expect(tokenCount <= maxTokens, "Should not exceed max tokens")
    }
}
