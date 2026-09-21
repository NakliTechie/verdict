import CoreML
import Foundation
import VerdictCore

/// Model aliases on the wire → backends. SPEC §3: `verdict-fm` (Foundation Models), `verdict-laya` (Laya Core ML).
enum Backends {
    static let aliases = ["verdict-fm", "verdict-laya"]

    static func make(model: String?) throws(Failure) -> any DecisionBackend {
        switch model ?? Wire.defaultModel {
        case "verdict-fm", "fm", "foundation-models":
            return FoundationModelsBackend()
        case "verdict-laya", "laya", "laya-coreml":
            do {
                return try LayaCoreMLBackend()
            } catch let e as BackendError {
                throw Failure(id: nil, code: .modelUnavailable, message: e.message,
                              remedy: LayaCoreMLBackend.downloadRemedy(for: LayaCoreMLBackend.defaultDirectory))
            } catch {
                throw Failure(id: nil, code: .modelUnavailable, message: String(describing: error))
            }
        default:
            throw Failure(id: nil, code: .validation, message: "Unknown model `\(model ?? "")`.",
                          remedy: "Use one of: \(aliases.joined(separator: ", ")).")
        }
    }

    static func canonicalModel(_ model: String?) -> String {
        switch model ?? Wire.defaultModel {
        case "fm", "foundation-models": "verdict-fm"
        case "laya", "laya-coreml": "verdict-laya"
        default: model ?? Wire.defaultModel
        }
    }
}
