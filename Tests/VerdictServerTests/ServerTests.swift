import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing
import VerdictCore
@testable import VerdictServer

/// Scripted backend: returns the given sample for every call.
final class ScriptedBackend: DecisionBackend, Sendable {
    let name = "scripted"
    let producesDistribution: Bool
    let script: Mutex<[Result<Sample, BackendError>]>
    let available: BackendAvailability
    init(_ script: [Result<Sample, BackendError>], producesDistribution: Bool = false, available: BackendAvailability = .available) {
        self.script = Mutex(script)
        self.producesDistribution = producesDistribution
        self.available = available
    }
    func availability() -> BackendAvailability { available }
    func sample(state: String, question: Question, sampling: Sampling) async throws -> Sample {
        let next = script.withLock { s in s.isEmpty ? nil : s.removeFirst() }
        guard let next else { throw BackendError(code: .backendError, message: "script exhausted") }
        return try next.get()
    }
}

@Suite struct ServerTests {
    static let token = String(repeating: "ab", count: 32)

    static func config(_ backend: any DecisionBackend, model: String = "verdict-fm") -> VerdictServer.Config {
        let registry = Registry(entries: [model: .init(model: model, backend: backend, confidence: "test")])
        return VerdictServer.Config(port: 0, token: token, registry: registry)
    }

    static func app(_ backend: any DecisionBackend) -> some ApplicationProtocol {
        Application(router: VerdictServer.router(config(backend)))
    }

    static let auth: HTTPFields = [.authorization: "Bearer \(token)", .contentType: "application/json"]

    static func json(_ r: TestResponse) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(buffer: r.body)) as! [String: Any]
    }

    @Test func healthNeedsNoTokenAndListsBackends() async throws {
        try await Self.app(ScriptedBackend([])).test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { r in
                #expect(r.status == .ok)
                let j = try Self.json(r)
                #expect(j["status"] as? String == "ok")
                #expect((j["models"] as? [String]) == ["verdict-fm"])
                #expect(((j["backends"] as? [String: Any])?["verdict-fm"] as? [String: Any])?["available"] as? Bool == true)
            }
        }
    }

    @Test func healthReports503WhenNothingIsAvailable() async throws {
        let b = ScriptedBackend([], available: .unavailable(reason: "off", remedy: "turn on"))
        try await Self.app(b).test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { r in
                #expect(r.status == .serviceUnavailable)
                let j = try Self.json(r)
                #expect(j["status"] as? String == "unavailable")
            }
        }
    }

    @Test func everyOtherRouteIsTokenGated() async throws {
        try await Self.app(ScriptedBackend([])).test(.router) { client in
            for (uri, method) in [("/v1/models", HTTPRequest.Method.get), ("/v1/limits", .get), ("/v1/systemone", .post)] {
                try await client.execute(uri: uri, method: method) { r in
                    #expect(r.status == .unauthorized, "\(uri)")
                    #expect(r.headers[.wwwAuthenticate] == "Bearer")
                    let e = try Self.json(r)["error"] as! [String: Any]
                    #expect(e["code"] as? String == "validation")
                    #expect((e["remedy"] as? String)?.contains("verdictd token") == true)
                }
                try await client.execute(uri: uri, method: method, headers: [.authorization: "Bearer " + String(repeating: "00", count: 32)]) { r in
                    #expect(r.status == .unauthorized, "\(uri) wrong token")
                }
            }
        }
    }

    @Test func modelsAndLimits() async throws {
        try await Self.app(ScriptedBackend([])).test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get, headers: Self.auth) { r in
                #expect(r.status == .ok)
                let data = try Self.json(r)["data"] as! [[String: String]]
                #expect(data.map { $0["id"] } == ["verdict-fm"])
            }
            try await client.execute(uri: "/v1/limits", method: .get, headers: Self.auth) { r in
                #expect(r.status == .ok)
                let j = try Self.json(r)
                #expect(j["max_questions"] as? Int == 64)
            }
        }
    }

    @Test func systemoneRoundTripJevShape() async throws {
        let backend = ScriptedBackend([.success(Sample(raw: .key("billing"))), .success(Sample(raw: .bool(true))), .success(Sample(raw: .level(1)))])
        try await Self.app(backend).test(.router) { client in
            let body = ByteBuffer(string: Wire.exampleRequestJSON)
            try await client.execute(uri: "/v1/systemone", method: .post, headers: Self.auth, body: body) { r in
                #expect(r.status == .ok)
                #expect(r.headers[.init("x-verdict-backend")!] == "scripted")
                #expect(r.headers[.init("x-verdict-failures")!] == "0")
                let j = try Self.json(r)
                #expect(j["model"] as? String == "verdict-fm")
                let answers = j["answers"] as! [String: [String: Any]]
                #expect(answers["department"]?["choice"] as? String == "billing")
                #expect(answers["refund"]?["noul"] as? Double == 1.0)
                #expect(answers["urgency"]?["level"] as? Int == 1)
                #expect(answers["urgency"]?["confidence_kind"] as? String == "none")
                #expect((j["failures"] as! [String: Any]).isEmpty)
            }
        }
    }

    @Test func jevLatestAliasResolvesToDefaultBackend() async throws {
        let backend = ScriptedBackend([.success(Sample(raw: .bool(false)))])
        try await Self.app(backend).test(.router) { client in
            let body = ByteBuffer(string: #"{"model":"jev-latest","state":"s","questions":{"q":{"type":"noul","instructions":"i"}}}"#)
            try await client.execute(uri: "/v1/systemone", method: .post, headers: Self.auth, body: body) { r in
                #expect(r.status == .ok)
                let j = try Self.json(r)
                #expect(j["model"] as? String == "verdict-fm")
            }
        }
    }

    @Test func malformedAndUnknownModelAre422() async throws {
        try await Self.app(ScriptedBackend([])).test(.router) { client in
            try await client.execute(uri: "/v1/systemone", method: .post, headers: Self.auth, body: ByteBuffer(string: "{not json")) { r in
                #expect(r.status == .unprocessableContent)
                let e = try Self.json(r)["error"] as! [String: Any]
                #expect(e["code"] as? String == "validation")
            }
            try await client.execute(uri: "/v1/systemone", method: .post, headers: Self.auth,
                                     body: ByteBuffer(string: #"{"model":"gpt-9","state":"s","questions":{"q":{"type":"noul","instructions":"i"}}}"#)) { r in
                #expect(r.status == .unprocessableContent)
                let e = try Self.json(r)["error"] as! [String: Any]
                #expect((e["remedy"] as? String)?.contains("/v1/models") == true)
            }
            try await client.execute(uri: "/v1/systemone", method: .post, headers: Self.auth,
                                     body: ByteBuffer(string: #"{"state":"   ","questions":{"q":{"type":"noul","instructions":"i"}}}"#)) { r in
                #expect(r.status == .unprocessableContent)
                let e = try Self.json(r)["error"] as! [String: Any]
                #expect((e["message"] as? String)?.contains("state") == true)
            }
        }
    }

    @Test func modelUnavailableIs503() async throws {
        let b = ScriptedBackend([], available: .unavailable(reason: "Apple Intelligence is off", remedy: "turn it on"))
        try await Self.app(b).test(.router) { client in
            try await client.execute(uri: "/v1/systemone", method: .post, headers: Self.auth, body: ByteBuffer(string: Wire.exampleRequestJSON)) { r in
                #expect(r.status == .serviceUnavailable)
                let e = try Self.json(r)["error"] as! [String: Any]
                #expect(e["code"] as? String == "model_unavailable")
                #expect(e["retryable"] as? Bool == true)
            }
        }
    }

    @Test func perQuestionFailuresStayInBodyWith200() async throws {
        let b = ScriptedBackend([.failure(BackendError(code: .refused, message: "x")), .failure(BackendError(code: .refused, message: "y")),
                                 .success(Sample(raw: .bool(true))), .success(Sample(raw: .level(2)))])
        try await Self.app(b).test(.router) { client in
            try await client.execute(uri: "/v1/systemone", method: .post, headers: Self.auth, body: ByteBuffer(string: Wire.exampleRequestJSON)) { r in
                #expect(r.status == .ok)
                #expect(r.headers[.init("x-verdict-failures")!] == "1")
                let j = try Self.json(r)
                let failures = j["failures"] as! [String: [String: Any]]
                #expect(failures["department"]?["code"] as? String == "refused")
                #expect((j["answers"] as! [String: Any]).count == 2)
            }
        }
    }

    @Test func decodedBackendIgnoresVotes() async throws {
        let b = ScriptedBackend([.success(Sample(raw: .key("billing"), distribution: ["billing": 0.8, "technical": 0.2]))], producesDistribution: true)
        try await Self.app(b).test(.router) { client in
            let body = ByteBuffer(string: #"{"state":"s","questions":{"d":{"type":"choice","instructions":"i","criteria":{"billing":null,"technical":null}}},"policy":{"votes":5}}"#)
            try await client.execute(uri: "/v1/systemone", method: .post, headers: Self.auth, body: body) { r in
                #expect(r.status == .ok)
                let j = try Self.json(r)
                let d = (j["answers"] as! [String: [String: Any]])["d"]!
                #expect(d["confidence_kind"] as? String == "decoded")
                #expect(d["samples"] as? Int == 1)
                #expect((d["probabilities"] as? [String: Double])?["billing"] == 0.8)
            }
        }
    }

    @Test func tokenHelpers() throws {
        #expect(Token.isValid(Self.token))
        #expect(!Token.isValid("short"))
        #expect(Token.matches(Self.token, Self.token))
        #expect(!Token.matches(Self.token, String(repeating: "ba", count: 32)))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verdict-test-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("token")
        let t1 = try Token.loadOrCreate(at: file)
        let t2 = try Token.loadOrCreate(at: file)
        #expect(t1 == t2)
        #expect(Token.isValid(t1))
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        try? FileManager.default.removeItem(at: dir)
    }
}
