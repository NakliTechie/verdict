import Foundation

/// Jev-compatible JSON. SPEC §3. Field names are load-bearing.
public enum Wire {
    public static let defaultModel = "verdict-fm"

    // MARK: Request

    public struct Request: Sendable, Equatable {
        public var model: String?
        public var state: String
        public var questions: [String: Question]   // ids; converted to sorted order
        public var policy: Policy?

        public init(model: String? = nil, state: String, questions: [String: Question], policy: Policy? = nil) {
            self.model = model
            self.state = state
            self.questions = questions
            self.policy = policy
        }

        /// Ordered by id so the response is deterministic.
        public func toCore() -> VerdictCore.Request {
            VerdictCore.Request(
                state: state,
                questions: questions.keys.sorted().map { QuestionEntry(id: $0, question: questions[$0]!) },
                policy: policy?.toCore() ?? VerdictCore.Policy())
        }
    }

    public struct Policy: Codable, Sendable, Equatable {
        public var votes: Int?
        public var seed: UInt64?
        public init(votes: Int? = nil, seed: UInt64? = nil) {
            self.votes = votes
            self.seed = seed
        }
        func toCore() -> VerdictCore.Policy {
            VerdictCore.Policy(votes: votes ?? 1, seed: seed ?? 1)
        }
    }

    // MARK: Response

    public struct Response: Encodable, Sendable {
        public let model: String
        public let backend: String
        public let answers: [String: AnswerBody]
        public let failures: [String: FailureBody]
        public let usage: Usage

        public struct Usage: Encodable, Sendable {
            public let samples: Int
            public let retries: Int
            public let seed: UInt64
            public let votes: Int
            public let latency_ms: Int
        }

        public struct FailureBody: Encodable, Sendable, Equatable {
            public let code: FailureCode
            public let message: String
            public let remedy: String
            public let retryable: Bool
            public let retries: Int
            public let latency_ms: Int
        }

        public struct AnswerBody: Sendable, Equatable {
            public let type: String
            public var choice: String? = nil
            public var score: Double? = nil
            public var level: Int? = nil
            public var legend: [String: String]? = nil
            public var noul: Double? = nil
            public var probabilities: [String: Double]? = nil
            public let confidence: Double?
            public let confidence_kind: ConfidenceKind
            public let samples: Int
            public let retries: Int
            public let latency_ms: Int
        }

        public init(_ response: VerdictCore.Response, request: VerdictCore.Request, model: String) {
            var answers: [String: AnswerBody] = [:]
            var failures: [String: FailureBody] = [:]
            let byID = Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, $0.question) })
            for (id, outcome) in response.outcomes {
                switch outcome {
                case .decision(let d):
                    answers[id] = AnswerBody(d, question: byID[id]!)
                case .failure(let f):
                    failures[id] = FailureBody(code: f.code, message: f.message, remedy: f.remedy,
                                               retryable: f.retryable, retries: f.retries,
                                               latency_ms: f.latency.wholeMilliseconds)
                }
            }
            self.model = model
            self.backend = response.backend
            self.answers = answers
            self.failures = failures
            self.usage = Usage(samples: response.samples, retries: response.retries,
                               seed: response.policy.seed, votes: response.policy.votes,
                               latency_ms: response.latency.wholeMilliseconds)
        }
    }

    // MARK: Errors

    public struct ErrorBody: Encodable, Sendable {
        public let error: Detail
        public struct Detail: Encodable, Sendable {
            public let code: FailureCode
            public let message: String
            public let remedy: String
            public let retryable: Bool
        }
        public init(_ f: Failure) {
            error = Detail(code: f.code, message: f.message, remedy: f.remedy, retryable: f.retryable)
        }
    }

    // MARK: Example (SPEC §3)

    public static let exampleRequestJSON = """
    {
      "model": "verdict-fm",
      "state": "I was charged twice. Please refund the duplicate.",
      "questions": {
        "refund":     {"type": "noul",   "instructions": "Does the user request a refund?",
                       "criteria": {"true": "Yes", "false": "No"}},
        "department": {"type": "choice", "instructions": "Which department should handle this?",
                       "criteria": {"billing": "Payments and refunds", "technical": "Software bugs"}},
        "urgency":    {"type": "score",  "instructions": "How urgent is the request?",
                       "criteria": ["Routine", "Urgent", "Emergency"]}
      },
      "policy": {"votes": 1}
    }
    """

    // MARK: Codec helpers

    public static func encoder(compact: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = compact ? [.sortedKeys, .withoutEscapingSlashes]
                                     : [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decodeRequest(_ data: Data) throws(Failure) -> Request {
        do {
            return try JSONDecoder().decode(Request.self, from: data)
        } catch let f as Failure {
            throw f
        } catch {
            throw Failure(id: nil, code: .validation, message: "Request JSON did not decode: \(Self.describe(error))",
                          remedy: "Start from `verdict decide --example` and keep the field names.")
        }
    }

    static func describe(_ error: Error) -> String {
        if let d = error as? DecodingError {
            switch d {
            case .keyNotFound(let k, let c): return "missing key `\(k.stringValue)` at \(path(c))"
            case .typeMismatch(_, let c): return "wrong type at \(path(c)): \(c.debugDescription)"
            case .valueNotFound(_, let c): return "null at \(path(c))"
            case .dataCorrupted(let c): return c.debugDescription
            @unknown default: return String(describing: d)
            }
        }
        return String(describing: error)
    }

    static func path(_ c: DecodingError.Context) -> String {
        c.codingPath.isEmpty ? "root" : c.codingPath.map(\.stringValue).joined(separator: ".")
    }
}

public extension Duration {
    var wholeMilliseconds: Int {
        let (s, atto) = components
        return Int(s) * 1000 + Int(atto / 1_000_000_000_000_000)
    }
}

// MARK: - Codable conformances

extension Wire.Request: Codable {
    enum CodingKeys: String, CodingKey { case model, state, questions, policy }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        state = try c.decode(String.self, forKey: .state)
        let raw = try c.decode([String: Wire.QuestionBody].self, forKey: .questions)
        questions = try raw.mapValues { try $0.toCore() }
        policy = try c.decodeIfPresent(Wire.Policy.self, forKey: .policy)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(state, forKey: .state)
        try c.encode(questions.mapValues(Wire.QuestionBody.init), forKey: .questions)
        try c.encodeIfPresent(policy, forKey: .policy)
    }
}

extension Wire {
    /// The polymorphic `criteria` field: object for choice / noul, array for score.
    struct QuestionBody: Codable {
        let type: String
        let instructions: String
        var choiceCriteria: [String: String?]? = nil
        var scoreCriteria: [String]? = nil
        var noulCriteria: [String: String]? = nil

        enum CodingKeys: String, CodingKey { case type, instructions, criteria }

        init(_ q: Question) {
            type = q.typeName
            instructions = q.instructions
            switch q {
            case .choice(let c): choiceCriteria = Dictionary(uniqueKeysWithValues: c.options.map { ($0.key, $0.description) })
            case .score(let s): scoreCriteria = s.levels
            case .noul(let n):
                var c: [String: String] = [:]
                if let y = n.yes { c["true"] = y }
                if let f = n.no { c["false"] = f }
                noulCriteria = c.isEmpty ? nil : c
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            instructions = try c.decode(String.self, forKey: .instructions)
            switch type {
            case "choice": choiceCriteria = try c.decode([String: String?].self, forKey: .criteria)
            case "score": scoreCriteria = try c.decode([String].self, forKey: .criteria)
            case "noul": noulCriteria = try c.decodeIfPresent([String: String].self, forKey: .criteria)
            default:
                throw Failure(id: nil, code: .validation,
                              message: "Unknown question type `\(type)`; use choice, score or noul.")
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(type, forKey: .type)
            try c.encode(instructions, forKey: .instructions)
            if let choiceCriteria { try c.encode(choiceCriteria, forKey: .criteria) }
            if let scoreCriteria { try c.encode(scoreCriteria, forKey: .criteria) }
            if let noulCriteria { try c.encode(noulCriteria, forKey: .criteria) }
        }

        func toCore() throws(Failure) -> Question {
            switch type {
            case "choice":
                let crit = choiceCriteria ?? [:]
                // Sorted keys: JSON objects carry no order into Swift dictionaries. Documented in SPEC §3.
                return .choice(ChoiceQuestion(instructions: instructions,
                                              options: crit.keys.sorted().map { ChoiceOption(key: $0, description: crit[$0] ?? nil) }))
            case "score":
                return .score(ScoreQuestion(instructions: instructions, levels: scoreCriteria ?? []))
            case "noul":
                return .noul(NoulQuestion(instructions: instructions, yes: noulCriteria?["true"], no: noulCriteria?["false"]))
            default:
                throw Failure(id: nil, code: .validation, message: "Unknown question type `\(type)`.")
            }
        }
    }
}

extension Wire.Response.AnswerBody: Encodable {
    enum CodingKeys: String, CodingKey {
        case type, choice, score, level, legend, noul, probabilities, confidence, confidence_kind, samples, retries, latency_ms
    }

    init(_ d: Decision, question: Question) {
        type = question.typeName
        confidence = d.confidence
        confidence_kind = d.confidenceKind
        samples = d.samples
        retries = d.retries
        latency_ms = d.latency.wholeMilliseconds
        probabilities = d.distribution
        switch (d.answer, question) {
        case (.choice(let key), _):
            choice = key
        case (.score(let lvl, let expected), .score(let q)):
            level = lvl
            score = expected
            legend = Dictionary(uniqueKeysWithValues: q.levels.enumerated().map { (String($0.offset), $0.element) })
        case (.noul(let b), _):
            noul = d.distribution?["true"] ?? (b ? 1.0 : 0.0)
        default:
            break
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(choice, forKey: .choice)
        try c.encodeIfPresent(score, forKey: .score)
        try c.encodeIfPresent(level, forKey: .level)
        try c.encodeIfPresent(legend, forKey: .legend)
        try c.encodeIfPresent(noul, forKey: .noul)
        try c.encodeIfPresent(probabilities, forKey: .probabilities)
        try c.encode(confidence, forKey: .confidence)          // explicit null when unknown
        try c.encode(confidence_kind, forKey: .confidence_kind)
        try c.encode(samples, forKey: .samples)
        try c.encode(retries, forKey: .retries)
        try c.encode(latency_ms, forKey: .latency_ms)
    }
}
