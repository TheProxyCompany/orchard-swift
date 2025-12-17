import Foundation

/// Orchard Swift - Swift client library for the Orchard inference platform.
///
/// Provides PIE binary management and NNG IPC communication.
public enum Orchard {
    /// Library version
    public static let version = "0.1.0"

    /// Shared engine fetcher instance
    public static let fetcher = EngineFetcher()
}
