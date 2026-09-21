import ArgumentParser
import Foundation
import VerdictCore

/// The one perception act (SPEC §0, §7).
struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report whether a decide can succeed: backend, availability, remedy, limits, newest gate record.")

    @Flag(help: "One-line JSON instead of pretty JSON.") var compact = false
    @Option(help: "Directory holding replay records.") var evidence = "evidence"
    @Flag(help: "SHA-256 every Laya checkpoint file against its manifest (reads 843 MB).") var verify = false

    struct Body: Encodable {
        let backends: [BackendStatus]
        let os: String
        let limits: [String: Int]
        let gate_records: [GateRecord]
        var available: Bool { backends.contains { $0.available } }
    }

    struct BackendStatus: Encodable {
        let model: String
        let backend: String
        let available: Bool
        let reason: String?
        let remedy: String?
        let detail: [String: String]?
    }

    struct GateRecord: Encodable {
        let path: String
        let run: String?
        let backend: String?
        let votes: Int?
        let top1: Int?
        let completed: Int?
        let out_of_schema: Int?
        let latency_p50_ms: Int?
        let gate_passed: Bool?
    }

    func run() async throws {
        var backends: [BackendStatus] = []

        let fm = FoundationModelsBackend()
        var fmReason: String? = nil, fmRemedy: String? = nil
        if case .unavailable(let r, let m) = fm.availability() { fmReason = r; fmRemedy = m }
        backends.append(BackendStatus(model: "verdict-fm", backend: fm.name, available: fmReason == nil, reason: fmReason, remedy: fmRemedy,
                                      detail: ["supported_languages": String(fm.supportedLanguageCount), "confidence": "none (greedy) or agreement (votes >= 2)"]))

        let layaDir = LayaCoreMLBackend.defaultDirectory
        switch LayaCoreMLBackend.availability(directory: layaDir) {
        case .available:
            var detail: [String: String] = ["directory": layaDir.path, "confidence": "decoded", "compute": "VERDICT_LAYA_COMPUTE=\(ProcessInfo.processInfo.environment["VERDICT_LAYA_COMPUTE"] ?? "cpu (default)")"]
            var reason: String? = nil, remedy: String? = nil
            if let laya = try? LayaCoreMLBackend(directory: layaDir) {
                detail["source"] = laya.manifest.source
                detail["max_tokens"] = String(laya.manifest.maxLength)
                detail["max_options"] = String(laya.manifest.maxOptions)
                if verify {
                    let bad = try laya.verifyChecksums()
                    detail["checksums"] = bad.isEmpty ? "all \(laya.manifest.files.count) files match" : "MISMATCH: \(bad.joined(separator: ", "))"
                    if !bad.isEmpty { reason = "Checksum mismatch in \(bad.count) file(s)."; remedy = "Re-download: " + LayaCoreMLBackend.downloadRemedy(for: layaDir) }
                }
            }
            backends.append(BackendStatus(model: "verdict-laya", backend: "laya-coreml", available: reason == nil, reason: reason, remedy: remedy, detail: detail))
        case .unavailable(let r, let m):
            backends.append(BackendStatus(model: "verdict-laya", backend: "laya-coreml", available: false, reason: r, remedy: m, detail: nil))
        }

        let body = Body(backends: backends, os: IO.osVersion,
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
                return GateRecord(path: path, run: nil, backend: nil, votes: nil, top1: nil, completed: nil,
                                  out_of_schema: nil, latency_p50_ms: nil, gate_passed: nil)
            }
            return GateRecord(path: path, run: obj["run"] as? String, backend: obj["backend"] as? String, votes: obj["votes"] as? Int,
                              top1: summary["top1"] as? Int, completed: summary["completed"] as? Int,
                              out_of_schema: summary["out_of_schema"] as? Int,
                              latency_p50_ms: summary["latency_p50_ms"] as? Int,
                              gate_passed: summary["gate_passed"] as? Bool)
        }
        return records.sorted { ($0.run ?? "") < ($1.run ?? "") }
    }
}
