import Foundation
import Testing
import VerdictCore

@Suite struct WireTests {
    @Test func exampleRequestDecodes() throws {
        let w = try Wire.decodeRequest(Data(Wire.exampleRequestJSON.utf8))
        let core = w.toCore()
        #expect(core.questions.map(\.id) == ["department", "refund", "urgency"])
        #expect(core.questions[0].question == .choice(ChoiceQuestion(instructions: "Which department should handle this?",
            options: [ChoiceOption(key: "billing", description: "Payments and refunds"), ChoiceOption(key: "technical", description: "Software bugs")])))
        #expect(core.questions[2].question == .score(ScoreQuestion(instructions: "How urgent is the request?", levels: ["Routine", "Urgent", "Emergency"])))
        #expect(core.policy.votes == 1)
    }

    @Test func nullDescriptionAndMissingPolicy() throws {
        let json = #"{"state":"s","questions":{"q":{"type":"choice","instructions":"i","criteria":{"a":null,"b":"B"}}}}"#
        let core = try Wire.decodeRequest(Data(json.utf8)).toCore()
        #expect(core.questions[0].question == .choice(ChoiceQuestion(instructions: "i", options: [ChoiceOption(key: "a"), ChoiceOption(key: "b", description: "B")])))
        #expect(core.policy == Policy())
    }

    @Test func unknownTypeIsValidationFailure() {
        let json = #"{"state":"s","questions":{"q":{"type":"rank","instructions":"i"}}}"#
        do {
            _ = try Wire.decodeRequest(Data(json.utf8))
            Issue.record("decoded an unknown type")
        } catch {
            #expect(error.code == .validation)
            #expect(error.message.contains("rank"))
        }
    }

    @Test func responseEncodesJevFieldsAndVerdictExtensions() async throws {
        let backend = FakeBackend([
            .success(.key("billing")),
            .success(.bool(true)), .success(.bool(false)), .success(.bool(true)),
            .success(.level(2)), .success(.level(1)), .success(.level(2)),
        ])
        let core = Request(state: "s", questions: [
            QuestionEntry(id: "department", question: Fixtures.choice),
            QuestionEntry(id: "refund", question: Fixtures.noul),
            QuestionEntry(id: "urgency", question: Fixtures.score),
        ], policy: Policy(votes: 3))
        // First question greedy: drive it with a separate engine so the fake script lines up.
        let greedy = try await Verdict(backend: FakeBackend([.success(.key("billing"))])).decide(
            Request(state: "s", questions: [core.questions[0]]))
        let voted = try await Verdict(backend: FakeBackend(Array(backend.scriptForTest().dropFirst()))).decide(
            Request(state: "s", questions: Array(core.questions.dropFirst()), policy: Policy(votes: 3)))

        let g = try JSONSerialization.jsonObject(with: Wire.encoder(compact: true).encode(
            Wire.Response(greedy, request: Request(state: "s", questions: [core.questions[0]]), model: "verdict-fm"))) as! [String: Any]
        let dept = (g["answers"] as! [String: Any])["department"] as! [String: Any]
        #expect(dept["type"] as? String == "choice")
        #expect(dept["choice"] as? String == "billing")
        #expect(dept["confidence"] is NSNull)
        #expect(dept["confidence_kind"] as? String == "none")
        #expect(dept["probabilities"] == nil)
        #expect((g["failures"] as! [String: Any]).isEmpty)

        let v = try JSONSerialization.jsonObject(with: Wire.encoder(compact: true).encode(
            Wire.Response(voted, request: Request(state: "s", questions: Array(core.questions.dropFirst()), policy: Policy(votes: 3)), model: "verdict-fm"))) as! [String: Any]
        let answers = v["answers"] as! [String: Any]
        let refund = answers["refund"] as! [String: Any]
        #expect(abs((refund["noul"] as! Double) - 2.0 / 3.0) < 1e-9)
        #expect(refund["confidence_kind"] as? String == "agreement")
        let urgency = answers["urgency"] as! [String: Any]
        #expect(urgency["level"] as? Int == 2)
        #expect(abs((urgency["score"] as! Double) - (5.0 / 3.0)) < 1e-9)
        #expect((urgency["legend"] as! [String: String])["0"] == "Routine")
        #expect((urgency["probabilities"] as! [String: Double]).count == 3)
        let usage = v["usage"] as! [String: Any]
        #expect(usage["samples"] as? Int == 6)
        #expect(usage["votes"] as? Int == 3)
        #expect(usage["seed"] as? Int == 1)
    }

    @Test func failureBodyCarriesRemedyAndRetryable() async throws {
        let r = try await Verdict(backend: FakeBackend([.failure(BackendError(code: .rateLimited, message: "slow down"))])).decide(Fixtures.request(Fixtures.choice))
        let core = Fixtures.request(Fixtures.choice)
        let json = try JSONSerialization.jsonObject(with: Wire.encoder(compact: true).encode(Wire.Response(r, request: core, model: "m"))) as! [String: Any]
        let f = (json["failures"] as! [String: Any])["q"] as! [String: Any]
        #expect(f["code"] as? String == "rate_limited")
        #expect(f["retryable"] as? Bool == true)
        #expect((f["remedy"] as? String)?.isEmpty == false)
        #expect((json["answers"] as! [String: Any]).isEmpty)
    }

    @Test func requestRoundTrips() throws {
        let w = try Wire.decodeRequest(Data(Wire.exampleRequestJSON.utf8))
        let again = try Wire.decodeRequest(try Wire.encoder().encode(w))
        #expect(again == w)
    }
}

extension FakeBackend {
    /// The scripted samples for the wire test, mirrored so the test can split them.
    func scriptForTest() -> [Result<Sample, BackendError>] {
        [.success(.key("billing")),
         .success(.bool(true)), .success(.bool(false)), .success(.bool(true)),
         .success(.level(2)), .success(.level(1)), .success(.level(2))]
    }
}
