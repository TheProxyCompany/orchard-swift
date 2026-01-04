import Foundation
import Testing
@testable import Orchard

/// Multimodal (image) tests
@Suite(.serialized)
struct MultimodalTests {
    static let testModelId = "moondream/moondream3-preview"

    /// Create a simple test image (1x1 red pixel PNG)
    static func makeTestImage() -> Data {
        // Minimal valid PNG: 1x1 red pixel
        let pngBytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE,
            0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, // IDAT chunk
            0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00,
            0x01, 0x01, 0x00, 0x05,
            0x7E, 0xD5, 0x39, 0x6E,
            0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, // IEND chunk
            0xAE, 0x42, 0x60, 0x82
        ]
        return Data(pngBytes)
    }

    @Test(.timeLimit(.minutes(2)), .disabled("Requires real test images"))
    func testImageDescription() async throws {
        let engine = try await TestFixtures.sharedEngine()
        let client = try engine.client()

        let imageData = Self.makeTestImage()
        let base64Image = imageData.base64EncodedString()
        let dataURL = "data:image/png;base64,\(base64Image)"

        let response = try await client.achat(
            modelId: Self.testModelId,
            messages: [[
                "role": "user",
                "content": [
                    ["type": "input_text", "text": "What is in this image?"],
                    ["type": "input_image", "image_url": dataURL]
                ]
            ]],
            params: ChatParameters(
                maxGeneratedTokens: 64,
                temperature: 0.0
            )
        )

        #expect(!response.text.isEmpty, "Should describe the image")
        print("Image description: \(response.text)")
    }

    @Test
    func testMultimodalMessageBuilding() throws {
        // Test the multimodal message building without actually calling the engine
        let imageData = Self.makeTestImage()
        let base64Image = imageData.base64EncodedString()
        let dataURL = "data:image/png;base64,\(base64Image)"

        let messages: [[String: Any]] = [[
            "role": "user",
            "content": [
                ["type": "text", "text": "What is this?"],
                ["type": "image", "image_url": dataURL]
            ]
        ]]

        // Create a mock formatter to test message building
        // For now just verify the data URL decoding works
        let decoded = try decodeImagePayload(dataURL)
        #expect(decoded == imageData, "Should decode image correctly")
    }

    @Test
    func testDataURLDecoding() throws {
        let testData = Data([0x01, 0x02, 0x03, 0x04])
        let base64 = testData.base64EncodedString()
        let dataURL = "data:application/octet-stream;base64,\(base64)"

        let decoded = try decodeImagePayload(dataURL)
        #expect(decoded == testData, "Should decode data correctly")
    }

    @Test
    func testInvalidDataURLThrows() {
        let invalidURL = "not-a-data-url"
        #expect(throws: MultimodalError.self) {
            _ = try decodeImagePayload(invalidURL)
        }
    }
}
