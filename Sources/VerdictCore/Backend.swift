/// Backend protocol. SPEC §4. One call = one sample of one question; the engine owns everything else.

public enum Sampling: Sendable, Equatable {
    case greedy
    case random(seed: UInt64)
}

public enum RawAnswer: Sendable, Equatable {
    case key(String)
    case level(Int)
    case bool(Bool)

    /// The label this answer has in a distribution, or nil when it is outside the question's schema.
    public func label(for question: Question) -> String? {
        switch (self, question) {
        case (.key(let k), .choice(let q)):
            q.options.contains { $0.key == k } ? k : nil
        case (.level(let l), .score(let q)):
            q.levels.indices.contains(l) ? String(l) : nil
        case (.bool(let b), .noul):
            b ? "true" : "false"
        default:
            nil
        }
    }
}

public struct Sample: Sendable, Equatable {
    public let raw: RawAnswer
    /// Real probabilities over the question's labels. Only a backend that reads logits sets this.
    public let distribution: [String: Double]?
    public init(raw: RawAnswer, distribution: [String: Double]? = nil) {
        self.raw = raw
        self.distribution = distribution
    }
}

public struct BackendError: Error, Sendable, Equatable {
    public let code: FailureCode
    public let message: String
    public init(code: FailureCode, message: String) {
        self.code = code
        self.message = message
    }
}

public enum BackendAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String, remedy: String)
}

public protocol DecisionBackend: Sendable {
    var name: String { get }
    /// True when one call returns a real distribution (Laya). The engine then runs exactly one sample
    /// per question and reports `confidenceKind = .decoded`; `Policy.votes` is ignored.
    var producesDistribution: Bool { get }
    func availability() -> BackendAvailability
    func sample(state: String, question: Question, sampling: Sampling) async throws -> Sample
}

public extension DecisionBackend {
    var producesDistribution: Bool { false }
}
