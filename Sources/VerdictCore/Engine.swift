/// The engine: validate, sample, retry, schema-check, aggregate, time. SPEC §2, §5, §6.
public struct Verdict: Sendable {
    public let backend: any DecisionBackend

    public init(backend: any DecisionBackend) {
        self.backend = backend
    }

    /// Request-level problems (validation, model unavailable) throw a `Failure` with `id == nil`.
    /// Per-question problems are returned as `.failure` outcomes; the other questions still run.
    public func decide(_ request: Request) async throws(Failure) -> Response {
        let clock = ContinuousClock()
        let start = clock.now
        try Self.validate(request)
        if case .unavailable(let reason, let remedy) = backend.availability() {
            throw Failure(id: nil, code: .modelUnavailable, message: reason, remedy: remedy)
        }
        var outcomes: [(id: String, outcome: Outcome)] = []
        for entry in request.questions {
            let outcome = await answer(entry, state: request.state, policy: request.policy, clock: clock)
            outcomes.append((entry.id, outcome))
        }
        return Response(backend: backend.name, outcomes: outcomes, policy: request.policy,
                        latency: clock.now - start)
    }

    // MARK: - Validation

    public static func validate(_ request: Request) throws(Failure) {
        func fail(_ message: String) -> Failure { Failure(id: nil, code: .validation, message: message) }
        if request.state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw fail("`state` is empty.")
        }
        if request.questions.isEmpty { throw fail("`questions` is empty; supply 1...\(Limits.maxQuestions).") }
        if request.questions.count > Limits.maxQuestions {
            throw fail("`questions` has \(request.questions.count) entries; the limit is \(Limits.maxQuestions).")
        }
        if request.policy.votes < 1 { throw fail("`policy.votes` must be >= 1 (1 = greedy).") }
        if request.policy.votes > Limits.maxVotes { throw fail("`policy.votes` is \(request.policy.votes); the limit is \(Limits.maxVotes).") }
        var seen = Set<String>()
        for entry in request.questions {
            if entry.id.isEmpty { throw fail("A question id is empty.") }
            if !seen.insert(entry.id).inserted { throw fail("Question id `\(entry.id)` is duplicated.") }
            let labels = entry.question.labels
            switch entry.question {
            case .choice(let q):
                if q.options.count < Limits.minOptions || q.options.count > Limits.maxOptions {
                    throw fail("`\(entry.id)`: choice needs \(Limits.minOptions)...\(Limits.maxOptions) options, got \(q.options.count).")
                }
                if Set(labels).count != labels.count { throw fail("`\(entry.id)`: option keys repeat.") }
                if labels.contains(where: \.isEmpty) { throw fail("`\(entry.id)`: an option key is empty.") }
            case .score(let q):
                if q.levels.count < Limits.minOptions || q.levels.count > Limits.maxOptions {
                    throw fail("`\(entry.id)`: score needs \(Limits.minOptions)...\(Limits.maxOptions) levels, got \(q.levels.count).")
                }
            case .noul:
                break
            }
            if entry.question.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw fail("`\(entry.id)`: `instructions` is empty.")
            }
        }
    }

    // MARK: - One question

    private func answer(_ entry: QuestionEntry, state: String, policy: Policy, clock: ContinuousClock) async -> Outcome {
        let start = clock.now
        var retries = 0
        let question = entry.question
        var labels: [String] = []
        var greedyDistribution: [String: Double]? = nil
        let runs = backend.producesDistribution ? 1 : max(1, policy.votes)
        for v in 0..<runs {
            let sampling: Sampling = runs == 1 ? .greedy : .random(seed: policy.seed(forVote: v))
            let sample: Sample
            switch await sampleWithRetry(state: state, question: question, sampling: sampling,
                                         retryBudget: policy.retryRefusals) {
            case .success(let s, let r):
                sample = s
                retries += r
            case .failure(let code, let message, let r):
                retries += r
                return .failure(Failure(id: entry.id, code: code, message: message,
                                        retries: retries, latency: clock.now - start))
            }
            guard let label = sample.raw.label(for: question) else {
                return .failure(Failure(id: entry.id, code: .outOfSchema,
                                        message: "Backend returned \(sample.raw) for a \(question.typeName) question with labels \(question.labels).",
                                        retries: retries, latency: clock.now - start))
            }
            labels.append(label)
            if runs == 1 {
                if let d = sample.distribution, let problem = Self.distributionProblem(d, labels: question.labels) {
                    return .failure(Failure(id: entry.id, code: .backendError,
                                            message: "Backend returned a malformed distribution: \(problem).",
                                            remedy: "Report as a bug in the backend; no confidence can be derived from it.",
                                            retries: retries, latency: clock.now - start))
                }
                greedyDistribution = sample.distribution
            }
        }
        let agg = runs == 1
            ? Aggregation.greedy(question: question, label: labels[0], distribution: greedyDistribution)
            : Aggregation.agreement(question: question, labels: labels)
        return .decision(Decision(id: entry.id, answer: agg.answer, confidence: agg.confidence,
                                  confidenceKind: agg.confidenceKind, distribution: agg.distribution,
                                  samples: runs, retries: retries, latency: clock.now - start))
    }

    /// nil when `d` is a usable distribution: keys ⊆ labels, every value finite and >= 0, total > 0.
    static func distributionProblem(_ d: [String: Double], labels: [String]) -> String? {
        let known = Set(labels)
        if let stray = d.keys.first(where: { !known.contains($0) }) { return "unknown label `\(stray)`" }
        if let bad = d.first(where: { !$0.value.isFinite || $0.value < 0 }) { return "value \(bad.value) for `\(bad.key)`" }
        if d.values.reduce(0, +) <= 0 { return "zero total mass" }
        return nil
    }

    private enum SampleResult {
        case success(Sample, retries: Int)
        case failure(FailureCode, String, retries: Int)
    }

    private func sampleWithRetry(state: String, question: Question, sampling: Sampling, retryBudget: Int) async -> SampleResult {
        var attempt = 0
        while true {
            do {
                let s = try await backend.sample(state: state, question: question, sampling: sampling)
                return .success(s, retries: attempt)
            } catch let e as BackendError {
                if e.code.engineRetries && attempt < retryBudget {
                    attempt += 1
                    continue
                }
                return .failure(e.code, e.message, retries: attempt)
            } catch {
                return .failure(.backendError, String(describing: error), retries: attempt)
            }
        }
    }
}
