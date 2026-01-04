import Foundation

/// Role configuration for chat templates
public struct Role: Codable, Sendable {
    public let roleName: String
    public let roleStartTag: String
    public let roleEndTag: String

    enum CodingKeys: String, CodingKey {
        case roleName = "role_name"
        case roleStartTag = "role_start_tag"
        case roleEndTag = "role_end_tag"
    }
}

/// Collection of role tags for different message types
public struct RoleTags: Codable, Sendable {
    public let system: Role?
    public let agent: Role?
    public let user: Role?
    public let tool: Role?

    public func role(for name: String) -> Role? {
        switch name {
        case "system": return system
        case "agent", "assistant": return agent
        case "user": return user
        case "tool", "ipython": return tool
        default: return nil
        }
    }

    public func toDict() -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]

        if let system = system {
            result["system"] = [
                "role_name": system.roleName,
                "role_start_tag": system.roleStartTag,
                "role_end_tag": system.roleEndTag
            ]
        }
        if let agent = agent {
            result["agent"] = [
                "role_name": agent.roleName,
                "role_start_tag": agent.roleStartTag,
                "role_end_tag": agent.roleEndTag
            ]
        }
        if let user = user {
            result["user"] = [
                "role_name": user.roleName,
                "role_start_tag": user.roleStartTag,
                "role_end_tag": user.roleEndTag
            ]
        }
        if let tool = tool {
            result["tool"] = [
                "role_name": tool.roleName,
                "role_start_tag": tool.roleStartTag,
                "role_end_tag": tool.roleEndTag
            ]
        }

        return result
    }
}

/// Control tokens for different model templates
public struct ControlTokens: Codable, Sendable {
    public let templateType: String
    public let beginOfText: String
    public let endOfMessage: String
    public let endOfSequence: String
    public let startImageToken: String?
    public let endImageToken: String?
    public let thinkingStartToken: String?
    public let thinkingEndToken: String?
    public let coordPlaceholder: String?
    public let capabilities: [String: String]
    public let roles: RoleTags

    enum CodingKeys: String, CodingKey {
        case templateType = "template_type"
        case beginOfText = "begin_of_text"
        case endOfMessage = "end_of_message"
        case endOfSequence = "end_of_sequence"
        case startImageToken = "start_image_token"
        case endImageToken = "end_image_token"
        case thinkingStartToken = "thinking_start_token"
        case thinkingEndToken = "thinking_end_token"
        case coordPlaceholder = "coord_placeholder"
        case capabilities
        case roles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        templateType = try container.decode(String.self, forKey: .templateType)
        beginOfText = try container.decode(String.self, forKey: .beginOfText)
        endOfMessage = try container.decode(String.self, forKey: .endOfMessage)
        endOfSequence = try container.decode(String.self, forKey: .endOfSequence)
        startImageToken = try container.decodeIfPresent(String.self, forKey: .startImageToken)
        endImageToken = try container.decodeIfPresent(String.self, forKey: .endImageToken)
        thinkingStartToken = try container.decodeIfPresent(String.self, forKey: .thinkingStartToken)
        thinkingEndToken = try container.decodeIfPresent(String.self, forKey: .thinkingEndToken)
        coordPlaceholder = try container.decodeIfPresent(String.self, forKey: .coordPlaceholder)
        capabilities = try container.decodeIfPresent([String: String].self, forKey: .capabilities) ?? [:]
        roles = try container.decode(RoleTags.self, forKey: .roles)
    }
}

/// Load control tokens from a profile directory
public func loadControlTokens(profileDir: URL) throws -> ControlTokens {
    let path = profileDir.appendingPathComponent("control_tokens.json")
    let data = try Data(contentsOf: path)
    return try JSONDecoder().decode(ControlTokens.self, from: data)
}
