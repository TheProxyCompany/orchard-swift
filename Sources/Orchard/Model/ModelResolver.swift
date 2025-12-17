import Foundation

/// Result of resolving a model identifier to a local path
public struct ResolvedModel {
    public let canonicalId: String
    public let modelPath: URL
    public let source: String  // "local", "hf_cache"
}

/// Error during model resolution
public enum ModelResolutionError: Error, CustomStringConvertible {
    case emptyIdentifier
    case notFound(String)
    case missingConfig(String)

    public var description: String {
        switch self {
        case .emptyIdentifier:
            return "Model identifier cannot be empty"
        case .notFound(let id):
            return "Model '\(id)' not found. Download it first with: huggingface-cli download \(id)"
        case .missingConfig(let path):
            return "Model directory '\(path)' is missing config.json"
        }
    }
}

/// Resolves model identifiers to local filesystem paths.
///
/// Resolution order:
/// 1. Local filesystem path (absolute or relative)
/// 2. HuggingFace cache (~/.cache/huggingface/hub/)
///
/// Note: Unlike orchard-py, this does NOT automatically download models.
/// Use `huggingface-cli download <model_id>` to download models first.
public class ModelResolver {

    /// Known aliases for common models
    private static let aliases: [String: String] = [
        "moondream3": "moondream/moondream3-preview"
    ]

    /// HuggingFace cache directory
    private let hfCacheDir: URL

    /// Cache of resolved models
    private var resolvedCache: [String: ResolvedModel] = [:]

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.hfCacheDir = home.appendingPathComponent(".cache/huggingface/hub")
    }

    /// Resolve a model identifier to a local filesystem path.
    ///
    /// - Parameter requestedId: Model identifier - can be:
    ///   - Local path: /path/to/model or ./relative/path
    ///   - HF repo ID: meta-llama/Llama-3.1-8B-Instruct
    ///   - Alias: moondream3
    ///
    /// - Returns: ResolvedModel with the local path
    /// - Throws: ModelResolutionError if the model cannot be resolved
    public func resolve(_ requestedId: String) throws -> ResolvedModel {
        let identifier = requestedId.trimmingCharacters(in: .whitespaces)
        guard !identifier.isEmpty else {
            throw ModelResolutionError.emptyIdentifier
        }

        // Check cache first
        let cacheKey = identifier.lowercased()
        if let cached = resolvedCache[cacheKey] {
            return cached
        }

        // 1. Try as local filesystem path
        if let resolved = tryLocalPath(identifier) {
            resolvedCache[cacheKey] = resolved
            return resolved
        }

        // 2. Resolve alias if present
        let hfRepoId: String
        if let aliased = Self.aliases[identifier.lowercased()] {
            hfRepoId = aliased
        } else {
            hfRepoId = identifier
        }

        // 3. Try HuggingFace cache
        if let resolved = tryHuggingFaceCache(hfRepoId, requestedId: identifier) {
            resolvedCache[cacheKey] = resolved
            return resolved
        }

        throw ModelResolutionError.notFound(identifier)
    }

    // MARK: - Private

    private func tryLocalPath(_ identifier: String) -> ResolvedModel? {
        let url: URL

        if identifier.hasPrefix("/") {
            // Absolute path
            url = URL(fileURLWithPath: identifier)
        } else if identifier.hasPrefix("./") || identifier.hasPrefix("../") {
            // Relative path
            url = URL(fileURLWithPath: identifier).standardizedFileURL
        } else {
            return nil
        }

        // Check if directory exists and has config.json
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }

        let configPath = url.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            return nil
        }

        return ResolvedModel(
            canonicalId: identifier,
            modelPath: url,
            source: "local"
        )
    }

    private func tryHuggingFaceCache(_ repoId: String, requestedId: String) -> ResolvedModel? {
        // HuggingFace cache structure:
        // ~/.cache/huggingface/hub/models--{org}--{model}/snapshots/{revision}/

        // Convert repo ID to cache directory name
        // "meta-llama/Llama-3.1-8B-Instruct" -> "models--meta-llama--Llama-3.1-8B-Instruct"
        let cacheDirName = "models--" + repoId.replacingOccurrences(of: "/", with: "--")
        let modelCacheDir = hfCacheDir.appendingPathComponent(cacheDirName)

        guard FileManager.default.fileExists(atPath: modelCacheDir.path) else {
            return nil
        }

        // Find the latest snapshot
        let snapshotsDir = modelCacheDir.appendingPathComponent("snapshots")
        guard FileManager.default.fileExists(atPath: snapshotsDir.path) else {
            return nil
        }

        // Get all snapshot directories
        guard let snapshots = try? FileManager.default.contentsOfDirectory(
            at: snapshotsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        // Find the most recent snapshot that has config.json
        var bestSnapshot: URL?
        var bestDate: Date?

        for snapshot in snapshots {
            let configPath = snapshot.appendingPathComponent("config.json")
            guard FileManager.default.fileExists(atPath: configPath.path) else {
                continue
            }

            // Get modification date
            if let attrs = try? FileManager.default.attributesOfItem(atPath: snapshot.path),
               let modDate = attrs[.modificationDate] as? Date {
                if bestDate == nil || modDate > bestDate! {
                    bestDate = modDate
                    bestSnapshot = snapshot
                }
            } else if bestSnapshot == nil {
                // Use first valid snapshot if we can't get dates
                bestSnapshot = snapshot
            }
        }

        guard let modelPath = bestSnapshot else {
            return nil
        }

        return ResolvedModel(
            canonicalId: requestedId,
            modelPath: modelPath,
            source: "hf_cache"
        )
    }
}
