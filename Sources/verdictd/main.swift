import ArgumentParser
import Foundation
import Logging
import VerdictCore
import VerdictServer

@main
struct VerdictD: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verdictd",
        abstract: "verdict's loopback face: Jev-compatible POST /v1/systemone on 127.0.0.1, bearer-token gated.",
        discussion: """
            Binds 127.0.0.1 only; there is no flag to change that. The token lives in
            ~/Library/Application Support/verdict/token (created on first start, mode 0600).
            Routes: GET /health (no token) · GET /v1/models · GET /v1/limits · POST /v1/systemone.
            """,
        version: VerdictServer.version,
        subcommands: [Serve.self, TokenCmd.self],
        defaultSubcommand: Serve.self)
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve", abstract: "Run the server (default).")

    @Option(help: "Loopback port.") var port = VerdictServer.defaultPort
    @Option(help: "Token file (created if absent).") var tokenFile = Token.defaultFile.path
    @Flag(help: "Do not load the Laya model at start (it then loads on first use, ~3 s).") var noWarm = false
    @Option(help: "Write the pid here while running.") var pidfile: String?
    @Option(help: "Log level: trace|debug|info|notice|warning|error.") var logLevel = "info"

    func run() async throws {
        let token = try Token.loadOrCreate(at: URL(fileURLWithPath: tokenFile))
        let registry = Registry()
        var logger = Logger(label: "verdictd")
        logger.logLevel = Logger.Level(rawValue: logLevel) ?? .info
        if !noWarm {
            for (model, t) in await registry.warm() { logger.info("warmed \(model) in \(t.wholeMilliseconds) ms") }
        }
        if let pidfile {
            try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: URL(fileURLWithPath: pidfile), options: .atomic)
        }
        defer { if let pidfile { try? FileManager.default.removeItem(atPath: pidfile) } }
        logger.info("verdictd \(VerdictServer.version) listening on http://127.0.0.1:\(port)  models=\(registry.models)  token=\(tokenFile)")
        let app = VerdictServer.application(.init(port: port, token: token, registry: registry), logger: logger)
        try await app.runService()
    }
}

struct TokenCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "token", abstract: "Print the bearer token (creating it if absent).")
    @Option(help: "Token file.") var tokenFile = Token.defaultFile.path
    @Flag(help: "Print the file path instead of the token.") var path = false

    func run() throws {
        if path { print(tokenFile); return }
        print(try Token.loadOrCreate(at: URL(fileURLWithPath: tokenFile)))
    }
}
