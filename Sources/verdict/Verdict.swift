import ArgumentParser
import Foundation
import VerdictCore

@main
struct VerdictCLI: AsyncParsableCommand {
    /// Line-buffer stdout even when piped, so replay progress streams to a driver reading a log.
    static func main() async {
        setlinebuf(stdout)
        await Self.main(nil)
    }

    static let configuration = CommandConfiguration(
        commandName: "verdict",
        abstract: "Typed decisions (choice / score / noul) over a text state, on-device.",
        discussion: """
            Exit codes: 0 every question answered · 1 at least one failure or gate failed ·
            2 usage or validation · 3 model unavailable (indeterminate, never a fallback).
            """,
        version: "0.1.0",
        subcommands: [Status.self, Decide.self, Replay.self]
    )
}

enum Exit {
    static let ok = ExitCode(0)
    static let failed = ExitCode(1)
    static let usage = ExitCode(2)
    static let unavailable = ExitCode(3)
}

enum IO {
    static func readInput(_ path: String) throws -> Data {
        if path == "-" { return FileHandle.standardInput.readDataToEndOfFile() }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    static func print<T: Encodable>(_ value: T, compact: Bool) {
        let data = try! Wire.encoder(compact: compact).encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func stderr(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    /// Atomic write: temp file in the same directory, then rename.
    static func writeAtomically(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }
}
