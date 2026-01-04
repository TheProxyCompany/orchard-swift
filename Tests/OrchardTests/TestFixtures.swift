import Foundation
@testable import Orchard

/// Test fixtures for shared engine management
actor TestFixtures {
    static let shared = TestFixtures()

    private var engine: InferenceEngine?
    private static let testModels = [
        "meta-llama/Llama-3.1-8B-Instruct",
        "moondream/moondream3-preview"
    ]

    private init() {}

    /// Get or create the shared engine instance
    func getEngine() async throws -> InferenceEngine {
        if let engine = engine {
            return engine
        }

        // Create engine and load test models
        let newEngine = try await InferenceEngine(
            startupTimeout: 120.0,
            loadModels: Self.testModels
        )

        engine = newEngine
        return newEngine
    }

    /// Shutdown the shared engine
    func shutdown() {
        engine?.close()
        engine = nil
    }

    /// Static helper for compatibility
    static func sharedEngine() async throws -> InferenceEngine {
        try await shared.getEngine()
    }

    /// Static helper for shutdown
    static func shutdownEngine() async {
        await shared.shutdown()
    }
}
