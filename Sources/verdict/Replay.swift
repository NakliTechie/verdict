import ArgumentParser
import Foundation
import VerdictCore

/// The verifier (SPEC §8). Extends ~/Code/knowledge/plan/fm-bench/classify2.swift: same fixture,
/// prompt shape, sampling settings and metrics; the model call goes through VerdictCore.
struct Replay: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Replay the fm-bench fixture through VerdictCore and judge the gate.",
        discussion: "Exit 0 gate passed · 1 gate failed · 3 indeterminate (model unavailable or nothing completed).")

    @Argument(help: "fixture.json: {topics: [{slug,title,blurb}], items: [{slug,title,tldr,truth}]}") var fixture: String
    @Option(help: "Only the first N items.") var limit: Int?
    @Option(help: "1 = greedy; N >= 2 = agreement voting.") var votes = 1
    @Option(help: "Base seed for sampled runs.") var seed: UInt64 = 1
    @Option(help: "Minimum top-1 hits to pass. Never lower this; raise it in plan/history.md.") var gate = 26
    @Option(help: "Write the full run record here (atomic).") var out: String?
    @Option(help: "Prior record; prints the items whose correctness flipped.") var baseline: String?
    @Option(help: "The question's instructions (caller-side text; default is the fm-bench question).") var instructions = Replay.question
    @Option(help: "Backend: verdict-fm (default) or verdict-laya.") var model = "verdict-fm"

    struct Topic: Codable { let slug: String; let title: String; let blurb: String }
    struct Item: Codable { let slug: String; let title: String; let tldr: String; let truth: [String] }
    struct Fixture: Codable { let topics: [Topic]; let items: [Item] }

    struct ItemRecord: Codable {
        let index: Int
        let slug: String
        let truth: [String]
        var answer: String?
        var ok: Bool?
        var share: Double?
        var probabilities: [String: Double]?
        var failure: String?
        var retries: Int
        let latency_ms: Int
    }

    struct Summary: Codable {
        let attempted: Int
        let completed: Int
        let top1: Int
        let out_of_schema: Int
        let refused: Int
        let failures: [String: Int]
        let retries: Int
        let latency_p50_ms: Int
        let latency_p90_ms: Int
        let latency_mean_ms: Int
        let share_right_mean: Double?
        let share_wrong_mean: Double?
        let unanimous_right: Int?
        let unanimous_wrong: Int?
        let gate: Int
        let gate_passed: Bool
        let indeterminate: Bool
    }

    struct Record: Codable {
        let run: String
        let os: String
        let backend: String
        let fixture: String
        let votes: Int
        let seed: UInt64
        let question: String
        let items: [ItemRecord]
        let summary: Summary
    }

    static let question = "Which topic does this note belong under?"

    func run() async throws {
        let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: fixture)))
        let backend: any DecisionBackend
        do {
            backend = try Backends.make(model: model)
        } catch {
            IO.stderr("INDETERMINATE: \(error.message) — \(error.remedy)")
            throw Exit.unavailable
        }
        if case .unavailable(let reason, let remedy) = backend.availability() {
            IO.stderr("INDETERMINATE: \(reason) — \(remedy)")
            throw Exit.unavailable
        }
        if let laya = backend as? LayaCoreMLBackend {
            let t = try laya.warmUp()
            print("laya: model loaded in \(t.wholeMilliseconds) ms (excluded from per-item latency)")
        }
        let engine = Verdict(backend: backend)
        let options = fx.topics.map { ChoiceOption(key: $0.slug, description: $0.title) }
        let policy = Policy(votes: votes, seed: seed)
        let items = Array(fx.items.prefix(limit ?? fx.items.count))

        var records: [ItemRecord] = []
        for (i, it) in items.enumerated() {
            let request = Request(
                state: "Title: \(it.title)\nSummary: \(it.tldr)",
                questions: [QuestionEntry(id: "topic", question: .choice(ChoiceQuestion(instructions: instructions, options: options)))],
                policy: policy)
            guard let response = await Self.decideOrNil(engine, request, item: i + 1) else { throw Exit.unavailable }
            let outcome = response.outcomes[0].outcome
            var rec = ItemRecord(index: i + 1, slug: it.slug, truth: it.truth, retries: response.retries,
                                 latency_ms: response.latency.wholeMilliseconds)
            switch outcome {
            case .decision(let d):
                guard case .choice(let key) = d.answer else { break }
                rec.answer = key
                rec.ok = it.truth.contains(key)
                rec.share = d.confidence
                rec.probabilities = d.distribution
                let shareText = d.confidence.map { String(format: "  share %.2f", $0) } ?? ""
                print("[\(i + 1)] \(it.slug)  \(key) \(rec.ok! ? "OK  " : "MISS")\(shareText)  \(rec.latency_ms) ms  truth=\(it.truth)")
            case .failure(let f):
                rec.failure = f.code.rawValue
                print("[\(i + 1)] \(it.slug)  FAIL \(f.code.rawValue) after \(f.retries) retries  \(rec.latency_ms) ms  — \(f.message)")
            }
            records.append(rec)
        }

        let summary = Self.summarise(records, gate: gate)
        print("""

        === SUMMARY backend=\(backend.name) votes=\(votes) seed=\(seed) os=\(IO.osVersion) ===
        top-1 in truth:   \(summary.top1)/\(summary.completed)  (attempted \(summary.attempted); gate >= \(gate) → \(summary.gate_passed ? "PASS" : "FAIL"))
        out-of-schema:    \(summary.out_of_schema)
        failures:         \(summary.failures.isEmpty ? "none" : summary.failures.description)  (refused \(summary.refused); engine retries \(summary.retries))
        latency per item: P50 \(summary.latency_p50_ms) ms · P90 \(summary.latency_p90_ms) ms · mean \(summary.latency_mean_ms) ms
        """)
        if votes >= 2 {
            func f(_ d: Double?) -> String { d.map { String(format: "%.2f", $0) } ?? "n/a" }
            print("winner share:     right mean \(f(summary.share_right_mean)) (unanimous \(summary.unanimous_right ?? 0)/\(summary.top1)) · wrong mean \(f(summary.share_wrong_mean)) (unanimous \(summary.unanimous_wrong ?? 0)/\(summary.completed - summary.top1))")
        }

        let record = Record(run: ISO8601DateFormatter().string(from: Date()), os: IO.osVersion, backend: backend.name,
                            fixture: fixture, votes: votes, seed: seed, question: instructions, items: records, summary: summary)
        if let out {
            try IO.writeAtomically(try Wire.encoder().encode(record), to: out)
            print("record:           \(out)")
        }
        if let baseline { try Self.diff(record, against: baseline) }

        if summary.indeterminate { throw Exit.unavailable }
        if !summary.gate_passed { throw Exit.failed }
    }

    /// Request-level failures (model unavailable, validation) make the whole replay indeterminate.
    static func decideOrNil(_ engine: Verdict, _ request: Request, item: Int) async -> Response? {
        do {
            return try await engine.decide(request)
        } catch {
            IO.stderr("INDETERMINATE at item \(item): \(error.code.rawValue) — \(error.message) — \(error.remedy)")
            return nil
        }
    }

    static func summarise(_ records: [ItemRecord], gate: Int) -> Summary {
        let completed = records.filter { $0.answer != nil }
        let top1 = completed.filter { $0.ok == true }.count
        var failures: [String: Int] = [:]
        for r in records { if let f = r.failure { failures[f, default: 0] += 1 } }
        let latencies = records.map(\.latency_ms).sorted()
        func pct(_ p: Double) -> Int {
            guard !latencies.isEmpty else { return 0 }
            return latencies[min(latencies.count - 1, Int(Double(latencies.count - 1) * p + 0.5))]
        }
        let right = completed.filter { $0.ok == true }.compactMap(\.share)
        let wrong = completed.filter { $0.ok == false }.compactMap(\.share)
        func mean(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
        let voting = completed.contains { $0.share != nil }
        let outOfSchema = failures["out_of_schema"] ?? 0
        let indeterminate = completed.isEmpty
        return Summary(
            attempted: records.count, completed: completed.count, top1: top1,
            out_of_schema: outOfSchema, refused: failures["refused"] ?? 0, failures: failures,
            retries: records.reduce(0) { $0 + $1.retries },
            latency_p50_ms: pct(0.5), latency_p90_ms: pct(0.9),
            latency_mean_ms: latencies.isEmpty ? 0 : latencies.reduce(0, +) / latencies.count,
            share_right_mean: voting ? mean(right) : nil, share_wrong_mean: voting ? mean(wrong) : nil,
            unanimous_right: voting ? right.filter { $0 >= 1.0 }.count : nil,
            unanimous_wrong: voting ? wrong.filter { $0 >= 1.0 }.count : nil,
            gate: gate, gate_passed: !indeterminate && top1 >= gate && outOfSchema == 0,
            indeterminate: indeterminate)
    }

    static func diff(_ record: Record, against path: String) throws {
        let prior = try JSONDecoder().decode(Record.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let before = Dictionary(uniqueKeysWithValues: prior.items.map { ($0.slug, $0) })
        var flips = 0
        print("\n=== BASELINE \(path): top-1 \(prior.summary.top1)/\(prior.summary.completed) → \(record.summary.top1)/\(record.summary.completed) ===")
        for it in record.items {
            guard let b = before[it.slug] else { print("  new item: \(it.slug)"); continue }
            if b.ok != it.ok || b.answer != it.answer {
                flips += 1
                print("  \(it.slug): \(b.answer ?? b.failure ?? "?") (\(b.ok == true ? "OK" : "MISS")) → \(it.answer ?? it.failure ?? "?") (\(it.ok == true ? "OK" : "MISS"))")
            }
        }
        print("flipped: \(flips)")
    }
}
