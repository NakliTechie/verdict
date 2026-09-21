import Foundation
import Testing
import VerdictCore
@testable import VerdictServer

@Suite(.serialized) struct DataflowTests {
    static func tempDB() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("verdict-df-\(UUID().uuidString).sqlite").path
    }

    static let topology = try! Topology(data: Data("""
    {"version": 1, "types": {
      "clipboard": {"model": "verdict-fm", "questions": {
        "is_url": {"type": "noul", "instructions": "Is it a URL?"},
        "sensitivity": {"type": "score", "instructions": "How sensitive?", "criteria": ["public", "personal", "secret"]}
      }},
      "page": {"questions": {"topic": {"type": "choice", "instructions": "Which?", "criteria": {"a": null, "b": null}}}}
    }}
    """.utf8))

    static func registry(_ backend: any DecisionBackend, model: String = "verdict-fm") -> Registry {
        Registry(entries: [model: .init(model: model, backend: backend, confidence: "test")])
    }

    @Test func topologyParsesQuestionsInWireShape() {
        #expect(Self.topology.version == 1)
        let clip = Self.topology.types["clipboard"]!
        #expect(clip.model == "verdict-fm")
        #expect(clip.questions.map(\.id) == ["is_url", "sensitivity"])   // sorted
        #expect(clip.questions[1].question.typeName == "score")
        #expect(Self.topology.types["page"]!.model == "verdict-fm")      // default model
    }

    @Test func badTopologyThrows() {
        #expect(throws: Topology.LoadError.self) { try Topology(data: Data(#"{"version":1,"types":{}}"#.utf8)) }
        #expect(throws: (any Error).self) { try Topology(data: Data(#"{"types":{"x":{"questions":{"q":{"type":"rank","instructions":"i"}}}}}"#.utf8)) }
    }

    @Test func pendingEventGetsDecisionsAndIsMarkedDone() async throws {
        let db = Self.tempDB(); defer { try? FileManager.default.removeItem(atPath: db) }
        let store = try EventStore(path: db)
        let id = try store.insertEvent(type: "clipboard", state: "https://example.com")
        let backend = ScriptedBackend([.success(Sample(raw: .bool(true))), .success(Sample(raw: .level(2)))])
        let watcher = try Watcher(dbPath: db, topology: Self.topology, registry: Self.registry(backend))
        let r = try await watcher.drain()
        #expect(r.processed == 1 && r.decisions == 2 && r.failures == 0 && r.skipped == 0)
        #expect(try store.status(eventID: id) == "done")
        let rows = try store.decisions(eventID: id)
        #expect(rows.map(\.questionID) == ["is_url", "sensitivity"])
        #expect(rows[0].answer == "true" && rows[0].confidenceKind == "none")
        #expect(rows[1].answer == "2" && rows[1].type == "score")
        #expect(rows.allSatisfy { !$0.failed })
    }

    @Test func decodedBackendWritesConfidenceAndProbabilities() async throws {
        let db = Self.tempDB(); defer { try? FileManager.default.removeItem(atPath: db) }
        let store = try EventStore(path: db)
        let id = try store.insertEvent(type: "page", state: "x")
        let backend = ScriptedBackend([.success(Sample(raw: .key("a"), distribution: ["a": 0.9, "b": 0.1]))], producesDistribution: true)
        _ = try await Watcher(dbPath: db, topology: Self.topology, registry: Self.registry(backend)).drain()
        let row = try store.decisions(eventID: id)[0]
        #expect(row.answer == "a")
        #expect(row.confidenceKind == "decoded")
        #expect((row.confidence ?? 0) > 0.5)
        #expect(row.probabilitiesJSON?.contains("\"a\":0.9") == true)
    }

    @Test func unknownEventTypeIsSkippedNotAnswered() async throws {
        let db = Self.tempDB(); defer { try? FileManager.default.removeItem(atPath: db) }
        let store = try EventStore(path: db)
        let id = try store.insertEvent(type: "mystery", state: "x")
        let r = try await Watcher(dbPath: db, topology: Self.topology, registry: Self.registry(ScriptedBackend([]))).drain()
        #expect(r.skipped == 1 && r.processed == 0)
        #expect(try store.status(eventID: id) == "skipped")
        #expect(try store.decisions(eventID: id).isEmpty)
    }

    @Test func perQuestionFailureIsAFailedRowAndEventStillCompletes() async throws {
        let db = Self.tempDB(); defer { try? FileManager.default.removeItem(atPath: db) }
        let store = try EventStore(path: db)
        let id = try store.insertEvent(type: "clipboard", state: "x")
        // is_url refuses (retry once then fail), sensitivity answers.
        let backend = ScriptedBackend([.failure(BackendError(code: .refused, message: "a")), .failure(BackendError(code: .refused, message: "b")),
                                       .success(Sample(raw: .level(1)))])
        let r = try await Watcher(dbPath: db, topology: Self.topology, registry: Self.registry(backend)).drain()
        #expect(r.processed == 1 && r.failures == 1)
        #expect(try store.status(eventID: id) == "done")
        let rows = try store.decisions(eventID: id)
        let urlRow = rows.first { $0.questionID == "is_url" }!
        #expect(urlRow.failed && urlRow.code == "refused" && urlRow.answer == nil && urlRow.confidenceKind == "failed")
        #expect(rows.first { $0.questionID == "sensitivity" }!.answer == "1")
    }

    @Test func drainIsIdempotentAndDoneEventsAreNotReprocessed() async throws {
        let db = Self.tempDB(); defer { try? FileManager.default.removeItem(atPath: db) }
        let store = try EventStore(path: db)
        _ = try store.insertEvent(type: "clipboard", state: "x")
        let first = ScriptedBackend([.success(Sample(raw: .bool(false))), .success(Sample(raw: .level(0)))])
        _ = try await Watcher(dbPath: db, topology: Self.topology, registry: Self.registry(first)).drain()
        // Second drain with an empty script: if it tried to reprocess it would throw "script exhausted".
        let r = try await Watcher(dbPath: db, topology: Self.topology, registry: Self.registry(ScriptedBackend([]))).drain()
        #expect(r.processed == 0)
        #expect(try store.count(status: "done") == 1)
    }

    @Test func requestLevelFailureLeavesEventPendingAndThrows() async throws {
        let db = Self.tempDB(); defer { try? FileManager.default.removeItem(atPath: db) }
        let store = try EventStore(path: db)
        let id = try store.insertEvent(type: "clipboard", state: "x")
        let backend = ScriptedBackend([], available: .unavailable(reason: "off", remedy: "on"))
        let watcher = try Watcher(dbPath: db, topology: Self.topology, registry: Self.registry(backend))
        await #expect(throws: Failure.self) { try await watcher.drain() }
        #expect(try store.status(eventID: id) == "pending")   // never a fabricated done
        #expect(try store.decisions(eventID: id).isEmpty)
    }

    @Test func schemaSurvivesReopen() throws {
        let db = Self.tempDB(); defer { try? FileManager.default.removeItem(atPath: db) }
        let id = try EventStore(path: db).insertEvent(type: "clipboard", state: "x")
        // Reopen: ensureSchema is IF NOT EXISTS, so the event persists.
        let store2 = try EventStore(path: db)
        #expect(try store2.status(eventID: id) == "pending")
        #expect(try store2.pending(limit: 10).count == 1)
    }
}
