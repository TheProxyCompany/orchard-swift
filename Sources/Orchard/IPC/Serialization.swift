import Foundation

/// Wire protocol constants matching C++ SerializedSegmentType
enum SegmentType: UInt8 {
    case text = 0
    case image = 1
    case capability = 2
}

/// Request type codes matching PIE
enum RequestType: Int {
    case generation = 0
    case embedding = 1
    case query = 2
    case point = 3
    case detect = 4
    case agent = 5
    case omni = 6

    init?(string: String) {
        switch string.lowercased() {
        case "generation": self = .generation
        case "embedding": self = .embedding
        case "query": self = .query
        case "point": self = .point
        case "detect": self = .detect
        case "agent": self = .agent
        case "omni": self = .omni
        default: return nil
        }
    }
}

/// Binary serialization for PIE IPC protocol.
///
/// Wire format: [4 bytes: metadata length][JSON metadata][16-byte aligned binary blobs]
enum Serialization {
    static let payloadAlignment = 16
    static let layoutSegmentSize = 16  // 1 byte type + 7 padding + 8 bytes length
    static let imageSpanSize = 8       // 8 bytes for length

    /// Align offset to payload alignment boundary
    static func align(_ offset: Int) -> Int {
        let remainder = offset % payloadAlignment
        return remainder == 0 ? offset : offset + (payloadAlignment - remainder)
    }

    /// Build a request payload for PIE
    static func buildRequestPayload(
        requestId: UInt64,
        modelId: String,
        modelPath: String,
        requestType: RequestType,
        responseChannelId: UInt64,
        prompts: [[String: Any]],
        requestChannelId: UInt64 = 0,
        parentRequestId: UInt64? = nil
    ) throws -> Data {
        guard !prompts.isEmpty else {
            throw SerializationError.noPrompts
        }

        let parentId = parentRequestId ?? requestId

        var metadata: [String: Any] = [
            "request_id": parentId,
            "model_id": modelId,
            "model_path": modelPath,
            "request_type": requestType.rawValue,
            "request_channel_id": requestChannelId,
            "response_channel_id": responseChannelId,
        ]

        var metadataPrompts: [[String: Any]] = []
        var blobFragments: [(offset: Int, data: Data)] = []
        var totalSize = 0

        func reserveBlob(_ data: Data) -> (offset: Int, size: Int) {
            guard !data.isEmpty else { return (0, 0) }
            totalSize = align(totalSize)
            let offset = totalSize
            blobFragments.append((offset, data))
            totalSize += data.count
            return (offset, data.count)
        }

        for (index, prompt) in prompts.enumerated() {
            // Extract text
            let textData: Data
            if let bytes = prompt["prompt_bytes"] as? Data {
                textData = bytes
            } else if let text = prompt["prompt"] as? String {
                textData = Data(text.utf8)
            } else {
                textData = Data()
            }

            // Extract images
            let imageBuffers = (prompt["image_buffers"] as? [Data]) ?? []
            let (imageSpanData, imageDataBytes) = encodeImageBuffers(imageBuffers)

            // Extract capabilities
            let capabilities = (prompt["capabilities"] as? [[String: Any]]) ?? []
            let (capabilityMetadata, capabilityData) = encodeCapabilities(capabilities)

            // Encode layout
            let layout = (prompt["layout"] as? [[String: Any]]) ?? []
            let layoutData = try encodeLayout(layout, textLength: textData.count, imageBuffers: imageBuffers)

            // Reserve blobs
            let (textOffset, textSize) = reserveBlob(textData)
            let (imageSizesOffset, _) = reserveBlob(imageSpanData)
            let (imageDataOffset, imageDataSize) = reserveBlob(imageDataBytes)
            let (capabilityDataOffset, capabilityDataSize) = reserveBlob(capabilityData)
            let (layoutOffset, _) = reserveBlob(layoutData)

            // Extract parameters
            let samplingParams = (prompt["sampling_params"] as? [String: Any]) ?? [:]
            let logitsParams = (prompt["logits_params"] as? [String: Any]) ?? [:]

            let temperature = (samplingParams["temperature"] as? Double) ?? 1.0
            let topP = (samplingParams["top_p"] as? Double) ?? 1.0
            let topK = (samplingParams["top_k"] as? Int) ?? -1
            let minP = (samplingParams["min_p"] as? Double) ?? 0.0
            let rngSeed = UInt32(truncatingIfNeeded: (samplingParams["rng_seed"] as? Int) ?? 0)

            let topLogprobs = (logitsParams["top_logprobs"] as? Int) ?? 0
            let frequencyPenalty = (logitsParams["frequency_penalty"] as? Double) ?? 0.0
            let presencePenalty = (logitsParams["presence_penalty"] as? Double) ?? 0.0
            let repetitionContextSize = (logitsParams["repetition_context_size"] as? Int) ?? 0
            let repetitionPenalty = (logitsParams["repetition_penalty"] as? Double) ?? 1.0

            let maxGeneratedTokens = (prompt["max_generated_tokens"] as? Int) ?? 0
            let numCandidates = max(1, (prompt["num_candidates"] as? Int) ?? 1)
            let bestOf = (prompt["best_of"] as? Int) ?? numCandidates
            let finalCandidates = (prompt["final_candidates"] as? Int) ?? bestOf

            let stopSequences = (prompt["stop_sequences"] as? [String]) ?? []
            let toolSchemasJson = (prompt["tool_schemas_json"] as? String) ?? ""
            let responseFormatJson = (prompt["response_format_json"] as? String) ?? ""
            let taskName = prompt["task_name"] as? String
            let reasoningEffort = prompt["reasoning_effort"] as? String

            // Build logit bias entries
            var logitBiasEntries: [[String: Any]] = []
            if let logitBias = logitsParams["logit_bias"] as? [String: Double] {
                for (token, bias) in logitBias {
                    if let tokenInt = Int(token) {
                        logitBiasEntries.append(["token": tokenInt, "bias": bias])
                    }
                }
            }

            var promptMetadata: [String: Any] = [
                "prompt_index": index,
                "num_candidates": numCandidates,
                "best_of": bestOf,
                "final_candidates": finalCandidates,
                "max_generated_tokens": maxGeneratedTokens,
                "text_offset": textOffset,
                "text_size": textSize,
                "image_data_offset": imageDataOffset,
                "image_data_size": imageDataSize,
                "image_sizes_offset": imageSizesOffset,
                "image_count": imageBuffers.count,
                "capability_data_offset": capabilityDataOffset,
                "capability_data_size": capabilityDataSize,
                "capabilities": capabilityMetadata,
                "layout_offset": layoutOffset,
                "layout_count": layoutData.count / layoutSegmentSize,
                "temperature": temperature,
                "top_p": topP,
                "top_k": topK,
                "min_p": minP,
                "rng_seed": rngSeed,
                "top_logprobs": topLogprobs,
                "frequency_penalty": frequencyPenalty,
                "presence_penalty": presencePenalty,
                "repetition_context_size": repetitionContextSize,
                "repetition_penalty": repetitionPenalty,
                "stop_sequences": stopSequences,
                "tool_schemas_json": toolSchemasJson,
                "response_format_json": responseFormatJson,
                "logit_bias": logitBiasEntries,
            ]

            if let taskName = taskName {
                promptMetadata["task_name"] = taskName
            }
            if let reasoningEffort = reasoningEffort {
                promptMetadata["reasoning_effort"] = reasoningEffort
            }

            metadataPrompts.append(promptMetadata)
        }

        metadata["prompts"] = metadataPrompts

        // Build payload buffer
        var payload = Data(count: totalSize)
        for (offset, data) in blobFragments {
            payload.replaceSubrange(offset..<(offset + data.count), with: data)
        }

        // Encode metadata as JSON
        let metadataBytes = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])

        guard metadataBytes.count <= UInt32.max else {
            throw SerializationError.metadataTooLarge
        }

        // Frame: [4 bytes length][metadata][payload]
        var frame = Data(capacity: 4 + metadataBytes.count + payload.count)
        var length = UInt32(metadataBytes.count).littleEndian
        frame.append(Data(bytes: &length, count: 4))
        frame.append(metadataBytes)
        frame.append(payload)

        return frame
    }

    /// Encode image buffers into span metadata and concatenated data
    private static func encodeImageBuffers(_ buffers: [Data]) -> (spans: Data, data: Data) {
        guard !buffers.isEmpty else { return (Data(), Data()) }

        var spanBuffer = Data(capacity: buffers.count * imageSpanSize)
        var dataBuffer = Data(capacity: buffers.reduce(0) { $0 + $1.count })

        for buffer in buffers {
            var size = UInt64(buffer.count).littleEndian
            spanBuffer.append(Data(bytes: &size, count: 8))
            dataBuffer.append(buffer)
        }

        return (spanBuffer, dataBuffer)
    }

    /// Encode capability entries
    private static func encodeCapabilities(_ capabilities: [[String: Any]]) -> (metadata: [[String: Any]], data: Data) {
        guard !capabilities.isEmpty else { return ([], Data()) }

        var metadataList: [[String: Any]] = []
        var dataBuffer = Data()

        for cap in capabilities {
            let name = (cap["name"] as? String) ?? ""
            let payload = (cap["payload"] as? Data) ?? Data()
            let position = (cap["position"] as? Int) ?? 0

            metadataList.append([
                "name": name,
                "position": position,
                "payload_size": payload.count,
            ])
            dataBuffer.append(payload)
        }

        return (metadataList, dataBuffer)
    }

    /// Encode layout segments
    private static func encodeLayout(_ layout: [[String: Any]], textLength: Int, imageBuffers: [Data]) throws -> Data {
        var segments: [(type: SegmentType, length: Int)] = []

        if layout.isEmpty {
            if textLength > 0 {
                segments.append((.text, textLength))
            }
            for image in imageBuffers {
                segments.append((.image, image.count))
            }
        } else {
            for segment in layout {
                let typeStr = (segment["type"] as? String)?.lowercased() ?? "text"
                let length = (segment["length"] as? Int) ?? 0

                switch typeStr {
                case "text":
                    segments.append((.text, length))
                case "image":
                    segments.append((.image, length))
                case "capability":
                    segments.append((.capability, 0))
                default:
                    throw SerializationError.unsupportedSegmentType(typeStr)
                }
            }
        }

        guard !segments.isEmpty else { return Data() }

        // Validate lengths
        let layoutTextBytes = segments.filter { $0.type == .text }.reduce(0) { $0 + $1.length }
        let layoutImageBytes = segments.filter { $0.type == .image }.reduce(0) { $0 + $1.length }
        let totalImageBytes = imageBuffers.reduce(0) { $0 + $1.count }

        guard layoutTextBytes == textLength else {
            throw SerializationError.layoutMismatch("text", expected: textLength, got: layoutTextBytes)
        }
        guard layoutImageBytes == totalImageBytes else {
            throw SerializationError.layoutMismatch("image", expected: totalImageBytes, got: layoutImageBytes)
        }

        // Pack segments: 1 byte type + 7 bytes padding + 8 bytes length
        var buffer = Data(capacity: segments.count * layoutSegmentSize)
        for (type, length) in segments {
            buffer.append(type.rawValue)
            buffer.append(contentsOf: [UInt8](repeating: 0, count: 7))
            var len = UInt64(length).littleEndian
            buffer.append(Data(bytes: &len, count: 8))
        }

        return buffer
    }
}

enum SerializationError: Error, CustomStringConvertible {
    case noPrompts
    case metadataTooLarge
    case unsupportedSegmentType(String)
    case layoutMismatch(String, expected: Int, got: Int)

    var description: String {
        switch self {
        case .noPrompts:
            return "At least one prompt is required"
        case .metadataTooLarge:
            return "Metadata exceeds 4-byte length prefix capacity"
        case .unsupportedSegmentType(let type):
            return "Unsupported layout segment type: \(type)"
        case .layoutMismatch(let kind, let expected, let got):
            return "Layout \(kind) length mismatch (expected \(expected), got \(got))"
        }
    }
}
