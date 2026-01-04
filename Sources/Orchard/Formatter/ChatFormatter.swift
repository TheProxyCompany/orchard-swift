import Foundation

/// Determines the model type from config.json
func determineModelType(config: [String: Any]) -> String {
    let modelType = config["model_type"] as? String ?? "llama"

    switch modelType {
    case "llama", "llama3":
        return "llama3"
    case "moondream", "moondream3":
        return "moondream3"
    case "gemma", "gemma3":
        return "gemma3"
    default:
        return modelType
    }
}

/// Handles the application of chat templates to conversation histories
public final class ChatFormatter: @unchecked Sendable {
    public let modelPath: URL
    public let controlTokens: ControlTokens
    private let profileDir: URL

    /// Whether to clip the image placeholder from the prompt text
    public var shouldClipImagePlaceholder: Bool {
        guard let startToken = controlTokens.startImageToken else { return true }
        return startToken.isEmpty
    }

    /// Default image placeholder to use if model doesn't have a start image token
    public var defaultImagePlaceholder: String {
        "<|image|>"
    }

    public init(modelPath: String) throws {
        self.modelPath = URL(fileURLWithPath: modelPath)

        // Load config.json
        let configPath = self.modelPath.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            throw ChatFormatterError.configNotFound(modelPath)
        }

        let configData = try Data(contentsOf: configPath)
        guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw ChatFormatterError.invalidConfig
        }

        let modelType = determineModelType(config: config)

        // Find profile directory
        let profileDir = getProfileDirectory(for: modelType)
        guard FileManager.default.fileExists(atPath: profileDir.path) else {
            throw ChatFormatterError.profileNotFound(modelType)
        }
        self.profileDir = profileDir

        // Load control tokens
        self.controlTokens = try loadControlTokens(profileDir: profileDir)
    }

    /// Apply the chat template to a conversation
    public func applyTemplate(
        _ conversation: [[String: Any]],
        addGenerationPrompt: Bool = true,
        reasoning: Bool = false,
        task: String? = nil
    ) -> String {
        var output = controlTokens.beginOfText

        for interaction in conversation {
            output += renderInteraction(interaction)
        }

        if addGenerationPrompt {
            if let agent = controlTokens.roles.agent {
                output += agent.roleStartTag + agent.roleName + agent.roleEndTag
            }
        }

        return output
    }

    // MARK: - Private

    private func renderInteraction(_ interaction: [String: Any]) -> String {
        var result = ""

        let roleName = interaction["role"] as? String ?? "user"
        let role = controlTokens.roles.role(for: roleName)

        if let role = role {
            result += role.roleStartTag + role.roleName + role.roleEndTag
        }

        // Render content
        if let content = interaction["content"] {
            if let stringContent = content as? String {
                result += stringContent
            } else if let arrayContent = content as? [Any] {
                for item in arrayContent {
                    if let renderable = item as? CustomStringConvertible {
                        result += renderable.description
                    }
                }
            }
        }

        // Add end token
        result += controlTokens.endOfSequence

        return result
    }
}

// MARK: - Profile Directory

/// Get the profile directory for a model type
/// Profiles are bundled with the package or looked up from a known location
func getProfileDirectory(for modelType: String) -> URL {
    // Look in the orchard-py profiles directory (for development)
    let currentFile = URL(fileURLWithPath: #file)
    let packageRoot = currentFile
        .deletingLastPathComponent() // Formatter
        .deletingLastPathComponent() // Orchard
        .deletingLastPathComponent() // Sources
        .deletingLastPathComponent() // orchard-swift

    // Try orchard-py profiles
    let orchardPyProfiles = packageRoot
        .deletingLastPathComponent() // TheProxyCompany
        .appendingPathComponent("orchard-py/orchard/formatter/profiles")
        .appendingPathComponent(modelType)

    if FileManager.default.fileExists(atPath: orchardPyProfiles.path) {
        return orchardPyProfiles
    }

    // Final fallback
    return URL(fileURLWithPath: "/usr/local/share/orchard/profiles/\(modelType)")
}

// MARK: - Errors

public enum ChatFormatterError: Error, LocalizedError {
    case configNotFound(String)
    case invalidConfig
    case profileNotFound(String)
    case templateNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .configNotFound(let path):
            return "config.json not found in \(path)"
        case .invalidConfig:
            return "Invalid config.json format"
        case .profileNotFound(let modelType):
            return "Profile directory for model type '\(modelType)' not found"
        case .templateNotFound(let modelType):
            return "Chat template not found for model type '\(modelType)'"
        }
    }
}
