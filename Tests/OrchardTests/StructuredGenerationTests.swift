import Foundation
import Testing
@testable import Orchard

/// Structured output (JSON schema) tests
@Suite(.serialized)
struct StructuredGenerationTests {
    static let testModelId = "moondream/moondream3-preview"

    @Test(.timeLimit(.minutes(2)))
    func testStructuredJSONResponse() async throws {
        let engine = try await TestFixtures.sharedEngine()
        let client = try engine.client()

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "color": [
                    "type": "object",
                    "properties": [
                        "R": ["type": "integer", "minimum": 0, "maximum": 255],
                        "G": ["type": "integer", "minimum": 0, "maximum": 255],
                        "B": ["type": "integer", "minimum": 0, "maximum": 255]
                    ],
                    "required": ["R", "G", "B"]
                ],
                "confidence": ["type": "number", "minimum": 0.0, "maximum": 1.0]
            ],
            "required": ["color", "confidence"]
        ]

        let schemaJSON = try JSONSerialization.data(withJSONObject: schema)
        let schemaString = String(data: schemaJSON, encoding: .utf8)!

        let response = try await client.achat(
            modelId: Self.testModelId,
            messages: [[
                "role": "user",
                "content": "Respond with a JSON object with a rgb(r, g, b) color and a confidence score. Use this schema: \(schemaString)"
            ]],
            params: ChatParameters(
                maxGeneratedTokens: 128,
                temperature: 0.0,
                responseFormat: [
                    "type": "json_schema",
                    "json_schema": [
                        "name": "color_summary",
                        "strict": true,
                        "schema": schema
                    ]
                ]
            )
        )

        #expect(!response.text.isEmpty, "Should have content")

        // Try to parse the JSON
        if let jsonStart = response.text.firstIndex(of: "{"),
           let jsonEnd = response.text.lastIndex(of: "}") {
            let jsonString = String(response.text[jsonStart...jsonEnd])
            let data = jsonString.data(using: .utf8)!

            if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                #expect(parsed["color"] != nil, "Should have color field")
                if let color = parsed["color"] as? [String: Any] {
                    #expect(color["R"] != nil, "Color should have R")
                    #expect(color["G"] != nil, "Color should have G")
                    #expect(color["B"] != nil, "Color should have B")
                }
            }
        }

        print("Structured response: \(response.text)")
    }

    @Test(.timeLimit(.minutes(2)))
    func testStructuredListResponse() async throws {
        let engine = try await TestFixtures.sharedEngine()
        let client = try engine.client()

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "items": [
                    "type": "array",
                    "items": ["type": "string"]
                ]
            ],
            "required": ["items"]
        ]

        let response = try await client.achat(
            modelId: Self.testModelId,
            messages: [[
                "role": "user",
                "content": "List three fruits as a JSON array in the 'items' field."
            ]],
            params: ChatParameters(
                maxGeneratedTokens: 64,
                temperature: 0.0,
                responseFormat: [
                    "type": "json_schema",
                    "json_schema": [
                        "name": "fruit_list",
                        "strict": true,
                        "schema": schema
                    ]
                ]
            )
        )

        #expect(!response.text.isEmpty, "Should have content")
        print("List response: \(response.text)")
    }
}
