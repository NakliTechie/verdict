import ArgumentParser
import CoreML
import Foundation
import VerdictCore

/// Measured cost per backend on this Mac, so a driver picks `model` and `votes` from numbers, not lore.
struct Bench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Warm-latency probe: a short noul and a 26-way choice per backend; Laya also reports Core ML op placement.")

    @Option(help: "Backends to probe, comma-separated.") var models = "verdict-fm,verdict-laya"
    @Option(help: "Warm iterations per case (after 2 discarded).") var iterations = 5
    @Flag(help: "One-line JSON.") var compact = false

    struct Result: Encodable {
        let model: String
        let backend: String
        let load_ms: Int?
        let cases: [Case]
        let op_placement: [String: Int]?
        struct Case: Encodable { let name: String; let first_ms: Int; let warm_p50_ms: Int; let tokens_note: String }
    }

    static let shortState = "I was charged twice. Please refund the duplicate."
    static let shortQuestion = Question.noul(NoulQuestion(instructions: "Does the user request a refund?"))
    static let wideState = """
        Title: edge0 — streaming-MoE inference: SSD expert offload + Recover-LoRA + prerouter
        Summary: An Apache-2.0 Python framework that runs sparse-MoE models far larger than available RAM by mmapping expert weights off SSD and predicting routing one step ahead so the loads overlap the forward pass. Two ready-to-run 4-bit tiers ship with trained LoRA + prerouter adapters.
        """
    static let wideQuestion = Question.choice(ChoiceQuestion(instructions: "Which topic does this note belong under?", options: [
        "ai-agents", "computing-foundations", "consumer-gpu-inference", "cs-best-papers-concepts", "cybersecurity-ai", "diffusion-language-models",
        "distributed-systems-databases", "economics-of-ai", "frontier-ai-labs", "human-impact-of-ai", "india-political-economy", "investing-markets",
        "job-search", "llm-architecture", "llm-evaluation", "local-first-tools", "machine-learning-foundations", "multimodal-models",
        "open-data-knowledge-graphs", "optical-analog-computing", "rl-post-training", "robotics-manipulation", "speech-audio-models",
        "synthetic-populations", "typed-decision-models", "web-scraping",
    ].map { ChoiceOption(key: $0, description: $0.replacingOccurrences(of: "-", with: " ").capitalized) }))

    func run() async throws {
        var results: [Result] = []
        for model in models.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }) {
            let backend: any DecisionBackend
            do { backend = try Backends.make(model: model) } catch {
                IO.stderr("\(model): \(error.message) — \(error.remedy)")
                continue
            }
            if case .unavailable(let r, let m) = backend.availability() {
                IO.stderr("\(model): \(r) — \(m)")
                continue
            }
            var load: Int? = nil
            var placement: [String: Int]? = nil
            if let laya = backend as? LayaCoreMLBackend {
                load = try laya.warmUp().wholeMilliseconds
                placement = try? await laya.opPlacement()
            }
            var cases: [Result.Case] = []
            for (name, state, q, note) in [("short-noul", Self.shortState, Self.shortQuestion, "~40 tokens, 2 options"),
                                          ("wide-choice", Self.wideState, Self.wideQuestion, "~370 tokens, 26 options")] {
                var ms: [Int] = []
                for _ in 0..<(iterations + 2) {
                    let clock = ContinuousClock()
                    let t0 = clock.now
                    _ = try await backend.sample(state: state, question: q, sampling: .greedy)
                    ms.append((clock.now - t0).wholeMilliseconds)
                }
                let warm = Array(ms.dropFirst(2)).sorted()
                cases.append(.init(name: name, first_ms: ms[0], warm_p50_ms: warm[warm.count / 2], tokens_note: note))
            }
            results.append(Result(model: Backends.canonicalModel(model), backend: backend.name, load_ms: load, cases: cases, op_placement: placement))
        }
        IO.print(results, compact: compact)
    }
}
