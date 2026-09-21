import ArgumentParser
import Foundation
import VerdictCore

/// The one perception act (SPEC §0, §7).
struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report whether a decide can succeed: backend, availability, remedy, limits, newest gate record.")

    @Flag(help: "One-line JSON instead of pretty JSON.") var compact = false
    @Option(help: "Directory holding replay records.") var evidence = "evidence"

    struct Body: Encodable {
        let backend: String
        let available: Bool
        let reason: String?
        let remedy: String?
        let os: String
        let supported_languages: Int
        let limits: [String: Int]
        let gate_records: [GateRecord]
    }

    struct GateRecord: Encodable {
        let path: String
        let run: String?
        let votes: Int?
        let top1: Int?
        let completed: Int?
        let out_of_schema: Int?
        let latency_p50_ms: Int?
        let gate_passed: Bool?
    }

    func run() async throws {
        let backend = FoundationModelsBackend()
        let availability = backend.availability()
        var reason: String? = nil, remedy: String? = nil
        if case .unavailable(let r, let m) = availability { reason = r; remedy = m }
        let body = Body(
            backend: backend.name,
            available: availability == .available,
            reason: reason, remedy: remedy,
            os: IO.osVersion,
            supported_languages: backend.supportedLanguageCount,
            limits: ["max_questions": Limits.maxQuestions, "max_options": Limits.maxOptions, "min_options": Limits.minOptions],
            gate_records: Self.records(in: evidence))
        IO.print(body, compact: compact)
        if !body.available { throw Exit.unavailable }
    }

    /// Every committed gate record, oldest first by its `run` timestamp. One line each; bounded by
    /// the number of gate runs, never by fixture or model size.
    static func records(in dir: String) -> [GateRecord] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        let records = names.filter { $0.hasPrefix("replay-") && $0.hasSuffix(".json") }.map { name -> GateRecord in
            let path = dir + "/" + name
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let summary = obj["summary"] as? [String: Any] else {
                return GateRecord(path: path, run: nil, votes: nil, top1: nil, completed: nil,
                                  out_of_schema: nil, latency_p50_ms: nil, gate_passed: nil)
            }
            return GateRecord(path: path, run: obj["run"] as? String, votes: obj["votes"] as? Int,
                              top1: summary["top1"] as? Int, completed: summary["completed"] as? Int,
                              out_of_schema: summary["out_of_schema"] as? Int,
                              latency_p50_ms: summary["latency_p50_ms"] as? Int,
                              gate_passed: summary["gate_passed"] as? Bool)
        }
        return records.sorted { ($0.run ?? "") < ($1.run ?? "") }
    }
}
