import Synchronization
import VerdictCore

/// Scripted backend: hands out samples (or errors) in order; records every call.
final class FakeBackend: DecisionBackend, Sendable {
    let name = "fake"
    private let script: Mutex<[Result<Sample, BackendError>]>
    let calls = Mutex<[(question: Question, sampling: Sampling)]>([])
    let available: BackendAvailability

    init(_ script: [Result<Sample, BackendError>], available: BackendAvailability = .available) {
        self.script = Mutex(script)
        self.available = available
    }

    func availability() -> BackendAvailability { available }

    func sample(state: String, question: Question, sampling: Sampling) async throws -> Sample {
        calls.withLock { $0.append((question, sampling)) }
        let next = script.withLock { s -> Result<Sample, BackendError>? in
            s.isEmpty ? nil : s.removeFirst()
        }
        guard let next else { throw BackendError(code: .backendError, message: "script exhausted") }
        return try next.get()
    }

    func callCount() -> Int { calls.withLock { $0.count } }
}

extension Sample {
    static func key(_ k: String) -> Sample { Sample(raw: .key(k)) }
    static func level(_ l: Int) -> Sample { Sample(raw: .level(l)) }
    static func bool(_ b: Bool) -> Sample { Sample(raw: .bool(b)) }
}

enum Fixtures {
    static let choice = Question.choice(ChoiceQuestion(
        instructions: "Which department?",
        options: [ChoiceOption(key: "billing", description: "Payments"), ChoiceOption(key: "technical", description: "Bugs"), ChoiceOption(key: "sales")]))
    static let score = Question.score(ScoreQuestion(instructions: "How urgent?", levels: ["Routine", "Urgent", "Emergency"]))
    static let noul = Question.noul(NoulQuestion(instructions: "Refund requested?"))

    static func request(_ q: Question, id: String = "q", votes: Int = 1) -> Request {
        Request(state: "I was charged twice.", questions: [QuestionEntry(id: id, question: q)], policy: Policy(votes: votes))
    }
}
