import Foundation
import Testing
import VerdictCore

/// Fidelity against the laya-coreml Python port on this machine. Needs the checkpoint on disk; skipped otherwise.
/// Gate: every probability within 0.02 of the Python reference (the port's own fidelity threshold).
@Suite(.serialized) struct LayaBackendLiveTests {
    static var present: Bool { LayaCoreMLBackend.availability() == .available }

    @Test(.enabled(if: present)) func probabilitiesMatchPythonReference() async throws {
        let backend = try LayaCoreMLBackend()
        let cases = try LayaTokenizerTests.fixture("laya-sequence-golden", as: [ReferenceCase].self)
        // Three small questions plus the first three fixture items: enough to catch label-order or
        // calibration mistakes without a 40-item live run.
        let picked = cases.filter { $0.qid != "topic" } + cases.filter { $0.qid == "topic" }.prefix(3)
        let engine = Verdict(backend: backend)
        var maxDrift = 0.0
        for c in picked {
            let q = LayaTokenizerTests.question(c.question)
            let r = try await engine.decide(Request(state: c.state, questions: [QuestionEntry(id: c.qid, question: q)]))
            guard let d = r.outcomes[0].outcome.decision else { Issue.record("\(c.qid) failed: \(r.outcomes[0].outcome)"); continue }
            #expect(d.confidenceKind == .decoded)
            #expect(d.samples == 1)
            // The Python port reports noul as P(true) only; expand it to the two-label map.
            let want = c.probabilities ?? (c.answer.noul.map { ["true": $0, "false": 1 - $0] } ?? [:])
            let got = d.distribution ?? [:]
            #expect(Set(want.keys) == Set(got.keys), "\(c.qid) labels")
            for (k, p) in want {
                let drift = abs(p - (got[k] ?? -1))
                maxDrift = max(maxDrift, drift)
                #expect(drift <= 0.02, "\(c.qid)[\(k)] python \(p) swift \(got[k] ?? -1)")
            }
            if c.qid == "refund" {
                // The example's P(true) as the Python port reports it (noul = p[true]).
                #expect(abs((got["true"] ?? 0) - c.answer.noul!) <= 0.02)
            }
        }
        print("laya fidelity: max |Δp| = \(maxDrift) over \(picked.count) questions")
    }

    struct ReferenceCase: Decodable {
        let qid: String
        let state: String
        let question: LayaTokenizerTests.SequenceCase.WireQuestion
        let probabilities: [String: Double]?
        let answer: Answer
        struct Answer: Decodable { let noul: Double?; let choice: String?; let score: Double? }
    }
}
