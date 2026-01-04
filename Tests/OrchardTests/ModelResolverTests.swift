import Foundation
import Testing
@testable import Orchard

/// Model resolver tests
@Suite
struct ModelResolverTests {
    @Test
    func testResolveHuggingFaceModel() throws {
        let resolver = ModelResolver()

        // This should work if model is cached locally
        do {
            let resolved = try resolver.resolve("meta-llama/Llama-3.1-8B-Instruct")
            #expect(!resolved.canonicalId.isEmpty, "Should have canonical ID")
            #expect(resolved.source == "hf_cache" || resolved.source == "huggingface", "Should be HF source")
        } catch ModelResolutionError.notFound {
            // Model not cached, skip
            print("Model not in cache, skipping")
        }
    }

    @Test
    func testResolveLocalPath() throws {
        let resolver = ModelResolver()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-model")

        // Create temp directory with config.json
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let config = ["model_type": "llama"]
        let configData = try JSONSerialization.data(withJSONObject: config)
        try configData.write(to: tempDir.appendingPathComponent("config.json"))

        let resolved = try resolver.resolve(tempDir.path)
        #expect(resolved.source == "local", "Should be local source")
        #expect(resolved.modelPath.path == tempDir.path, "Path should match")
    }

    @Test
    func testResolveInvalidModelThrows() {
        let resolver = ModelResolver()

        #expect(throws: ModelResolutionError.self) {
            _ = try resolver.resolve("definitely-not-a-real-model-path-or-id-12345")
        }
    }

    @Test
    func testResolveAlias() throws {
        let resolver = ModelResolver()

        // moondream3 is a known alias
        do {
            let resolved = try resolver.resolve("moondream3")
            #expect(resolved.canonicalId.contains("moondream"), "Should resolve moondream alias")
        } catch ModelResolutionError.notFound {
            print("Moondream not in cache, skipping")
        }
    }
}
