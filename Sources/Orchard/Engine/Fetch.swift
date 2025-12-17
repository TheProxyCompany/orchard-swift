import Foundation
import CryptoKit

/// Errors that can occur during engine binary operations.
public enum FetchError: Error, LocalizedError {
    case manifestFetchFailed(String)
    case versionNotFound(String, available: [String])
    case downloadFailed(String)
    case integrityCheckFailed(expected: String, actual: String)
    case extractionFailed(String)
    case binaryNotFound

    public var errorDescription: String? {
        switch self {
        case .manifestFetchFailed(let reason):
            return "Failed to fetch release manifest: \(reason)"
        case .versionNotFound(let version, let available):
            return "Version \(version) not found. Available: \(available.joined(separator: ", "))"
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .integrityCheckFailed(let expected, let actual):
            return "SHA256 verification failed. Expected: \(expected), Got: \(actual)"
        case .extractionFailed(let reason):
            return "Failed to extract archive: \(reason)"
        case .binaryNotFound:
            return "Engine binary not found after installation"
        }
    }
}

/// Release manifest response from the server.
struct ReleaseManifest: Codable {
    let latest: String
    let versions: [String: VersionInfo]

    struct VersionInfo: Codable {
        let url: String
        let sha256: String
    }
}

/// Manages PIE binary fetching and installation.
public actor EngineFetcher {

    private static let manifestURL = "https://prod.proxy.ing/functions/v1/get-release-manifest"
    public static let defaultChannel = "stable"

    private let orchardHome: URL
    private let session: URLSession

    public init() {
        self.orchardHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".orchard")
        self.session = URLSession.shared
    }

    /// Returns the path to the engine binary, downloading if necessary.
    public func getEnginePath() async throws -> URL {
        // Check for local dev override
        if let localBuild = ProcessInfo.processInfo.environment["PIE_LOCAL_BUILD"] {
            let localPath = URL(fileURLWithPath: localBuild)
                .appendingPathComponent("bin")
                .appendingPathComponent("proxy_inference_engine")
            if FileManager.default.fileExists(atPath: localPath.path) {
                return localPath
            }
        }

        let binaryPath = orchardHome
            .appendingPathComponent("bin")
            .appendingPathComponent("proxy_inference_engine")

        if FileManager.default.fileExists(atPath: binaryPath.path) {
            return binaryPath
        }

        // Download if not present
        try await downloadEngine()

        guard FileManager.default.fileExists(atPath: binaryPath.path) else {
            throw FetchError.binaryNotFound
        }

        return binaryPath
    }

    /// Downloads and installs the engine binary.
    public func downloadEngine(
        channel: String = defaultChannel,
        version: String? = nil
    ) async throws {
        let manifest = try await fetchManifest(channel: channel)

        let targetVersion = version ?? manifest.latest

        guard let versionInfo = manifest.versions[targetVersion] else {
            throw FetchError.versionNotFound(
                targetVersion,
                available: Array(manifest.versions.keys).sorted()
            )
        }

        print("→ Downloading \(targetVersion)")
        let data = try await downloadWithProgress(
            url: versionInfo.url,
            expectedSHA256: versionInfo.sha256
        )

        try extractAndInstall(data: data, version: targetVersion)
        print("✓ Installed \(targetVersion)")
    }

    /// Returns the currently installed version, if any.
    public func getInstalledVersion() -> String? {
        let versionFile = orchardHome.appendingPathComponent("version.txt")
        guard let contents = try? String(contentsOf: versionFile, encoding: .utf8) else {
            return nil
        }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Checks if an update is available.
    public func checkForUpdates(channel: String = defaultChannel) async -> String? {
        guard let installed = getInstalledVersion() else { return nil }

        do {
            let manifest = try await fetchManifest(channel: channel)
            if manifest.latest != installed {
                return manifest.latest
            }
        } catch {
            // Silently ignore update check failures
        }

        return nil
    }

    // MARK: - Private

    private func fetchManifest(channel: String) async throws -> ReleaseManifest {
        var components = URLComponents(string: Self.manifestURL)!
        components.queryItems = [
            URLQueryItem(name: "channel", value: channel),
            URLQueryItem(name: "v", value: getInstalledVersion() ?? "unknown"),
            URLQueryItem(name: "os", value: "darwin"),
            URLQueryItem(name: "arch", value: currentArchitecture())
        ]

        guard let url = components.url else {
            throw FetchError.manifestFetchFailed("Invalid URL")
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw FetchError.manifestFetchFailed("Server returned error")
        }

        return try JSONDecoder().decode(ReleaseManifest.self, from: data)
    }

    private func downloadWithProgress(url: String, expectedSHA256: String) async throws -> Data {
        guard let downloadURL = URL(string: url) else {
            throw FetchError.downloadFailed("Invalid URL")
        }

        let (data, response) = try await session.data(from: downloadURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw FetchError.downloadFailed("Server returned error")
        }

        // Verify SHA256
        let hash = SHA256.hash(data: data)
        let actualSHA256 = hash.compactMap { String(format: "%02x", $0) }.joined()

        guard actualSHA256 == expectedSHA256 else {
            throw FetchError.integrityCheckFailed(expected: expectedSHA256, actual: actualSHA256)
        }

        return data
    }

    private func extractAndInstall(data: Data, version: String) throws {
        let fileManager = FileManager.default

        // Create orchard home if needed
        try fileManager.createDirectory(at: orchardHome, withIntermediateDirectories: true)

        let binDir = orchardHome.appendingPathComponent("bin")

        // Clean existing bin directory
        if fileManager.fileExists(atPath: binDir.path) {
            try fileManager.removeItem(at: binDir)
        }

        // Write to temp file and extract
        let tempFile = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tar.gz")
        try data.write(to: tempFile)
        defer { try? fileManager.removeItem(at: tempFile) }

        // Extract using tar
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", tempFile.path, "-C", orchardHome.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw FetchError.extractionFailed("tar exited with status \(process.terminationStatus)")
        }

        // Verify binary exists
        let binaryPath = binDir.appendingPathComponent("proxy_inference_engine")
        guard fileManager.fileExists(atPath: binaryPath.path) else {
            throw FetchError.extractionFailed("Archive did not contain expected binary")
        }

        // Make executable
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath.path)

        // Write version file
        let versionFile = orchardHome.appendingPathComponent("version.txt")
        try version.write(to: versionFile, atomically: true, encoding: .utf8)
    }

    private func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
