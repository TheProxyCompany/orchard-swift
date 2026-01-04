import Foundation

/// Orchard Swift - Telemetry client for PIE (Proxy Inference Engine).
///
/// This minimal library provides telemetry subscription for SwiftUI apps.
/// For full inference capabilities, use orchard-rs via Grand Central.
///
/// ## Quick Start
///
/// ```swift
/// let telemetry = try OrchardTelemetry()
///
/// for await snapshot in telemetry.snapshots {
///     print("Tokens/sec: \(snapshot.models.first?.tokensPerSecond ?? 0)")
///     print("Energy: \(snapshot.health.systemWattage)W")
/// }
/// ```
public enum Orchard {
    /// Library version
    public static let version = "2026.1.0"
}
