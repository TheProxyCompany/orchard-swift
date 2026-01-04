import Foundation

/// Represents a capability input (coord, size) with name and payload bytes
public struct CapabilityInput: Sendable {
    public let name: String
    public let payload: Data

    public init(name: String, payload: Data) {
        self.name = name
        self.payload = payload
    }
}

/// Wrapper for text content in multimodal messages
class RenderableText: CustomStringConvertible {
    let text: String
    var type: String { "text" }

    init(_ text: String) {
        self.text = text
    }

    var description: String { text }
}

/// Wrapper for image content in multimodal messages
class RenderableImage: CustomStringConvertible {
    var type: String { "image" }
    var description: String { "" }
}

/// Wrapper for capability content in multimodal messages
class RenderableCapability: CustomStringConvertible {
    var type: String { "capability" }
    var description: String { "" }
}

/// Regex pattern for base64 data URLs
private let dataURLPattern = try! NSRegularExpression(
    pattern: #"^data:(?<mime>[\w\-/+.]+);base64,(?<data>[A-Za-z0-9+/=]+)$"#
)

/// Decode base64 image data from a data URL
func decodeImagePayload(_ dataURL: String) throws -> Data {
    let range = NSRange(dataURL.startIndex..., in: dataURL)
    guard let match = dataURLPattern.firstMatch(in: dataURL, range: range) else {
        throw MultimodalError.invalidDataURL
    }

    let dataRange = match.range(withName: "data")
    guard dataRange.location != NSNotFound,
          let swiftRange = Range(dataRange, in: dataURL) else {
        throw MultimodalError.invalidDataURL
    }

    let base64Data = String(dataURL[swiftRange])
    guard let data = Data(base64Encoded: base64Data) else {
        throw MultimodalError.invalidBase64
    }

    return data
}

/// Normalize a role name to a standard form
func normalizeRole(_ rawRole: String?, availableRoles: Set<String>) -> String {
    guard let rawRole = rawRole else { return "user" }

    let roleLower = rawRole.lowercased()
    let aliasMap: [String: String] = [
        "assistant": "agent",
        "model": "agent",
        "developer": "system"
    ]

    return aliasMap[roleLower] ?? roleLower
}

/// Build multimodal messages for template rendering
/// - Returns: Tuple of (messages, imageBuffers, capabilities, contentOrder)
public func buildMultimodalMessages(
    formatter: ChatFormatter,
    items: [[String: Any]],
    instructions: String? = nil
) throws -> ([[String: Any]], [Data], [CapabilityInput], [(String, Int)]) {
    let rolesDict = formatter.controlTokens.roles.toDict()
    let availableRoles = Set(rolesDict.keys)

    var messages: [[String: Any]] = []
    var imageBuffers: [Data] = []
    var capabilities: [CapabilityInput] = []
    var contentOrder: [(String, Int)] = []

    // Add system instructions if provided
    if let instructions = instructions {
        let systemRole = availableRoles.contains("system") ? "system" : normalizeRole("system", availableRoles: availableRoles)
        messages.append(["role": systemRole, "content": instructions])
    }

    for (messageIndex, message) in items.enumerated() {
        let role = normalizeRole(message["role"] as? String, availableRoles: availableRoles)
        let content = message["content"]

        // Simple string content
        if let stringContent = content as? String {
            messages.append(["role": role, "content": stringContent])
            continue
        }

        // Array content (multimodal)
        guard let arrayContent = content as? [[String: Any]] else {
            throw MultimodalError.invalidContentType(messageIndex)
        }

        var parts: [Any] = []

        for (partIndex, contentPart) in arrayContent.enumerated() {
            guard let partType = contentPart["type"] as? String else {
                throw MultimodalError.missingType(messageIndex, partIndex)
            }

            let normalizedType = partType.lowercased()

            switch normalizedType {
            case "input_text", "text":
                guard let text = contentPart["text"] as? String else {
                    throw MultimodalError.missingText(messageIndex, partIndex)
                }
                parts.append(RenderableText(text))

            case "input_image", "image", "image_url":
                var imageURL: String?
                if let url = contentPart["image_url"] as? String {
                    imageURL = url
                } else if let urlDict = contentPart["image_url"] as? [String: Any] {
                    imageURL = urlDict["url"] as? String ?? urlDict["data"] as? String
                }

                guard let imageURL = imageURL else {
                    throw MultimodalError.missingImageURL(messageIndex, partIndex)
                }

                let decodedBytes = try decodeImagePayload(imageURL)
                contentOrder.append(("image", imageBuffers.count))
                imageBuffers.append(decodedBytes)
                parts.append(RenderableImage())

            case "capability":
                guard let name = contentPart["name"] as? String else {
                    throw MultimodalError.missingCapabilityName(messageIndex, partIndex)
                }
                guard let data = contentPart["data"] as? [Double] else {
                    throw MultimodalError.missingCapabilityData(messageIndex, partIndex)
                }

                // Pack floats as little-endian
                var payload = Data()
                for value in data {
                    var float = Float(value)
                    payload.append(Data(bytes: &float, count: 4))
                }

                contentOrder.append(("capability", capabilities.count))
                capabilities.append(CapabilityInput(name: name, payload: payload))
                parts.append(RenderableCapability())

            default:
                throw MultimodalError.unsupportedContentType(partType)
            }
        }

        messages.append(["role": role, "content": parts])
    }

    return (messages, imageBuffers, capabilities, contentOrder)
}

/// Build the multimodal layout for PIE
public func buildMultimodalLayout(
    promptText: String,
    imageBuffers: [Data],
    capabilities: [CapabilityInput],
    contentOrder: [(String, Int)],
    placeholderToken: String,
    excludeImagePlaceholder: Bool,
    coordPlaceholder: String? = nil
) throws -> [[String: Any]] {
    var layout: [[String: Any]] = []

    // Text-only case
    if imageBuffers.isEmpty && capabilities.isEmpty {
        let textBytes = promptText.data(using: .utf8)!
        guard !textBytes.isEmpty else {
            throw MultimodalError.emptyPrompt
        }
        layout.append(["type": "text", "length": textBytes.count])
        return layout
    }

    // Find image placeholder positions
    let imageMatches: [Range<String.Index>]
    if imageBuffers.isEmpty {
        imageMatches = []
    } else {
        imageMatches = promptText.ranges(of: placeholderToken)
    }

    guard imageMatches.count == imageBuffers.count else {
        throw MultimodalError.placeholderMismatch(imageMatches.count, imageBuffers.count)
    }

    // Check for coord placeholders
    let coordPlaceholderToken = coordPlaceholder ?? "<|coord|>"
    let coordMatches = promptText.ranges(of: coordPlaceholderToken)
    let useCoordPlaceholders = !coordMatches.isEmpty

    if useCoordPlaceholders {
        // Build layout using placeholder positions
        let coordCapabilities = capabilities.filter { $0.name == "coord" }
        guard coordMatches.count == coordCapabilities.count else {
            throw MultimodalError.coordPlaceholderMismatch(coordMatches.count, coordCapabilities.count)
        }

        // Combine all placeholders
        var allPlaceholders: [(start: String.Index, end: String.Index, type: String, index: Int)] = []

        for (idx, range) in imageMatches.enumerated() {
            allPlaceholders.append((range.lowerBound, range.upperBound, "image", idx))
        }

        for (idx, range) in coordMatches.enumerated() {
            allPlaceholders.append((range.lowerBound, range.upperBound, "coord", idx))
        }

        // Sort by position
        allPlaceholders.sort { $0.start < $1.start }

        var cursor = promptText.startIndex
        var coordCapIdx = 0

        for placeholder in allPlaceholders {
            // Add text before this placeholder
            let textEnd: String.Index
            if placeholder.type == "image" && !excludeImagePlaceholder {
                textEnd = placeholder.end
            } else {
                textEnd = placeholder.start
            }

            let textSegment = String(promptText[cursor..<textEnd])
            let segmentBytes = textSegment.data(using: .utf8)!
            if !segmentBytes.isEmpty {
                layout.append(["type": "text", "length": segmentBytes.count])
            }

            // Add placeholder content
            if placeholder.type == "image" {
                layout.append(["type": "image", "length": imageBuffers[placeholder.index].count])
            } else {
                let cap = coordCapabilities[coordCapIdx]
                layout.append([
                    "type": "capability",
                    "name": cap.name,
                    "length": cap.payload.count
                ])
                coordCapIdx += 1
            }

            cursor = placeholder.end
        }

        // Add remaining text
        if cursor < promptText.endIndex {
            let tailSegment = String(promptText[cursor...])
            let tailBytes = tailSegment.data(using: .utf8)!
            if !tailBytes.isEmpty {
                layout.append(["type": "text", "length": tailBytes.count])
            }
        }
    } else {
        // Original behavior: use contentOrder
        var cursor = promptText.startIndex
        var imageIdx = 0
        var capIdx = 0

        for (contentType, _) in contentOrder {
            if contentType == "image" {
                // Add text before this image
                let match = imageMatches[imageIdx]
                let textEnd = excludeImagePlaceholder ? match.lowerBound : match.upperBound
                let textSegment = String(promptText[cursor..<textEnd])
                let segmentBytes = textSegment.data(using: .utf8)!
                if !segmentBytes.isEmpty {
                    layout.append(["type": "text", "length": segmentBytes.count])
                }

                // Add image
                layout.append(["type": "image", "length": imageBuffers[imageIdx].count])
                cursor = match.upperBound
                imageIdx += 1

            } else if contentType == "capability" {
                let cap = capabilities[capIdx]
                layout.append([
                    "type": "capability",
                    "name": cap.name,
                    "length": cap.payload.count
                ])
                capIdx += 1
            }
        }

        // Add remaining text
        if cursor < promptText.endIndex {
            let tailSegment = String(promptText[cursor...])
            let tailBytes = tailSegment.data(using: .utf8)!
            if !tailBytes.isEmpty {
                layout.append(["type": "text", "length": tailBytes.count])
            }
        }
    }

    guard !layout.isEmpty else {
        throw MultimodalError.emptyPrompt
    }

    return layout
}

// MARK: - String Extension

extension String {
    func ranges(of substring: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchRange = startIndex..<endIndex

        while let range = self.range(of: substring, range: searchRange) {
            ranges.append(range)
            searchRange = range.upperBound..<endIndex
        }

        return ranges
    }
}

// MARK: - Errors

public enum MultimodalError: Error, LocalizedError {
    case invalidDataURL
    case invalidBase64
    case invalidContentType(Int)
    case missingType(Int, Int)
    case missingText(Int, Int)
    case missingImageURL(Int, Int)
    case missingCapabilityName(Int, Int)
    case missingCapabilityData(Int, Int)
    case unsupportedContentType(String)
    case emptyPrompt
    case placeholderMismatch(Int, Int)
    case coordPlaceholderMismatch(Int, Int)

    public var errorDescription: String? {
        switch self {
        case .invalidDataURL:
            return "Invalid image data URL format"
        case .invalidBase64:
            return "Invalid base64-encoded image content"
        case .invalidContentType(let msg):
            return "Message \(msg) content must be string or array"
        case .missingType(let msg, let part):
            return "Content part \(part) in message \(msg) missing 'type'"
        case .missingText(let msg, let part):
            return "Text content missing for part \(part) in message \(msg)"
        case .missingImageURL(let msg, let part):
            return "Image URL missing for part \(part) in message \(msg)"
        case .missingCapabilityName(let msg, let part):
            return "Capability name missing for part \(part) in message \(msg)"
        case .missingCapabilityData(let msg, let part):
            return "Capability data missing for part \(part) in message \(msg)"
        case .unsupportedContentType(let type):
            return "Unsupported content type: \(type)"
        case .emptyPrompt:
            return "Request must include at least one content segment"
        case .placeholderMismatch(let found, let expected):
            return "Image placeholder mismatch: found \(found), expected \(expected)"
        case .coordPlaceholderMismatch(let found, let expected):
            return "Coord placeholder mismatch: found \(found), expected \(expected)"
        }
    }
}
