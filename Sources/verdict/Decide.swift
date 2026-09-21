import ArgumentParser
import Foundation
import VerdictCore

struct Decide: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Answer typed questions about a state. Prints one Jev-compatible JSON document.",
        discussion: """
            Either pass a Jev request (`--request req.json`, `-` for stdin), or build one question from
            flags: `--state f.txt --choice "a|b|c"`. Option syntax: `key|key` or `key=description|key=description`.
            """)

    @Option(help: "Jev request JSON file, or `-` for stdin.") var request: String?
    @Flag(help: "Print an example request and exit.") var example = false

    @Option(help: "State text file, or `-` for stdin.") var state: String?
    @Option(help: "Choice options, `k1|k2` or `k1=desc|k2=desc`.") var choice: String?
    @Option(help: "Score rubric levels, lowest first, `l0|l1|l2`.") var score: String?
    @Flag(help: "Ask a yes/no question (with --ask).") var noul = false
    @Option(help: "The question's instructions.") var ask: String?
    @Option(help: "Question id in the output.") var id = "q"
    @Option(help: "Backend: verdict-fm (Foundation Models, default) or verdict-laya (Laya Core ML). Overrides the request's `model`.") var model: String?
    @Option(help: "1 = greedy (no confidence); N >= 2 = N sampled runs, agreement confidence.") var votes = 1
    @Option(help: "Base seed for sampled runs.") var seed: UInt64 = 1
    @Flag(help: "One-line JSON.") var compact = false

    func run() async throws {
        if example {
            print(Wire.exampleRequestJSON)
            return
        }
        let wire: Wire.Request
        do {
            wire = try buildRequest()
        } catch {
            IO.print(Wire.ErrorBody(error), compact: compact)
            throw Exit.usage
        }
        let core = wire.toCore()
        let backend: any DecisionBackend
        do {
            backend = try Backends.make(model: model ?? wire.model)
        } catch {
            IO.print(Wire.ErrorBody(error), compact: compact)
            throw error.code == .modelUnavailable ? Exit.unavailable : Exit.usage
        }
        let engine = Verdict(backend: backend)
        let response: Response
        do {
            response = try await engine.decide(core)
        } catch {
            IO.print(Wire.ErrorBody(error), compact: compact)
            throw error.code == .modelUnavailable ? Exit.unavailable : Exit.usage
        }
        IO.print(Wire.Response(response, request: core, model: Backends.canonicalModel(model ?? wire.model)), compact: compact)
        if response.failed { throw Exit.failed }
    }

    func buildRequest() throws(Failure) -> Wire.Request {
        if let request {
            guard let data = try? IO.readInput(request) else {
                throw Failure(id: nil, code: .validation, message: "Cannot read `\(request)`.",
                              remedy: "Pass a readable file path or `-` for stdin.")
            }
            return try Wire.decodeRequest(data)
        }
        guard let state, let stateData = try? IO.readInput(state),
              let stateText = String(data: stateData, encoding: .utf8) else {
            throw Failure(id: nil, code: .validation, message: "`--state <file|->` is required without `--request`.",
                          remedy: "verdict decide --state f.txt --choice \"a|b|c\" [--ask \"...\"]")
        }
        let question: Question
        let kinds = [choice != nil, score != nil, noul].filter { $0 }.count
        guard kinds == 1 else {
            throw Failure(id: nil, code: .validation, message: "Pass exactly one of --choice, --score, --noul (got \(kinds)).",
                          remedy: "verdict decide --state f.txt --choice \"a|b|c\"")
        }
        if let choice {
            let options = Self.parseOptions(choice)
            question = .choice(ChoiceQuestion(instructions: ask ?? "Which option fits the state best?", options: options))
        } else if let score {
            let levels = score.split(separator: "|", omittingEmptySubsequences: true).map { String($0).trimmingCharacters(in: .whitespaces) }
            question = .score(ScoreQuestion(instructions: ask ?? "Which level fits the state best?", levels: levels))
        } else {
            guard let ask else {
                throw Failure(id: nil, code: .validation, message: "--noul needs --ask \"<yes/no question>\".",
                              remedy: "verdict decide --state f.txt --noul --ask \"Is this a refund request?\"")
            }
            question = .noul(NoulQuestion(instructions: ask))
        }
        return Wire.Request(model: Wire.defaultModel, state: stateText, questions: [id: question],
                            policy: Wire.Policy(votes: votes, seed: seed))
    }

    static func parseOptions(_ spec: String) -> [ChoiceOption] {
        spec.split(separator: "|", omittingEmptySubsequences: true).map { part in
            let s = String(part)
            guard let eq = s.firstIndex(of: "=") else {
                return ChoiceOption(key: s.trimmingCharacters(in: .whitespaces))
            }
            let key = String(s[..<eq]).trimmingCharacters(in: .whitespaces)
            let desc = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            return ChoiceOption(key: key, description: desc)
        }
    }
}
