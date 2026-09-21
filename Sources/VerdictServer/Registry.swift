import Foundation
import VerdictCore

/// One instance of each backend for the life of the process. Laya loads once (2.7 s) and serves every caller.
public final class Registry: Sendable {
    public struct Entry: Sendable {
        public let model: String
        public let backend: any DecisionBackend
        public let confidence: String
        public init(model: String, backend: any DecisionBackend, confidence: String) {
            self.model = model
            self.backend = backend
            self.confidence = confidence
        }
        init(model: String, confidence: String, backend: any DecisionBackend) {
            self.init(model: model, backend: backend, confidence: confidence)
        }
    }

    public let entries: [String: Entry]
    public let aliases: [String: String]

    public static let defaultAliases = ["fm": "verdict-fm", "foundation-models": "verdict-fm", "laya": "verdict-laya",
                                        "laya-coreml": "verdict-laya", "jev-latest": "verdict-fm"]   // Jev clients send jev-latest

    public init(layaDirectory: URL = LayaCoreMLBackend.defaultDirectory) {
        var entries: [String: Entry] = [:]
        entries["verdict-fm"] = Entry(model: "verdict-fm", backend: FoundationModelsBackend(), confidence: "none | agreement")
        do {
            entries["verdict-laya"] = Entry(model: "verdict-laya", backend: try LayaCoreMLBackend(directory: layaDirectory), confidence: "decoded")
        } catch {
            // Keep the model name served so a request gets 503 model_unavailable with the install remedy, not 422 unknown model.
            let reason = (error as? BackendError)?.message ?? String(describing: error)
            entries["verdict-laya"] = Entry(model: "verdict-laya", confidence: "decoded",
                                            backend: UnavailableBackend(name: "laya-coreml", reason: reason,
                                                                        remedy: LayaCoreMLBackend.downloadRemedy(for: layaDirectory)))
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

/// A backend that is configured but cannot be constructed (checkpoint missing or corrupt). Every call
/// reports the same reason and remedy, so the wire shows 503 `model_unavailable`, never 422.
public struct UnavailableBackend: DecisionBackend {
    public let name: String
    public let reason: String
    public let remedy: String
    public init(name: String, reason: String, remedy: String) {
        self.name = name
        self.reason = reason
        self.remedy = remedy
    }
    public func availability() -> BackendAvailability { .unavailable(reason: reason, remedy: remedy) }
    public func sample(state: String, question: Question, sampling: Sampling) async throws -> Sample {
        throw BackendError(code: .modelUnavailable, message: reason)
    }
}
