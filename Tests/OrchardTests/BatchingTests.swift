import Foundation
import Testing
@testable import Orchard

/// Batched chat completion tests
@Suite(.serialized)
struct BatchingTests {
    static let testModelId = "moondream/moondream3-preview"

    @Test(.timeLimit(.minutes(3)))
    func testBatchedHomogeneousPrompts() async throws {
        let engine = try await TestFixtures.sharedEngine()
        let client = try engine.client()

        let responses = try await client.achatBatch(
            modelId: Self.testModelId,
            conversations: [
                [["role": "user", "content": "Say hello politely."]],
                [["role": "user", "content": "Give me a fun fact about space."]]
            ],
            params: ChatParameters(
                maxGeneratedTokens: 10,
                temperature: 0.0
            )
        )

        #expect(responses.count == 2, "Should have 2 responses")

        for (index, response) in responses.enumerated() {
            #expect(!response.text.isEmpty, "Response \(index) should have content")
            #expect(response.finishReason != nil, "Response \(index) should have finish reason")
            print("Response \(index): \(response.text)")
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testBatchedDifferentLengths() async throws {
        let engine = try await TestFixtures.sharedEngine()
        let client = try engine.client()

        // Each prompt with different complexity
        let responses = try await client.achatBatch(
            modelId: Self.testModelId,
            conversations: [
                [["role": "user", "content": "Respond with a single word greeting."]],
                [["role": "user", "content": "List three colors separated by commas."]]
            ],
            params: ChatParameters(
                maxGeneratedTokens: 20,
                temperature: 0.0
            )
        )

        #expect(responses.count == 2, "Should have 2 responses")

        for (index, response) in responses.enumerated() {
            #expect(!response.text.isEmpty, "Response \(index) should have content")
            print("Response \(index): \(response.text)")
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testBatchedThreePrompts() async throws {
        let engine = try await TestFixtures.sharedEngine()
        let client = try engine.client()

        let responses = try await client.achatBatch(
            modelId: Self.testModelId,
            conversations: [
                [["role": "user", "content": "What is 2+2?"]],
                [["role": "user", "content": "What is the capital of France?"]],
                [["role": "user", "content": "Name a primary color."]]
            ],
            params: ChatParameters(
                maxGeneratedTokens: 10,
                temperature: 0.0
            )
        )

        #expect(responses.count == 3, "Should have 3 responses")

        for (index, response) in responses.enumerated() {
            #expect(!response.text.isEmpty, "Response \(index) should have content")
        }
    }
}
