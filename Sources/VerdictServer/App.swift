import Foundation
import HTTPTypes
import Hummingbird
import Logging
import VerdictCore

/// `verdictd`: Jev-compatible `POST /v1/systemone` on loopback, bearer-token gated. SPEC §11.
public enum VerdictServer {
    public static let defaultPort = 7311
    public static let maxBodyBytes = 1 << 20   // 1 MiB; a 64-question request with 64 options each fits with room

    public struct Config: Sendable {
        public var port: Int
        public var token: String
        public var registry: Registry
        public var startedAt: Date
        public init(port: Int = defaultPort, token: String, registry: Registry, startedAt: Date = Date()) {
            self.port = port
            self.token = token
            self.registry = registry
            self.startedAt = startedAt
        }
    }

    public static func application(_ config: Config, logger: Logger? = nil) -> some ApplicationProtocol {
        let router = router(config)
        var appConfig = ApplicationConfiguration(address: .hostname("127.0.0.1", port: config.port), serverName: "verdictd")
        appConfig.reuseAddress = true
        return Application(router: router, configuration: appConfig, logger: logger)
    }

    public static func router(_ config: Config) -> Router<BasicRequestContext> {
        let router = Router()
        router.add(middleware: AuthMiddleware(token: config.token))

        router.get("/health") { _, _ in
            var backends: [String: HealthBody.Backend] = [:]
            for (name, e) in config.registry.entries {
                var reason: String? = nil
                if case .unavailable(let r, _) = e.backend.availability() { reason = r }
                backends[name] = .init(backend: e.backend.name, available: reason == nil, reason: reason, confidence: e.confidence)
            }
            let ok = backends.values.contains { $0.available }
            let body = HealthBody(status: ok ? "ok" : "unavailable", bind: "127.0.0.1:\(config.port)",
                                  models: config.registry.models, backends: backends,
                                  uptime_s: Int(Date().timeIntervalSince(config.startedAt)),
                                  limits: limits, version: version)
            return try json(body, status: ok ? .ok : .serviceUnavailable)
        }

        router.get("/v1/models") { _, _ in
            let data = config.registry.models.map { ["id": $0, "object": "model", "owned_by": "verdict"] }
            return try json(["object": "list", "data": data] as [String: Any], status: .ok)
        }

        router.get("/v1/limits") { _, _ in
            try json(limits, status: .ok)
        }

        router.post("/v1/systemone") { request, context in
            let buffer: ByteBuffer
            do {
                var req = request
                buffer = try await req.collectBody(upTo: maxBodyBytes)
            } catch {
                return try Self.error(Failure(id: nil, code: .validation, message: "Body exceeds \(maxBodyBytes) bytes.",
                                         remedy: "Shorten `state` or split the questions across requests."), status: .contentTooLarge)
            }
            let wire: Wire.Request
            switch Result(catching: { () throws(Failure) in try Wire.decodeRequest(Data(buffer.readableBytesView)) }) {
            case .success(let w): wire = w
            case .failure(let f): return try Self.error(f, status: .unprocessableContent)
            }
            guard let entry = config.registry.entry(for: wire.model) else {
                return try Self.error(Failure(id: nil, code: .validation, message: "Unknown model `\(wire.model ?? "")`.",
                                              remedy: "GET /v1/models lists the served models."), status: .unprocessableContent)
            }
            let core = wire.toCore()
            let response: VerdictCore.Response
            do {
                response = try await Verdict(backend: entry.backend).decide(core)
            } catch let f as Failure {
                return try Self.error(f, status: status(for: f.code))
            }
            let body = Wire.Response(response, request: core, model: entry.model)
            var http = try json(body, status: .ok)
            http.headers[.init("x-verdict-backend")!] = entry.backend.name
            http.headers[.init("x-verdict-latency-ms")!] = String(response.latency.wholeMilliseconds)
            http.headers[.init("x-verdict-failures")!] = String(body.failures.count)
            return http
        }
        return router
    }

    // MARK: Bodies

    static let limits: [String: Int] = [
        "max_questions": Limits.maxQuestions, "max_options": Limits.maxOptions, "min_options": Limits.minOptions,
        "max_body_bytes": maxBodyBytes, "max_votes": 25,
    ]
    public static let version = "0.2.0"

    struct HealthBody: Encodable {
        struct Backend: Encodable { let backend: String; let available: Bool; let reason: String?; let confidence: String }
        let status: String
        let bind: String
        let models: [String]
        let backends: [String: Backend]
        let uptime_s: Int
        let limits: [String: Int]
        let version: String
    }

    /// Failure code → HTTP status. One status per distinct next action (SPEC §0).
    static func status(for code: FailureCode) -> HTTPResponse.Status {
        switch code {
        case .validation, .outOfSchema, .decodingFailure: .unprocessableContent
        case .modelUnavailable: .serviceUnavailable
        case .rateLimited, .concurrentRequests: .tooManyRequests
        case .contextExceeded: .contentTooLarge
        case .refused, .guardrailViolation, .unsupportedLanguage, .backendError: .badGateway
        }
    }

    static func json(_ value: some Encodable, status: HTTPResponse.Status) throws -> Response {
        let data = try Wire.encoder(compact: true).encode(value)
        return Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(data: data)))
    }

    static func json(_ value: [String: Any], status: HTTPResponse.Status) throws -> Response {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(data: data)))
    }

    static func error(_ f: Failure, status: HTTPResponse.Status) throws -> Response {   // named `error` shadows the catch binding; always call as Self.error
        try json(Wire.ErrorBody(f), status: status)
    }
}

/// Bearer gate on every route except `/health`, which is the one perception act and carries nothing sensitive.
struct AuthMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext
    let token: String

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        if request.uri.path == "/health" { return try await next(request, context) }
        let header = request.headers[.authorization] ?? ""
        let presented = header.hasPrefix("Bearer ") ? String(header.dropFirst(7)) : ""
        guard Token.matches(presented, token) else {
            var r = try VerdictServer.error(
                Failure(id: nil, code: .validation, message: "Missing or wrong bearer token.",
                        remedy: "Send `Authorization: Bearer <token>`; the token is in \(Token.defaultFile.path) (`verdictd token` prints it)."),
                status: .unauthorized)
            r.headers[.wwwAuthenticate] = "Bearer"
            return r
        }
        return try await next(request, context)
    }
}
