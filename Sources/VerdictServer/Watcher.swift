import Foundation
import VerdictCore

/// Dataflow mode's operator (SPEC §12.3): reads pending events, asks each its type's questions, writes
/// decisions, marks the event done. An actor so its non-Sendable EventStore is safe across `await decide`.
public actor Watcher {
    public struct Report: Sendable {
        public var processed: Int
        public var skipped: Int
        public var decisions: Int
        public var failures: Int
    }

    let store: EventStore
    let topology: Topology
    let registry: Registry
    let batch: Int

    public init(dbPath: String, topology: Topology, registry: Registry, batch: Int = 50) throws {
        self.store = try EventStore(path: dbPath)
        self.topology = topology
        self.registry = registry
        self.batch = batch
    }

    /// Process the current backlog once. A request-level failure (model unavailable, bad topology) throws
    /// and leaves that event pending. Returns counts.
    @discardableResult
    public func drain() async throws -> Report {
        var report = Report(processed: 0, skipped: 0, decisions: 0, failures: 0)
        while true {
            let events = try store.pending(limit: batch)
            if events.isEmpty { break }
            for event in events {
                let now = ISO8601DateFormatter().string(from: Date())
                guard let type = topology.types[event.type] else {
                    try store.setStatus(eventID: event.id, status: "skipped", now: now)
                    report.skipped += 1
                    continue
                }
                guard let entry = registry.entry(for: type.model) else {
                    throw Watcher.Error(description: "event \(event.id): topology model `\(type.model)` is not served. `GET /v1/models` lists valid names.")
                }
                let request = Request(state: event.state, questions: type.questions)
                let response = try await Verdict(backend: entry.backend).decide(request)   // request-level Failure propagates
                var rows: [EventStore.DecisionRow] = []
                for (qid, outcome) in response.outcomes {
                    switch outcome {
                    case .decision(let d):
                        rows.append(row(qid: qid, decision: d, backend: response.backend))
                    case .failure(let f):
                        report.failures += 1
                        rows.append(EventStore.DecisionRow(questionID: qid, type: questionType(qid, request),
                                                           answer: nil, confidence: nil, confidenceKind: "failed",
                                                           probabilitiesJSON: nil, backend: response.backend,
                                                           failed: true, code: f.code.rawValue))
                    }
                }
                try store.complete(eventID: event.id, rows: rows, now: now)
                report.processed += 1
                report.decisions += rows.count
            }
        }
        return report
    }

    /// Poll forever: drain, then sleep `interval` seconds, until cancelled.
    public func run(interval: Duration) async throws {
        while !Task.isCancelled {
            _ = try await drain()
            try await Task.sleep(for: interval)
        }
    }

    // MARK: rows

    private func row(qid: String, decision d: Decision, backend: String) -> EventStore.DecisionRow {
        let answer: String
        let type: String
        switch d.answer {
        case .choice(let key): answer = key; type = "choice"
        case .score(let level, _): answer = String(level); type = "score"
        case .noul(let b): answer = b ? "true" : "false"; type = "noul"
        }
        var probsJSON: String? = nil
        if let dist = d.distribution, let data = try? JSONSerialization.data(withJSONObject: dist, options: [.sortedKeys]) {
            probsJSON = String(decoding: data, as: UTF8.self)
        }
        return EventStore.DecisionRow(questionID: qid, type: type, answer: answer, confidence: d.confidence,
                                      confidenceKind: d.confidenceKind.rawValue, probabilitiesJSON: probsJSON,
                                      backend: backend, failed: false, code: nil)
    }

    private func questionType(_ qid: String, _ request: Request) -> String {
        request.questions.first { $0.id == qid }?.question.typeName ?? "?"
    }

    public struct Error: Swift.Error, CustomStringConvertible { public let description: String }
}
