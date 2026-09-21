import Foundation
import FoundationModels

/// Apple Foundation Models backend. SPEC §4.1. Constrained decoding gives schema-valid answers and
/// no probabilities, so `Sample.distribution` is always nil here.
public struct FoundationModelsBackend: DecisionBackend {
    public let name = "foundation-models"
    let model: SystemLanguageModel

    public init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    public var supportedLanguageCount: Int { model.supportedLanguages.count }

    public func availability() -> BackendAvailability {
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(reason: "This Mac is not eligible for Apple Intelligence.",
                                    remedy: "Run verdict on an Apple silicon Mac with macOS 26 and Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return .unavailable(reason: "Apple Intelligence is turned off.",
                                    remedy: "System Settings → Apple Intelligence & Siri → turn on Apple Intelligence, then re-run.")
            case .modelNotReady:
                return .unavailable(reason: "The system model is still downloading or preparing.",
                                    remedy: "Wait for the download to finish (System Settings → Apple Intelligence & Siri), then re-run.")
            @unknown default:
                return .unavailable(reason: "The system model is unavailable: \(reason).",
                                    remedy: "Check System Settings → Apple Intelligence & Siri, then re-run.")
            }
        }
    }

    public func sample(state: String, question: Question, sampling: Sampling) async throws -> Sample {
        let compiled = PromptCompiler.compile(state: state, question: question)
        let schema = Self.schema(for: question, description: compiled.answerDescription)
        let session = LanguageModelSession(model: model, instructions: compiled.instructions)
        var options = GenerationOptions()
        switch sampling {
        case .greedy:
            options.sampling = .greedy
        case .random(let seed):
            options.sampling = .random(top: 40, seed: seed)
            options.temperature = 1.0
        }
        do {
            let response = try await session.respond(to: compiled.prompt, schema: schema, options: options)
            return Sample(raw: try Self.raw(from: response.content, question: question), distribution: nil)
        } catch let e as LanguageModelSession.GenerationError {
            throw Self.map(e)
        } catch let e as BackendError {
            throw e
        } catch {
            throw BackendError(code: .backendError, message: String(describing: error))
        }
    }

    /// The same shape the `@Generable` macro expands `@Guide(.anyOf(...))` to in the fm-bench harness:
    /// one object with one guided property named `answer`.
    static func schema(for question: Question, description: String) -> GenerationSchema {
        let property: GenerationSchema.Property
        switch question {
        case .choice(let q):
            property = .init(name: "answer", description: description, type: String.self,
                             guides: [.anyOf(q.options.map(\.key))])
        case .score(let q):
            property = .init(name: "answer", description: description, type: Int.self,
                             guides: [.range(0...(q.levels.count - 1))])
        case .noul:
            property = .init(name: "answer", description: description, type: Bool.self)
        }
        return GenerationSchema(type: GeneratedContent.self, description: "The answer to the question",
                                properties: [property])
    }

    static func raw(from content: GeneratedContent, question: Question) throws -> RawAnswer {
        do {
            switch question {
            case .choice: return .key(try content.value(String.self, forProperty: "answer"))
            case .score: return .level(try content.value(Int.self, forProperty: "answer"))
            case .noul: return .bool(try content.value(Bool.self, forProperty: "answer"))
            }
        } catch {
            throw BackendError(code: .decodingFailure,
                               message: "Could not read `answer` from generated content \(content.jsonString): \(error)")
        }
    }

    static func map(_ e: LanguageModelSession.GenerationError) -> BackendError {
        let detail = e.errorDescription ?? String(describing: e)
        switch e {
        case .refusal: return BackendError(code: .refused, message: "The model refused: \(detail)")
        case .guardrailViolation: return BackendError(code: .guardrailViolation, message: "Guardrail violation: \(detail)")
        case .exceededContextWindowSize: return BackendError(code: .contextExceeded, message: detail)
        case .assetsUnavailable: return BackendError(code: .modelUnavailable, message: detail)
        case .unsupportedLanguageOrLocale: return BackendError(code: .unsupportedLanguage, message: detail)
        case .decodingFailure, .unsupportedGuide: return BackendError(code: .decodingFailure, message: detail)
        case .rateLimited: return BackendError(code: .rateLimited, message: detail)
        case .concurrentRequests: return BackendError(code: .concurrentRequests, message: detail)
        @unknown default: return BackendError(code: .backendError, message: detail)
        }
    }
}
