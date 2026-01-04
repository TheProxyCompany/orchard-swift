import Foundation
import Testing
@testable import Orchard

/// Basic end-to-end tests for chat completions
@Suite(.serialized)
struct BasicTests {
    static let testModelId = "meta-llama/Llama-3.1-8B-Instruct"

    @Test(.timeLimit(.minutes(3)))
    func testChatCompletionFirstToken() async throws {
        let engine = try await TestFixtures.sharedEngine()
        let client: OrchardClient = try engine.client()

        let response = try await client.achat(
            modelId: Self.testModelId,
            messages: [["role": "user", "content": "Hello!"]],
            params: ChatParameters(
                maxGeneratedTokens: 1,
                temperature: 1.0
            )
        )

        #expect(!response.text.isEmpty, "Content should not be empty")
        #expect(response.finishReason != nil, "Should have a finish reason")
    }

    @Test(.timeLimit(.minutes(2)))
    func testChatCompletionMultiToken() async throws {
        let engine = try await TestFixtures.sharedEngine()
        let client = try engine.client()

        let response = try await client.achat(
            modelId: Self.testModelId,
            messages: [[
                "role": "user",
                "content": "Provide one friendly sentence introducing yourself."
            ]],
            params: ChatParameters(
                maxGeneratedTokens: 64,
                temperature: 0.0
            )
        )

        #expect(!response.text.isEmpty, "Should have generated content")
        #expect(response.usage.completionTokens > 0, "Should have completion tokens")
        print("Response: \(response.text)")
    }

    @Test(.timeLimit(.minutes(2)))
    func testChatCompletionWithSystemPrompt() async throws {
        let engine = try await TestFixtures.sharedEngine()
        let client = try engine.client()

        let response = try await client.achat(
            modelId: Self.testModelId,
            messages: [
                ["role": "system", "content": "You are a pirate. Always respond like a pirate."],
                ["role": "user", "content": "Hello, who are you?"]
            ],
            params: ChatParameters(
                maxGeneratedTokens: 64,
                temperature: 0.0
            )
        )

        #expect(!response.text.isEmpty, "Should have generated content")
        print("Pirate response: \(response.text)")
    }

    @Test(.timeLimit(.minutes(2)))
    func testChatCompletionDeterministic() async throws {
        let engine = try await TestFixtures.sharedEngine()
        let client = try engine.client()

        let params = ChatParameters(
            maxGeneratedTokens: 10,
            temperature: 0.0,
            rngSeed: 42
        )

        let response1 = try await client.achat(
            modelId: Self.testModelId,
            messages: [["role": "user", "content": "Count from 1 to 5."]],
            params: params
        )

        let response2 = try await client.achat(
            modelId: Self.testModelId,
            messages: [["role": "user", "content": "Count from 1 to 5."]],
            params: params
        )

        #expect(response1.text == response2.text, "Deterministic outputs should match")
    }
}
