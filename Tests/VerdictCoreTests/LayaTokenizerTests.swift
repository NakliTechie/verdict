import Foundation
import Testing
import VerdictCore

/// Parity with the Python `tokenizers` library and the laya-coreml sequence builder. These tests need the
/// Laya checkpoint's tokenizer on disk (`LayaCoreMLBackend.defaultDirectory`); they skip when it is absent.
@Suite struct LayaTokenizerTests {
    static let dir = LayaCoreMLBackend.defaultDirectory
    static var present: Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("tokenizer/tokenizer.json").path)
    }

    static func tokenizer() throws -> BPETokenizer {
        try BPETokenizer(tokenizerJSON: dir.appendingPathComponent("tokenizer/tokenizer.json"),
                         config: dir.appendingPathComponent("tokenizer/tokenizer_config.json"))
    }

    static func fixture<T: Decodable>(_ name: String, as: T.Type) throws -> T {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    struct TokenCase: Decodable { let text: String; let ids: [Int32] }

    @Test(.enabled(if: present)) func specialTokenIDs() throws {
        let tok = try Self.tokenizer()
        #expect(tok.clsID == 50281)
        #expect(tok.sepID == 50282)
        #expect(tok.padID == 50283)
        #expect(tok.maskID == 50284)
    }

    @Test(.enabled(if: present)) func matchesPythonTokenizersOnEveryGolden() throws {
        let tok = try Self.tokenizer()
        let cases = try Self.fixture("laya-tokenizer-golden", as: [TokenCase].self)
        #expect(cases.count == 96)
        var mismatches = 0
        for c in cases where tok.encode(c.text) != c.ids {
            mismatches += 1
            Issue.record("mismatch for \(c.text.prefix(60).debugDescription): got \(tok.encode(c.text).prefix(12)) want \(c.ids.prefix(12))")
        }
        #expect(mismatches == 0)
    }

    struct SequenceCase: Decodable {
        let qid: String
        let type: String
        let state: String
        let question: WireQuestion
        let input_ids: [Int32]
        let markers: [Int32]
        let qtype: Int32
        let temperature: Double
        struct WireQuestion: Decodable {
            let type: String
            let instructions: String
            let criteria: Criteria?
            enum Criteria: Decodable {
                case map([String: String?]), list([String])
                init(from d: Decoder) throws {
                    let c = try d.singleValueContainer()
                    if let l = try? c.decode([String].self) { self = .list(l) } else { self = .map(try c.decode([String: String?].self)) }
                }
            }
        }
    }

    static func question(_ q: SequenceCase.WireQuestion) -> Question {
        switch q.type {
        case "choice":
            guard case .map(let m) = q.criteria! else { fatalError() }
            // The Python reference iterates dict insertion order, which is the fixture's topic order (sorted slugs).
            return .choice(ChoiceQuestion(instructions: q.instructions, options: m.keys.sorted().map { ChoiceOption(key: $0, description: m[$0] ?? nil) }))
        case "score":
            guard case .list(let l) = q.criteria! else { fatalError() }
            return .score(ScoreQuestion(instructions: q.instructions, levels: l))
        default:
            return .noul(NoulQuestion(instructions: q.instructions))
        }
    }

    @Test(.enabled(if: present)) func sequenceBuilderMatchesPortOnFixture() throws {
        let tok = try Self.tokenizer()
        let cases = try Self.fixture("laya-sequence-golden", as: [SequenceCase].self)
        #expect(cases.count == 43)
        var mismatches = 0
        for c in cases {
            let q = Self.question(c.question)
            let seq = LayaPrompt.sequence(state: c.state, question: q, tok: tok, maxLen: 1024, headMaxLen: 256)
            if seq.ids != c.input_ids || seq.markers != c.markers || seq.qtype != c.qtype {
                mismatches += 1
                Issue.record("\(c.qid) ids \(seq.ids.count) vs \(c.input_ids.count); markers \(seq.markers) vs \(c.markers)")
            }
            let bucket = LayaPrompt.temperatureBucket(qtype: c.qtype, options: q.labels.count)
            let expectedBucket: [String: Double] = ["choice:11+": 0.10058280825614929, "noul:2": 1.983399510383606, "choice:2": 1.9063563346862793, "score:3-5": 1.2514300346374512]
            #expect(expectedBucket[bucket] == c.temperature)
        }
        #expect(mismatches == 0)
    }
}
