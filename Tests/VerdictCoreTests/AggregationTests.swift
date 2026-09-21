import Testing
import VerdictCore

@Suite struct AggregationTests {
    @Test func greedyHasNoConfidence() {
        let r = Aggregation.greedy(question: Fixtures.choice, label: "billing", distribution: nil)
        #expect(r.answer == .choice(key: "billing"))
        #expect(r.confidence == nil)
        #expect(r.confidenceKind == .none)
        #expect(r.distribution == nil)
    }

    @Test func greedyWithBackendDistributionIsDecoded() {
        let r = Aggregation.greedy(question: Fixtures.choice, label: "billing",
                                   distribution: ["billing": 0.8, "technical": 0.2, "sales": 0])
        #expect(r.confidenceKind == .decoded)
        #expect(r.distribution?["billing"] == 0.8)
        #expect(r.confidence! > 0.5 && r.confidence! < 1)
    }

    @Test func agreementShareAndDistribution() {
        let r = Aggregation.agreement(question: Fixtures.choice, labels: ["billing", "billing", "technical", "billing", "sales"])
        #expect(r.answer == .choice(key: "billing"))
        #expect(r.confidence == 0.6)
        #expect(r.confidenceKind == .agreement)
        #expect(r.distribution == ["billing": 0.6, "technical": 0.2, "sales": 0.2])
    }

    @Test func agreementTieGoesToEarlierOption() {
        let r = Aggregation.agreement(question: Fixtures.choice, labels: ["technical", "sales", "sales", "technical"])
        #expect(r.answer == .choice(key: "technical"))
        #expect(r.confidence == 0.5)
    }

    @Test func scoreExpectedValueUnderVoting() {
        let r = Aggregation.agreement(question: Fixtures.score, labels: ["1", "2", "1", "0", "2"])
        guard case .score(let level, let expected) = r.answer else { Issue.record("not a score"); return }
        #expect(level == 1)   // 1 and 2 tie at 2 votes; lower index wins
        #expect(abs(expected - 1.2) < 1e-9)
    }

    @Test func scoreGreedyExpectedEqualsLevel() {
        let r = Aggregation.greedy(question: Fixtures.score, label: "2", distribution: nil)
        #expect(r.answer == .score(level: 2, expected: 2))
    }

    @Test func noulShareOfTrue() {
        let r = Aggregation.agreement(question: Fixtures.noul, labels: ["true", "true", "false"])
        #expect(r.answer == .noul(true))
        #expect(r.distribution?["true"] == 2.0 / 3.0)
    }

    @Test func entropyConfidenceBounds() {
        #expect(Aggregation.oneMinusNormalisedEntropy(["a": 1, "b": 0]) == 1)
        #expect(abs(Aggregation.oneMinusNormalisedEntropy(["a": 0.5, "b": 0.5])) < 1e-12)
    }
}
