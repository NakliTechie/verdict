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
        subcommands: [Serve.self, TokenCmd.self, Watch.self, Install.self, Uninstall.self, AgentStatus.self],
        defaultSubcommand: Serve.self)
}

enum AgentIO {
    static func print(_ r: LaunchAgent.Report, action: String) {
        let obj: [String: Any] = [
            "action": action, "label": LaunchAgent.label, "binary": r.binary, "plist": r.plist, "log": r.log,
            "loaded": r.loaded, "pid": r.pid as Any, "healthy": r.healthy, "health_wait_ms": r.healthWaitMs,
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        Swift.print(String(decoding: data, as: UTF8.self))
    }
}

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install verdictd as a per-user launchd agent (runs at login, restarts on exit) and verify /health.",
        discussion: "Copies this binary to ~/Library/Application Support/verdict/bin, writes ~/Library/LaunchAgents/\(LaunchAgent.label).plist, bootstraps it. Re-running replaces both. No sudo.")
    @Option(help: "Loopback port the agent serves on.") var port = VerdictServer.defaultPort
    @Option(help: "Binary to install (default: the one running this command).") var binary: String?

    func run() throws {
        let source = binary.map { URL(fileURLWithPath: $0) } ?? Bundle.main.executableURL!.resolvingSymlinksInPath()
        let r = try LaunchAgent.install(source: source, port: port)
        AgentIO.print(r, action: "install")
        if !r.healthy { throw ExitCode(1) }
    }
}

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Unload the launchd agent and remove the plist and binary copy. Token and logs stay.")
    func run() throws {
        AgentIO.print(try LaunchAgent.uninstall(), action: "uninstall")
    }
}

struct AgentStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "agent-status", abstract: "Is the launchd agent loaded, and is /health answering?")
    @Option(help: "Port to probe.") var port = VerdictServer.defaultPort
    func run() throws {
        let r = LaunchAgent.status(port: port)
        AgentIO.print(r, action: "status")
        if !(r.loaded && r.healthy) { throw ExitCode(r.loaded ? 1 : 3) }
    }
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

struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Dataflow mode (SPEC §12): answer an SQLite events table's pending rows into a decisions table.",
        discussion: "Creates the tables if absent. --once drains the backlog and exits; otherwise polls. The join and any fallback live in the consumer's SQL, not here.")
    @Option(help: "SQLite database file (events in, decisions out).") var db: String
    @Option(help: "topology.json: event type -> model + questions.") var topology: String
    @Flag(help: "Drain the current backlog and exit, instead of polling.") var once = false
    @Option(help: "Poll interval in seconds when not --once.") var interval = 1.0
    @Option(help: "Events per batch.") var batch = 50
    @Option(help: "Log level.") var logLevel = "info"

    func run() async throws {
        var logger = Logger(label: "verdictd-watch")
        logger.logLevel = Logger.Level(rawValue: logLevel) ?? .info
        let topo: Topology
        do { topo = try Topology(url: URL(fileURLWithPath: topology)) }
        catch { throw ValidationError("topology: \(error)") }
        let watcher = try Watcher(dbPath: db, topology: topo, registry: Registry(), batch: batch)
        if once {
            let r = try await watcher.drain()
            let obj: [String: Any] = ["processed": r.processed, "skipped": r.skipped, "decisions": r.decisions, "failures": r.failures]
            print(String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            return
        }
        logger.info("watching \(db) every \(interval)s; types=\(Array(topo.types.keys).sorted())")
        try await watcher.run(interval: .milliseconds(Int(interval * 1000)))
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
