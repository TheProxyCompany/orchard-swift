import Foundation

/// Usage statistics for a completion request
public struct UsageStats: Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int

    public init(promptTokens: Int = 0, completionTokens: Int = 0) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = promptTokens + completionTokens
    }
}

/// A delta (incremental update) from a streaming completion
public struct ClientDelta: Sendable {
    public let requestId: UInt64
    public let sequenceId: Int?
    public let promptIndex: Int?
    public let candidateIndex: Int?
    public let promptTokenCount: Int?
    public let numTokensInDelta: Int?
    public let tokens: [Int]
    public let topLogprobs: [[String: Double]]
    public let cumulativeLogprob: Double?
    public let generationLen: Int?
    public let content: String?
    public let contentLen: Int?
    public let isFinal: Bool
    public let finishReason: String?
    public let error: String?

    public init(from json: [String: Any]) {
        self.requestId = (json["request_id"] as? UInt64)
            ?? (json["request_id"] as? Int).map { UInt64($0) }
            ?? 0
        self.sequenceId = json["sequence_id"] as? Int
        self.promptIndex = json["prompt_index"] as? Int
        self.candidateIndex = json["candidate_index"] as? Int
        self.promptTokenCount = json["prompt_token_count"] as? Int
        self.numTokensInDelta = json["num_tokens_in_delta"] as? Int
        self.tokens = json["tokens"] as? [Int] ?? []
        self.topLogprobs = json["top_logprobs"] as? [[String: Double]] ?? []
        self.cumulativeLogprob = json["cumulative_logprob"] as? Double
        self.generationLen = json["generation_len"] as? Int
        self.content = json["content"] as? String
        self.contentLen = json["content_len"] as? Int
        self.isFinal = (json["is_final_delta"] as? Bool) ?? false
        self.finishReason = json["finish_reason"] as? String
        self.error = json["error"] as? String
    }
}

/// The aggregated response from a non-streaming completion
public struct ClientResponse: Sendable {
    public let text: String
    public let finishReason: String?
    public let usage: UsageStats
    public let deltas: [ClientDelta]

    public init(text: String, finishReason: String? = nil, usage: UsageStats = UsageStats(), deltas: [ClientDelta] = []) {
        self.text = text
        self.finishReason = finishReason
        self.usage = usage
        self.deltas = deltas
    }
}

/// Parameters for chat completion requests
public struct ChatParameters {
    /// Maximum tokens to generate
    public var maxGeneratedTokens: Int

    /// Sampling temperature (0.0 = deterministic, 1.0 = default)
    public var temperature: Double

    /// Top-p (nucleus) sampling
    public var topP: Double

    /// Top-k sampling (-1 = disabled)
    public var topK: Int

    /// Minimum probability threshold
    public var minP: Double

    /// Random seed for sampling
    public var rngSeed: UInt32?

    /// Stop sequences
    public var stop: [String]

    /// Number of top logprobs to return per token
    public var topLogprobs: Int

    /// Frequency penalty (0.0 = disabled)
    public var frequencyPenalty: Double

    /// Presence penalty (0.0 = disabled)
    public var presencePenalty: Double

    /// Context size for repetition penalty
    public var repetitionContextSize: Int

    /// Repetition penalty (1.0 = disabled)
    public var repetitionPenalty: Double

    /// Logit bias map (token ID -> bias)
    public var logitBias: [Int: Double]

    /// Tool schemas for function calling
    public var tools: [[String: Any]]?

    /// Response format (for structured output)
    public var responseFormat: [String: Any]?

    /// Number of completions to generate
    public var n: Int

    /// Best-of sampling
    public var bestOf: Int

    /// Final number of candidates to return
    public var finalCandidates: Int

    /// Task name for task-specific formatting
    public var taskName: String?

    /// Reasoning mode
    public var reasoning: Bool

    /// Reasoning effort level
    public var reasoningEffort: String?

    /// System instructions (prepended to conversation)
    public var instructions: String?

    public init(
        maxGeneratedTokens: Int = 1024,
        temperature: Double = 1.0,
        topP: Double = 1.0,
        topK: Int = -1,
        minP: Double = 0.0,
        rngSeed: UInt32? = nil,
        stop: [String] = [],
        topLogprobs: Int = 0,
        frequencyPenalty: Double = 0.0,
        presencePenalty: Double = 0.0,
        repetitionContextSize: Int = 60,
        repetitionPenalty: Double = 1.0,
        logitBias: [Int: Double] = [:],
        tools: [[String: Any]]? = nil,
        responseFormat: [String: Any]? = nil,
        n: Int = 1,
        bestOf: Int = 1,
        finalCandidates: Int = 1,
        taskName: String? = nil,
        reasoning: Bool = false,
        reasoningEffort: String? = nil,
        instructions: String? = nil
    ) {
        self.maxGeneratedTokens = maxGeneratedTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.rngSeed = rngSeed
        self.stop = stop
        self.topLogprobs = topLogprobs
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.repetitionContextSize = repetitionContextSize
        self.repetitionPenalty = repetitionPenalty
        self.logitBias = logitBias
        self.tools = tools
        self.responseFormat = responseFormat
        self.n = n
        self.bestOf = bestOf
        self.finalCandidates = finalCandidates
        self.taskName = taskName
        self.reasoning = reasoning
        self.reasoningEffort = reasoningEffort
        self.instructions = instructions
    }
}
