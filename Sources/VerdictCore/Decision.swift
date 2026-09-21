/// Outcomes. SPEC §2 and §6.

public enum ConfidenceKind: String, Sendable, Codable {
    /// A backend read real probabilities (Laya, M1). Never Foundation Models.
    case decoded
    /// Share of N sampled runs that agreed with the winner.
    case agreement
    /// One greedy run; no confidence is known and none is invented.
    /// Compare as `ConfidenceKind.none`; a bare `.none` against an Optional resolves to nil.
    case none
}

public enum Answer: Sendable, Equatable {
    case choice(key: String)
    /// `level` is the winning index; `expected` is Σ level × share (equals `level` for greedy).
    case score(level: Int, expected: Double)
    case noul(Bool)
}

public struct Decision: Sendable, Equatable {
    public let id: String
    public let answer: Answer
    /// nil iff `confidenceKind == .none`.
    public let confidence: Double?
    public let confidenceKind: ConfidenceKind
    /// Over the question's labels; sums to 1. nil iff `confidenceKind == .none`.
    public let distribution: [String: Double]?
    public let samples: Int
    public let retries: Int
    public let latency: Duration

    public init(id: String, answer: Answer, confidence: Double?, confidenceKind: ConfidenceKind,
                distribution: [String: Double]?, samples: Int, retries: Int, latency: Duration) {
        self.id = id
        self.answer = answer
        self.confidence = confidence
        self.confidenceKind = confidenceKind
        self.distribution = distribution
        self.samples = samples
        self.retries = retries
        self.latency = latency
    }
}

public enum FailureCode: String, Sendable, Codable, CaseIterable {
    case refused
    case guardrailViolation = "guardrail_violation"
    case contextExceeded = "context_exceeded"
    case modelUnavailable = "model_unavailable"
    case unsupportedLanguage = "unsupported_language"
    case decodingFailure = "decoding_failure"
    case rateLimited = "rate_limited"
    case concurrentRequests = "concurrent_requests"
    case outOfSchema = "out_of_schema"
    case validation
    case backendError = "backend_error"

    /// Whether the engine retries a sample that failed with this code (SPEC §6).
    public var engineRetries: Bool {
        self == .refused || self == .guardrailViolation
    }

    /// Whether the same call, unchanged, can succeed later.
    public var retryable: Bool {
        switch self {
        case .modelUnavailable, .rateLimited, .concurrentRequests: true
        default: false
        }
    }

    public var defaultRemedy: String {
        switch self {
        case .refused, .guardrailViolation:
            "Rephrase the state or the question; the on-device guardrail declined twice."
        case .contextExceeded:
            "Shorten `state` (measured safe: 3,400 words on macOS 26.5)."
        case .modelUnavailable:
            "Run `verdict status` for the reason and the setting to change."
        case .unsupportedLanguage:
            "Write the state in a supported language (`verdict status` lists the count)."
        case .decodingFailure:
            "Report with the request; the schema builder emitted something the model could not follow."
        case .rateLimited:
            "Wait and retry; the system model is throttling."
        case .concurrentRequests:
            "Serialise calls; one request at a time per process."
        case .outOfSchema:
            "Report as a bug; constrained decoding returned a value outside the schema."
        case .validation:
            "Fix the request field named in the message."
        case .backendError:
            "Read the message; if it names a system condition, fix that and re-run."
        }
    }
}

public struct Failure: Sendable, Error, Equatable {
    /// nil when the whole request failed (validation, model unavailable).
    public let id: String?
    public let code: FailureCode
    public let message: String
    public let remedy: String
    public var retryable: Bool { code.retryable }
    public let retries: Int
    public let latency: Duration

    public init(id: String?, code: FailureCode, message: String, remedy: String? = nil,
                retries: Int = 0, latency: Duration = .zero) {
        self.id = id
        self.code = code
        self.message = message
        self.remedy = remedy ?? code.defaultRemedy
        self.retries = retries
        self.latency = latency
    }
}

public enum Outcome: Sendable, Equatable {
    case decision(Decision)
    case failure(Failure)

    public var decision: Decision? { if case .decision(let d) = self { d } else { nil } }
    public var failure: Failure? { if case .failure(let f) = self { f } else { nil } }
}

public struct Response: Sendable {
    public let backend: String
    /// Every question id exactly once, in request order.
    public let outcomes: [(id: String, outcome: Outcome)]
    public let policy: Policy
    public let latency: Duration

    public var samples: Int {
        outcomes.reduce(0) { $0 + ($1.outcome.decision?.samples ?? 0) }
    }
    public var retries: Int {
        outcomes.reduce(0) { $0 + ($1.outcome.decision?.retries ?? $1.outcome.failure?.retries ?? 0) }
    }
    public var failed: Bool { outcomes.contains { $0.outcome.failure != nil } }
}
