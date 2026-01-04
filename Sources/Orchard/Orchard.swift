import Foundation

/// Orchard Swift - Swift client library for the Orchard inference platform.
///
/// Provides PIE binary management, NNG IPC communication, and high-level inference APIs.
///
/// ## Quick Start
///
/// ```swift
/// // Start the inference engine and load a model
/// let engine = try await InferenceEngine(loadModels: ["meta-llama/Llama-3.1-8B-Instruct"])
///
/// // Get a client and make a request
/// let client = try engine.client()
/// let response = try await client.achat(
///     modelId: "meta-llama/Llama-3.1-8B-Instruct",
///     messages: [["role": "user", "content": "Hello!"]]
/// )
/// print(response.text)
///
/// // Clean up
/// engine.close()
/// ```
public enum Orchard {
    /// Library version
    public static let version = "0.2.0"

    /// Shared engine fetcher instance
    public static let fetcher = EngineFetcher()

    /// Global context for the inference engine
    public static var globalContext: GlobalContext { GlobalContext.shared }
}
