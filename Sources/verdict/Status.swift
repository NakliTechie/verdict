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
        let newest_gate_record: GateRecord?
    }

    struct GateRecord: Encodable {
        let path: String
        let gate_passed: Bool?
        let top1: Int?
        let completed: Int?
        let votes: Int?
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
            newest_gate_record: Self.newestRecord(in: evidence))
        IO.print(body, compact: compact)
        if !body.available { throw Exit.unavailable }
    }

    static func newestRecord(in dir: String) -> GateRecord? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        guard let newest = names.filter({ $0.hasPrefix("replay-") && $0.hasSuffix(".json") }).sorted().last else { return nil }
        let path = dir + "/" + newest
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = obj["summary"] as? [String: Any] else {
            return GateRecord(path: path, gate_passed: nil, top1: nil, completed: nil, votes: nil)
        }
        return GateRecord(path: path, gate_passed: summary["gate_passed"] as? Bool,
                          top1: summary["top1"] as? Int, completed: summary["completed"] as? Int,
                          votes: obj["votes"] as? Int)
    }
}
