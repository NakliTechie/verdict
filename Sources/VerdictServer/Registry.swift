import Foundation
import VerdictCore

/// One instance of each backend for the life of the process. Laya loads once (2.7 s) and serves every caller.
public final class Registry: Sendable {
    public struct Entry: Sendable {
        public let model: String
        public let backend: any DecisionBackend
        public let confidence: String
    }

    public let entries: [String: Entry]
    public let aliases: [String: String]

    public static let defaultAliases = ["fm": "verdict-fm", "foundation-models": "verdict-fm", "laya": "verdict-laya",
                                        "laya-coreml": "verdict-laya", "jev-latest": "verdict-fm"]   // Jev clients send jev-latest

    public init(layaDirectory: URL = LayaCoreMLBackend.defaultDirectory) {
        var entries: [String: Entry] = [:]
        entries["verdict-fm"] = Entry(model: "verdict-fm", backend: FoundationModelsBackend(), confidence: "none | agreement")
        if let laya = try? LayaCoreMLBackend(directory: layaDirectory) {
            entries["verdict-laya"] = Entry(model: "verdict-laya", backend: laya, confidence: "decoded")
        }
        self.entries = entries
        aliases = Self.defaultAliases
    }

    /// Explicit entries (tests, or a future policy file).
    public init(entries: [String: Entry], aliases: [String: String] = Registry.defaultAliases) {
        self.entries = entries
        self.aliases = aliases
    }

    public func canonical(_ model: String?) -> String {
        let m = model ?? Wire.defaultModel
        return aliases[m] ?? m
    }

    public func entry(for model: String?) -> Entry? { entries[canonical(model)] }

    public var models: [String] { entries.keys.sorted() }

    /// Warm every backend that has a load cost. Returns per-model load time.
    public func warm() async -> [String: Duration] {
        var out: [String: Duration] = [:]
        for (name, e) in entries {
            if let laya = e.backend as? LayaCoreMLBackend, let t = try? await laya.warmUp() { out[name] = t }
        }
        return out
    }
}
