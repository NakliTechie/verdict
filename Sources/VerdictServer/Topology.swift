import Foundation
import VerdictCore

/// A dataflow topology (SPEC §12.2): event type → the model and the questions to ask. The question
/// shape reuses the wire codec, so the vocabulary is identical to `POST /v1/systemone`.
public struct Topology: Sendable {
    public struct EventType: Sendable {
        public let model: String
        public let questions: [QuestionEntry]
    }
    public let version: Int
    public let types: [String: EventType]

    public struct LoadError: Error, CustomStringConvertible { public let description: String }

    public init(url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(data: data, source: url.path)
    }

    public init(data: Data, source: String = "<data>") throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError(description: "\(source) is not a JSON object.")
        }
        version = (root["version"] as? NSNumber)?.intValue ?? 1
        guard let typesObj = root["types"] as? [String: Any], !typesObj.isEmpty else {
            throw LoadError(description: "\(source) has no non-empty `types` object.")
        }
        var types: [String: EventType] = [:]
        for (typeName, def) in typesObj {
            guard let d = def as? [String: Any] else { throw LoadError(description: "type `\(typeName)` is not an object.") }
            let model = d["model"] as? String ?? "verdict-fm"
            guard let qObj = d["questions"] as? [String: Any], !qObj.isEmpty else {
                throw LoadError(description: "type `\(typeName)` has no non-empty `questions`.")
            }
            var entries: [QuestionEntry] = []
            for (qid, _) in qObj.sorted(by: { $0.key < $1.key }) {
                let qData = try JSONSerialization.data(withJSONObject: qObj[qid]!)
                do {
                    let body = try JSONDecoder().decode(Wire.RequestQuestion.self, from: qData)
                    entries.append(QuestionEntry(id: qid, question: try body.toCore()))
                } catch {
                    throw LoadError(description: "type `\(typeName)` question `\(qid)`: \(error)")
                }
            }
            types[typeName] = EventType(model: model, questions: entries)
        }
        self.types = types
    }
}
