import Foundation

/// Pure functions turning samples into the confidence-bearing parts of a Decision. SPEC §5.
public enum Aggregation {
    public struct Result: Sendable, Equatable {
        public let answer: Answer
        public let confidence: Double?
        public let confidenceKind: ConfidenceKind
        public let distribution: [String: Double]?
    }

    /// One greedy sample. `.decoded` only when the backend supplied a distribution.
    public static func greedy(question: Question, label: String, distribution: [String: Double]?) -> Result {
        guard let distribution, !distribution.isEmpty else {
            return Result(answer: answer(question: question, winner: label, shares: nil),
                          confidence: nil, confidenceKind: .none, distribution: nil)
        }
        let shares = normalised(distribution, labels: question.labels)
        return Result(answer: answer(question: question, winner: label, shares: shares),
                      confidence: oneMinusNormalisedEntropy(shares),
                      confidenceKind: .decoded, distribution: shares)
    }

    /// N sampled labels. Winner = most votes; ties go to the earliest label in question order.
    public static func agreement(question: Question, labels votes: [String]) -> Result {
        precondition(!votes.isEmpty, "agreement needs at least one vote")
        let order = question.labels
        var counts: [String: Int] = [:]
        for v in votes { counts[v, default: 0] += 1 }
        let winner = order.max { a, b in
            let ca = counts[a, default: 0], cb = counts[b, default: 0]
            if ca != cb { return ca < cb }
            return order.firstIndex(of: a)! > order.firstIndex(of: b)!   // earlier label wins ties
        }!
        let n = Double(votes.count)
        var shares: [String: Double] = [:]
        for l in order { shares[l] = Double(counts[l, default: 0]) / n }
        return Result(answer: answer(question: question, winner: winner, shares: shares),
                      confidence: Double(counts[winner, default: 0]) / n,
                      confidenceKind: .agreement, distribution: shares)
    }

    static func answer(question: Question, winner: String, shares: [String: Double]?) -> Answer {
        switch question {
        case .choice:
            return .choice(key: winner)
        case .score(let q):
            let level = Int(winner)!
            guard let shares else { return .score(level: level, expected: Double(level)) }
            let expected = q.levels.indices.reduce(0.0) { $0 + Double($1) * (shares[String($1)] ?? 0) }
            return .score(level: level, expected: expected)
        case .noul:
            return .noul(winner == "true")
        }
    }

    /// Caller (the engine) has already rejected non-finite, negative, stray-key and zero-mass inputs.
    static func normalised(_ d: [String: Double], labels: [String]) -> [String: Double] {
        let total = labels.reduce(0.0) { $0 + (d[$1] ?? 0) }
        precondition(total > 0 && total.isFinite, "normalised() needs a validated distribution")
        return Dictionary(uniqueKeysWithValues: labels.map { ($0, (d[$0] ?? 0) / total) })
    }

    /// openjev's confidence: 1 − H(p)/log n, clamped to [0, 1].
    public static func oneMinusNormalisedEntropy(_ p: [String: Double]) -> Double {
        let n = p.count
        guard n > 1 else { return 1 }
        let h = -p.values.reduce(0.0) { $0 + ($1 > 0 ? $1 * log($1) : 0) }
        return min(1, max(0, 1 - h / log(Double(n))))
    }
}
