/// Typed questions asked about a shared text state. SPEC §2.

public enum Limits {
    public static let maxQuestions = 64
    public static let maxOptions = 64
    public static let minOptions = 2
}

public struct ChoiceOption: Sendable, Equatable {
    public let key: String
    public let description: String?
    public init(key: String, description: String? = nil) {
        self.key = key
        self.description = description
    }
}

public struct ChoiceQuestion: Sendable, Equatable {
    public var instructions: String
    public var options: [ChoiceOption]
    public init(instructions: String, options: [ChoiceOption]) {
        self.instructions = instructions
        self.options = options
    }
}

public struct ScoreQuestion: Sendable, Equatable {
    public var instructions: String
    /// Ordered rubric, lowest first. The answer is an index into this array.
    public var levels: [String]
    public init(instructions: String, levels: [String]) {
        self.instructions = instructions
        self.levels = levels
    }
}

public struct NoulQuestion: Sendable, Equatable {
    public var instructions: String
    /// Meaning of true / false. nil = the caller gave none; each backend renders its own trained default.
    public var yes: String?
    public var no: String?
    public init(instructions: String, yes: String? = nil, no: String? = nil) {
        self.instructions = instructions
        self.yes = yes
        self.no = no
    }
}

public enum Question: Sendable, Equatable {
    case choice(ChoiceQuestion)
    case score(ScoreQuestion)
    case noul(NoulQuestion)

    public var typeName: String {
        switch self {
        case .choice: "choice"
        case .score: "score"
        case .noul: "noul"
        }
    }

    public var instructions: String {
        switch self {
        case .choice(let q): q.instructions
        case .score(let q): q.instructions
        case .noul(let q): q.instructions
        }
    }

    /// Every admissible answer, as the label used in distributions, in canonical order.
    public var labels: [String] {
        switch self {
        case .choice(let q): q.options.map(\.key)
        case .score(let q): q.levels.indices.map(String.init)
        case .noul: ["true", "false"]
        }
    }
}

public struct QuestionEntry: Sendable, Equatable {
    public let id: String
    public let question: Question
    public init(id: String, question: Question) {
        self.id = id
        self.question = question
    }
}

public struct Policy: Sendable, Equatable {
    /// 1 = one greedy run. N >= 2 = N sampled runs aggregated by agreement (SPEC §5).
    public var votes: Int
    /// Base seed; sampled run v uses `seed + v * 7919`.
    public var seed: UInt64
    /// How many times a refused or guardrailed sample is retried with a fresh session.
    public var retryRefusals: Int

    public init(votes: Int = 1, seed: UInt64 = 1, retryRefusals: Int = 1) {
        self.votes = votes
        self.seed = seed
        self.retryRefusals = retryRefusals
    }

    public func seed(forVote v: Int) -> UInt64 { seed &+ UInt64(v) &* 7919 }
}

public struct Request: Sendable, Equatable {
    public var state: String
    public var questions: [QuestionEntry]
    public var policy: Policy
    public init(state: String, questions: [QuestionEntry], policy: Policy = Policy()) {
        self.state = state
        self.questions = questions
        self.policy = policy
    }
}
