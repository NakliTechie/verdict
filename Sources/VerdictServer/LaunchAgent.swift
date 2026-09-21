import Foundation

/// Per-user launchd agent for verdictd. SPEC §10 lifecycle. Everything lives under the user's home:
/// the binary copy, the plist, the logs. Nothing needs sudo; nothing binds beyond loopback.
public enum LaunchAgent {
    public static let label = "com.naklitechie.verdictd"
    public static let plistURL = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    public static let binaryURL = home.appendingPathComponent("Library/Application Support/verdict/bin/verdictd")
    public static let logURL = home.appendingPathComponent("Library/Logs/verdict/verdictd.log")
    static let home = FileManager.default.homeDirectoryForCurrentUser

    public struct Error: Swift.Error, CustomStringConvertible {
        public let description: String
    }

    public struct Report: Sendable {
        public var binary: String
        public var plist: String
        public var log: String
        public var loaded: Bool
        public var pid: Int?
        public var healthy: Bool
        public var healthWaitMs: Int
    }

    /// Copy `source` into place, write the plist, (re)bootstrap the agent, wait for /health.
    public static func install(source: URL, port: Int, healthTimeout: Duration = .seconds(45)) throws -> Report {
        let fm = FileManager.default
        try fm.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Unload first so the running copy releases the binary and the port.
        _ = try? launchctl(["bootout", domain, plistURL.path])

        let tmp = binaryURL.deletingLastPathComponent().appendingPathComponent(".verdictd.\(getpid())")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: source, to: tmp)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        _ = try? fm.removeItem(at: binaryURL)
        try fm.moveItem(at: tmp, to: binaryURL)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binaryURL.path, "serve", "--port", String(port)],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "ThrottleInterval": 5,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
            "EnvironmentVariables": ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        let out = try launchctl(["bootstrap", domain, plistURL.path])
        if out.status != 0 {
            throw Error(description: "launchctl bootstrap failed (\(out.status)): \(out.text)\nFix: `launchctl bootout \(domain) \(plistURL.path)` then re-run, or inspect \(logURL.path).")
        }
        let (healthy, waited) = waitForHealth(port: port, timeout: healthTimeout)
        return Report(binary: binaryURL.path, plist: plistURL.path, log: logURL.path,
                      loaded: true, pid: pid(), healthy: healthy, healthWaitMs: waited)
    }

    /// Unload and remove the plist and the binary copy. The token file and logs stay.
    public static func uninstall() throws -> Report {
        let wasLoaded = pid() != nil || (try? launchctl(["print", "\(domain)/\(label)"]))?.status == 0
        let out = try launchctl(["bootout", domain, plistURL.path])
        if out.status != 0 && wasLoaded {
            throw Error(description: "launchctl bootout failed (\(out.status)): \(out.text)")
        }
        try? FileManager.default.removeItem(at: plistURL)
        try? FileManager.default.removeItem(at: binaryURL)
        return Report(binary: binaryURL.path, plist: plistURL.path, log: logURL.path,
                      loaded: false, pid: nil, healthy: false, healthWaitMs: 0)
    }

    public static func status(port: Int) -> Report {
        let loaded = (try? launchctl(["print", "\(domain)/\(label)"]))?.status == 0
        let (healthy, waited) = waitForHealth(port: port, timeout: .seconds(2))
        return Report(binary: binaryURL.path, plist: plistURL.path, log: logURL.path,
                      loaded: loaded, pid: pid(), healthy: healthy, healthWaitMs: waited)
    }

    // MARK: helpers

    static var domain: String { "gui/\(getuid())" }

    static func launchctl(_ args: [String]) throws -> (status: Int32, text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// PID from `launchctl print`, when the agent is running.
    static func pid() -> Int? {
        guard let out = try? launchctl(["print", "\(domain)/\(label)"]), out.status == 0 else { return nil }
        for line in out.text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("pid = "), let v = Int(t.dropFirst(6)) { return v }
        }
        return nil
    }

    static func waitForHealth(port: Int, timeout: Duration) -> (Bool, Int) {
        let clock = ContinuousClock()
        let start = clock.now
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        while clock.now - start < timeout {
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var ok = false
            let task = URLSession.shared.dataTask(with: url) { _, resp, _ in
                ok = (resp as? HTTPURLResponse)?.statusCode == 200
                sem.signal()
            }
            task.resume()
            _ = sem.wait(timeout: .now() + 2)
            if ok { return (true, (clock.now - start).wholeMilliseconds) }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return (false, (clock.now - start).wholeMilliseconds)
    }
}
