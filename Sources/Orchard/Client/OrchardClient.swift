import Foundation

/// High-level client for the Proxy Inference Engine (PIE)
public final class OrchardClient: @unchecked Sendable {
    private let ipcState: IPCState
    private let modelRegistry: ModelRegistry
    private let defaultModelId: String?

    /// For synchronous API
    private var syncQueue: DispatchQueue?

    public init(ipcState: IPCState, modelRegistry: ModelRegistry, defaultModelId: String? = nil) {
        self.ipcState = ipcState
        self.modelRegistry = modelRegistry
        self.defaultModelId = defaultModelId
    }

    // MARK: - Async API

    /// Asynchronously perform a chat completion
    /// - Parameters:
    ///   - modelId: Model to use for generation
    ///   - messages: Single conversation (array of message dicts) or batch (array of conversations)
    ///   - params: Generation parameters
    /// - Returns: ClientResponse for single, array of ClientResponse for batch
    public func achat(
        modelId: String? = nil,
        messages: [[String: Any]],
        params: ChatParameters = ChatParameters()
    ) async throws -> ClientResponse {
        let responses = try await achatBatch(
            modelId: modelId,
            conversations: [messages],
            params: params
        )
        return responses[0]
    }

    /// Asynchronously perform a batch chat completion
    public func achatBatch(
        modelId: String? = nil,
        conversations: [[[String: Any]]],
        params: ChatParameters = ChatParameters()
    ) async throws -> [ClientResponse] {
        let resolvedModelId = modelId ?? defaultModelId
        guard let resolvedModelId = resolvedModelId else {
            throw ClientError.noModelSpecified
        }

        let requestId = ipcState.nextRequestId()

        // Get model info
        let info = try await modelRegistry.getInfo(resolvedModelId)

        // Build prompts for each conversation
        var promptPayloads: [[String: Any]] = []

        for messages in conversations {
            let prompt = try buildPromptPayload(
                messages: messages,
                info: info,
                params: params
            )
            promptPayloads.append(prompt)
        }

        // Create response stream
        let stream = AsyncStream<ResponseDelta> { continuation in
            ipcState.registerQueue(requestId: requestId, continuation: continuation)

            continuation.onTermination = { [weak self] _ in
                self?.ipcState.unregisterQueue(requestId: requestId)
            }
        }

        // Send request
        try ipcState.sendRequest(
            requestId: requestId,
            modelId: resolvedModelId,
            modelPath: info.modelPath,
            prompts: promptPayloads
        )

        // Collect all deltas
        var allDeltas: [ClientDelta] = []
        for await delta in stream {
            let clientDelta = ClientDelta(from: delta.toDict())
            allDeltas.append(clientDelta)
        }

        // Aggregate into responses
        return aggregateBatchResponse(deltas: allDeltas, batchSize: conversations.count)
    }

    /// Stream chat completion as async sequence
    public func achatStream(
        modelId: String? = nil,
        messages: [[String: Any]],
        params: ChatParameters = ChatParameters()
    ) async throws -> AsyncStream<ClientDelta> {
        let resolvedModelId = modelId ?? defaultModelId
        guard let resolvedModelId = resolvedModelId else {
            throw ClientError.noModelSpecified
        }

        let requestId = ipcState.nextRequestId()

        // Get model info
        let info = try await modelRegistry.getInfo(resolvedModelId)

        // Build prompt
        let promptPayload = try buildPromptPayload(
            messages: messages,
            info: info,
            params: params
        )

        // Create response stream
        let stream = AsyncStream<ClientDelta> { continuation in
            let innerStream = AsyncStream<ResponseDelta> { innerContinuation in
                ipcState.registerQueue(requestId: requestId, continuation: innerContinuation)

                innerContinuation.onTermination = { [weak self] _ in
                    self?.ipcState.unregisterQueue(requestId: requestId)
                }
            }

            Task {
                for await delta in innerStream {
                    let clientDelta = ClientDelta(from: delta.toDict())
                    continuation.yield(clientDelta)
                    if clientDelta.isFinal {
                        break
                    }
                }
                continuation.finish()
            }
        }

        // Send request
        try ipcState.sendRequest(
            requestId: requestId,
            modelId: resolvedModelId,
            modelPath: info.modelPath,
            prompts: [promptPayload]
        )

        return stream
    }


    /// Resolve control token capabilities for a model
    public func resolveCapabilities(modelId: String) throws -> [String: Int] {
        let info = try modelRegistry.ensureReadySync(modelId)
        let capabilities = info.capabilities ?? [:]

        var resolved: [String: Int] = [:]
        for (name, tokenIds) in capabilities {
            if let first = tokenIds.first {
                resolved[name] = first
            }
        }
        return resolved
    }

    // MARK: - Private

    private func buildPromptPayload(
        messages: [[String: Any]],
        info: ModelInfo,
        params: ChatParameters
    ) throws -> [String: Any] {
        // Build multimodal messages
        let (messagesForTemplate, imageBuffers, capabilities, contentOrder) = try buildMultimodalMessages(
            formatter: info.formatter,
            items: messages,
            instructions: params.instructions
        )

        // Apply template
        let reasoningFlag = params.reasoning || params.reasoningEffort != nil
        var promptText = info.formatter.applyTemplate(
            messagesForTemplate,
            addGenerationPrompt: true,
            reasoning: reasoningFlag,
            task: params.taskName
        )

        // Build layout
        let layoutSegments = try buildMultimodalLayout(
            promptText: promptText,
            imageBuffers: imageBuffers,
            capabilities: capabilities,
            contentOrder: contentOrder,
            placeholderToken: info.formatter.controlTokens.startImageToken ?? info.formatter.defaultImagePlaceholder,
            excludeImagePlaceholder: info.formatter.shouldClipImagePlaceholder,
            coordPlaceholder: info.formatter.controlTokens.coordPlaceholder
        )

        // Clean up prompt text
        if info.formatter.shouldClipImagePlaceholder {
            promptText = promptText.replacingOccurrences(of: info.formatter.defaultImagePlaceholder, with: "")
        }
        if let coordPlaceholder = info.formatter.controlTokens.coordPlaceholder {
            promptText = promptText.replacingOccurrences(of: coordPlaceholder, with: "")
        }

        let promptBytes = promptText.data(using: .utf8)!

        // Build capabilities payload
        let capabilitiesPayload = capabilities.map { cap -> [String: Any] in
            [
                "name": cap.name,
                "payload": cap.payload,
                "position": 0
            ]
        }

        // Build logit bias entries
        let logitBiasEntries = params.logitBias.map { (token, bias) -> [String: Any] in
            ["token": token, "bias": bias]
        }

        let rngSeed = params.rngSeed ?? UInt32.random(in: 0...UInt32.max)
        let numCandidates = max(1, params.n)
        let bestOf = params.bestOf <= 0 ? numCandidates : params.bestOf
        let finalCandidates = params.finalCandidates <= 0 ? bestOf : params.finalCandidates

        var promptPayload: [String: Any] = [
            "prompt_bytes": promptBytes,
            "image_buffers": imageBuffers,
            "capabilities": capabilitiesPayload,
            "layout": layoutSegments,
            "sampling_params": [
                "temperature": params.temperature,
                "top_p": params.topP,
                "top_k": params.topK,
                "min_p": params.minP,
                "rng_seed": rngSeed
            ],
            "logits_params": [
                "top_logprobs": params.topLogprobs,
                "frequency_penalty": params.frequencyPenalty,
                "presence_penalty": params.presencePenalty,
                "repetition_context_size": params.repetitionContextSize,
                "repetition_penalty": params.repetitionPenalty,
                "logit_bias": logitBiasEntries
            ],
            "max_generated_tokens": params.maxGeneratedTokens,
            "stop_sequences": params.stop,
            "num_candidates": numCandidates,
            "best_of": bestOf,
            "final_candidates": finalCandidates
        ]

        // Add optional fields
        if let tools = params.tools {
            promptPayload["tool_schemas_json"] = try serializeJSON(tools)
        }
        if let responseFormat = params.responseFormat {
            promptPayload["response_format_json"] = try serializeJSON(responseFormat)
        }
        if let taskName = params.taskName {
            promptPayload["task_name"] = taskName
        }
        if let reasoningEffort = params.reasoningEffort {
            promptPayload["reasoning_effort"] = reasoningEffort
        }

        return promptPayload
    }

    private func serializeJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func aggregateResponse(deltas: [ClientDelta]) -> ClientResponse {
        let text = deltas.compactMap { $0.content }.joined()
        let finishReason = deltas.reversed().first { $0.finishReason != nil }?.finishReason

        var usage = UsageStats()
        for delta in deltas {
            if let promptCount = delta.promptTokenCount {
                usage.promptTokens = max(usage.promptTokens, promptCount)
            }
            if let genLen = delta.generationLen {
                usage.completionTokens = max(usage.completionTokens, genLen)
            }
        }
        usage.totalTokens = usage.promptTokens + usage.completionTokens

        return ClientResponse(
            text: text,
            finishReason: finishReason,
            usage: usage,
            deltas: deltas
        )
    }

    private func aggregateBatchResponse(deltas: [ClientDelta], batchSize: Int) -> [ClientResponse] {
        // Group deltas by prompt index
        var deltasByPrompt: [[ClientDelta]] = Array(repeating: [], count: batchSize)

        for delta in deltas {
            let idx = delta.promptIndex ?? 0
            if idx < batchSize {
                deltasByPrompt[idx].append(delta)
            }
        }

        return deltasByPrompt.map { aggregateResponse(deltas: $0) }
    }
}

// MARK: - ResponseDelta Extension

extension ResponseDelta {
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "request_id": requestId,
            "is_final_delta": isFinalDelta
        ]
        if let content = content { dict["content"] = content }
        if let finishReason = finishReason { dict["finish_reason"] = finishReason }
        if let error = error { dict["error"] = error }
        return dict
    }
}

// MARK: - Errors

public enum ClientError: Error, LocalizedError {
    case noModelSpecified
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noModelSpecified:
            return "No model ID specified and no default model set"
        case .requestFailed(let reason):
            return "Request failed: \(reason)"
        }
    }
}
