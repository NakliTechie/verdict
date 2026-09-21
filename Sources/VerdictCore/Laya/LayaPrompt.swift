/// Laya's input format, ported from laya-coreml `common.py` (Apache-2.0, Convai Innovations / mizorewww):
/// `[CLS] <type> question: <instructions> [SEP] [MASK] opt0 [MASK] opt1 … [SEP] state [SEP]`.
/// The model reads one logit per `[MASK]` marker position.
public enum LayaPrompt {
    public struct Sequence: Sendable, Equatable {
        public let ids: [Int32]
        public let markers: [Int32]
        public let qtype: Int32          // 0 choice · 1 score · 2 noul
    }

    public static func qtype(_ q: Question) -> Int32 {
        switch q {
        case .choice: 0
        case .score: 1
        case .noul: 2
        }
    }

    /// Distribution labels in marker order. Noul is [false, true] here (the engine's own order is [true, false]).
    public static func labels(_ q: Question) -> [String] {
        if case .noul = q { return ["false", "true"] }
        return q.labels
    }

    /// Option texts in marker order. Noul is always [false, true].
    public static func renderOptions(_ q: Question) -> [String] {
        switch q {
        case .choice(let c):
            return c.options.map { o in
                if let d = o.description, !d.isEmpty { "\(o.key): \(d)" } else { o.key }
            }
        case .score(let s):
            return s.levels.enumerated().map { "level \($0.offset): \($0.element)" }
        case .noul(let n):
            let f = (n.no?.isEmpty ?? true) ? "no, the statement does not hold" : n.no!
            let t = (n.yes?.isEmpty ?? true) ? "yes, the statement holds" : n.yes!
            return ["false: \(f)", "true: \(t)"]
        }
    }

    static func stripMask(_ s: String, _ tok: BPETokenizer) -> String {
        s.replacingOccurrences(of: tok.maskToken, with: " ")
    }

    /// Question-only prefix, before state tokens (`build_prefix`).
    static func prefix(_ q: Question, tok: BPETokenizer, headMaxLen: Int) -> (ids: [Int32], markers: [Int32]) {
        let opts = renderOptions(q)
        var headIDs = tok.encode("\(q.typeName) question: \(stripMask(q.instructions, tok))")
        var optIDs: [[Int32]] = opts.map { [tok.maskID] + Array(tok.encode(" " + stripMask($0, tok)).prefix(48)) }
        var optBudget = headMaxLen - optIDs.reduce(0) { $0 + $1.count }
        if optBudget < 16 {
            let per = max(4, (headMaxLen - 16) / max(1, optIDs.count))
            optIDs = optIDs.map { Array($0.prefix(per)) }
            optBudget = headMaxLen - optIDs.reduce(0) { $0 + $1.count }
        }
        headIDs = Array(headIDs.prefix(max(8, optBudget)))
        var ids: [Int32] = [tok.clsID] + headIDs + [tok.sepID]
        var markers: [Int32] = []
        for o in optIDs {
            markers.append(Int32(ids.count))
            ids += o
        }
        ids.append(tok.sepID)
        return (ids, markers)
    }

    /// Full sequence (`build_sequence`), state truncated on the right to fit `maxLen`.
    public static func sequence(state: String, question: Question, tok: BPETokenizer,
                                maxLen: Int, headMaxLen: Int) -> Sequence {
        let (prefixIDs, markers) = prefix(question, tok: tok, headMaxLen: headMaxLen)
        let room = max(0, maxLen - prefixIDs.count - 1)
        let stateIDs = Array(tok.encode(stripMask(state, tok)).prefix(room))
        let ids = Array((prefixIDs + stateIDs + [tok.sepID]).prefix(maxLen))
        return Sequence(ids: ids, markers: markers.filter { Int($0) < maxLen }, qtype: qtype(question))
    }

    /// Calibration bucket name, as in `temp_bucket`.
    public static func temperatureBucket(qtype: Int32, options k: Int) -> String {
        let size = k <= 2 ? "2" : k <= 5 ? "3-5" : k <= 10 ? "6-10" : "11+"
        let name = ["choice", "score", "noul"][Int(qtype)]
        return "\(name):\(size)"
    }
}
