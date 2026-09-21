import Testing
import VerdictCore

@Suite struct EngineTests {
    @Test func greedyDecision() async throws {
        let backend = FakeBackend([.success(.key("billing"))])
        let r = try await Verdict(backend: backend).decide(Fixtures.request(Fixtures.choice))
        let d = r.outcomes[0].outcome.decision
        #expect(d?.answer == .choice(key: "billing"))
        #expect(d?.confidenceKind == ConfidenceKind.none)
        #expect(d?.samples == 1)
        #expect(backend.calls.withLock { $0.map(\.sampling) } == [.greedy])
    }

    @Test func votingUsesSeededSampling() async throws {
        let backend = FakeBackend([.success(.key("billing")), .success(.key("technical")), .success(.key("billing"))])
        let r = try await Verdict(backend: backend).decide(Fixtures.request(Fixtures.choice, votes: 3))
        let d = r.outcomes[0].outcome.decision
        #expect(d?.answer == .choice(key: "billing"))
        #expect(d?.confidenceKind == .agreement)
        #expect(d?.confidence == 2.0 / 3.0)
        #expect(d?.samples == 3)
        let p = Policy(votes: 3)
        #expect(backend.calls.withLock { $0.map(\.sampling) } == [.random(seed: p.seed(forVote: 0)), .random(seed: p.seed(forVote: 1)), .random(seed: p.seed(forVote: 2))])
    }

    @Test func refusalRetriesOnceThenSucceeds() async throws {
        let backend = FakeBackend([.failure(BackendError(code: .refused, message: "sensitive")), .success(.key("sales"))])
        let r = try await Verdict(backend: backend).decide(Fixtures.request(Fixtures.choice))
        let d = r.outcomes[0].outcome.decision
        #expect(d?.answer == .choice(key: "sales"))
        #expect(d?.retries == 1)
        #expect(r.retries == 1)
    }

    @Test func refusalTwiceIsTypedFailureNotFallback() async throws {
        let backend = FakeBackend([.failure(BackendError(code: .refused, message: "a")), .failure(BackendError(code: .refused, message: "b"))])
        let r = try await Verdict(backend: backend).decide(Fixtures.request(Fixtures.choice))
        let f = r.outcomes[0].outcome.failure
        #expect(f?.code == .refused)
        #expect(f?.retries == 1)
        #expect(f?.retryable == false)
        #expect(r.failed)
        #expect(backend.callCount() == 2)
    }

    @Test func nonRefusalErrorsAreNotRetried() async throws {
        let backend = FakeBackend([.failure(BackendError(code: .contextExceeded, message: "too long"))])
        let r = try await Verdict(backend: backend).decide(Fixtures.request(Fixtures.choice))
        #expect(r.outcomes[0].outcome.failure?.code == .contextExceeded)
        #expect(backend.callCount() == 1)
    }

    @Test func outOfSchemaIsCaughtByEngine() async throws {
        let backend = FakeBackend([.success(.key("invented-slug"))])
        let r = try await Verdict(backend: backend).decide(Fixtures.request(Fixtures.choice))
        #expect(r.outcomes[0].outcome.failure?.code == .outOfSchema)
        let backend2 = FakeBackend([.success(.level(7))])
        let r2 = try await Verdict(backend: backend2).decide(Fixtures.request(Fixtures.score))
        #expect(r2.outcomes[0].outcome.failure?.code == .outOfSchema)
    }

    @Test func otherQuestionsStillRunAfterAFailure() async throws {
        let backend = FakeBackend([.failure(BackendError(code: .decodingFailure, message: "x")), .success(.bool(true))])
        let req = Request(state: "s", questions: [QuestionEntry(id: "a", question: Fixtures.choice), QuestionEntry(id: "b", question: Fixtures.noul)])
        let r = try await Verdict(backend: backend).decide(req)
        #expect(r.outcomes.map(\.id) == ["a", "b"])
        #expect(r.outcomes[0].outcome.failure?.code == .decodingFailure)
        #expect(r.outcomes[1].outcome.decision?.answer == .noul(true))
    }

    @Test func modelUnavailableThrowsRequestLevelFailure() async {
        let backend = FakeBackend([], available: .unavailable(reason: "off", remedy: "turn it on"))
        await #expect(throws: Failure.self) {
            try await Verdict(backend: backend).decide(Fixtures.request(Fixtures.choice))
        }
    }

    @Test func validation() {
        func code(_ r: Request) -> FailureCode? {
            do { try Verdict.validate(r); return nil } catch { return error.code }
        }
        #expect(code(Request(state: " ", questions: [QuestionEntry(id: "q", question: Fixtures.choice)])) == .validation)
        #expect(code(Request(state: "s", questions: [])) == .validation)
        #expect(code(Request(state: "s", questions: [QuestionEntry(id: "q", question: Fixtures.choice), QuestionEntry(id: "q", question: Fixtures.noul)])) == .validation)
        #expect(code(Request(state: "s", questions: [QuestionEntry(id: "q", question: .choice(ChoiceQuestion(instructions: "i", options: [ChoiceOption(key: "only")])))])) == .validation)
        #expect(code(Request(state: "s", questions: [QuestionEntry(id: "q", question: Fixtures.choice)], policy: Policy(votes: 0))) == .validation)
        #expect(code(Fixtures.request(Fixtures.choice)) == nil)
    }
}
