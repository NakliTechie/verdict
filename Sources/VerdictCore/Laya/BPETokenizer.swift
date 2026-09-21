import Foundation
import Synchronization

/// Byte-level BPE tokenizer reading a Hugging Face `tokenizer.json` (GPT-2 / OLMo / ModernBERT family:
/// NFC normalizer, ByteLevel pre-tokenizer with the GPT-2 regex, BPE merges, added tokens).
/// Verified token-for-token against the Python `tokenizers` library (Tests/…/laya-tokenizer-golden.json).
public final class BPETokenizer: Sendable {
    public struct LoadError: Error, CustomStringConvertible {
        public let description: String
    }

    private struct Pair: Hashable { let a: String; let b: String }

    private let vocab: [String: Int32]
    private let ranks: [Pair: Int]
    private let addedTokens: [String: Int32]
    private let addedTokenPattern: NSRegularExpression?
    private let byteEncoder: [UInt8: Character]
    private let pretokenizer: NSRegularExpression
    private let cache: Mutex<[String: [Int32]]> = Mutex([:])

    public let clsID: Int32
    public let sepID: Int32
    public let padID: Int32
    public let maskID: Int32
    public let maskToken: String

    public init(tokenizerJSON: URL, config: URL) throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: tokenizerJSON)) as? [String: Any]
        guard let json, let model = json["model"] as? [String: Any], model["type"] as? String == "BPE",
              let vocabAny = model["vocab"] as? [String: Any], let mergesAny = model["merges"] as? [Any] else {
            throw LoadError(description: "\(tokenizerJSON.path) is not a BPE tokenizer.json")
        }
        guard (json["pre_tokenizer"] as? [String: Any])?["type"] as? String == "ByteLevel" else {
            throw LoadError(description: "Only the ByteLevel pre-tokenizer is supported")
        }
        var vocab: [String: Int32] = [:]
        vocab.reserveCapacity(vocabAny.count)
        for (k, v) in vocabAny { vocab[k] = Int32((v as? NSNumber)?.intValue ?? -1) }
        var ranks: [Pair: Int] = [:]
        ranks.reserveCapacity(mergesAny.count)
        for (i, m) in mergesAny.enumerated() {
            if let arr = m as? [String], arr.count == 2 {
                ranks[Pair(a: arr[0], b: arr[1])] = i
            } else if let s = m as? String {
                let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2 { ranks[Pair(a: parts[0], b: parts[1])] = i }
            }
        }
        var added: [String: Int32] = [:]
        for a in json["added_tokens"] as? [[String: Any]] ?? [] {
            if let c = a["content"] as? String, let id = (a["id"] as? NSNumber)?.int32Value { added[c] = id }
        }
        self.vocab = vocab
        self.ranks = ranks
        self.addedTokens = added
        if added.isEmpty {
            addedTokenPattern = nil
        } else {
            let alternation = added.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            addedTokenPattern = try NSRegularExpression(pattern: alternation)
        }
        // GPT-2 byte-level pre-tokenization pattern (what tokenizers' ByteLevel(use_regex: true) applies).
        pretokenizer = try NSRegularExpression(pattern: #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#)
        byteEncoder = Self.bytesToUnicode()

        let cfg = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any] ?? [:]
        func special(_ name: String) throws -> (String, Int32) {
            var value = cfg[name]
            if let d = value as? [String: Any] { value = d["content"] }
            guard let s = value as? String, let id = added[s] ?? vocab[s] else {
                throw LoadError(description: "tokenizer_config.json lacks a valid \(name)")
            }
            return (s, id)
        }
        clsID = try special("cls_token").1
        sepID = try special("sep_token").1
        padID = try special("pad_token").1
        (maskToken, maskID) = try special("mask_token")
    }

    /// Token ids for `text` with no special tokens added (the `add_special_tokens=False` path).
    public func encode(_ text: String) -> [Int32] {
        let normalized = text.precomposedStringWithCanonicalMapping   // NFC
        guard let addedTokenPattern else { return encodeSegment(normalized) }
        var ids: [Int32] = []
        let ns = normalized as NSString
        var cursor = 0
        for m in addedTokenPattern.matches(in: normalized, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                ids += encodeSegment(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            }
            ids.append(addedTokens[ns.substring(with: m.range)]!)
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { ids += encodeSegment(ns.substring(from: cursor)) }
        return ids
    }

    private func encodeSegment(_ text: String) -> [Int32] {
        if text.isEmpty { return [] }
        let ns = text as NSString
        var ids: [Int32] = []
        for m in pretokenizer.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range)
            if let hit = cache.withLock({ $0[word] }) {
                ids += hit
                continue
            }
            let encoded = bpe(String(word.utf8.map { byteEncoder[$0]! }))
            cache.withLock { if $0.count < 20_000 { $0[word] = encoded } }
            ids += encoded
        }
        return ids
    }

    /// GPT-2 reference algorithm: repeatedly merge every occurrence of the lowest-ranked adjacent pair.
    private func bpe(_ word: String) -> [Int32] {
        if let id = vocab[word] { return [id] }
        var symbols = word.map { String($0) }
        while symbols.count > 1 {
            var best: (rank: Int, pair: Pair)? = nil
            for i in 0..<(symbols.count - 1) {
                let pair = Pair(a: symbols[i], b: symbols[i + 1])
                if let r = ranks[pair], best == nil || r < best!.rank { best = (r, pair) }
            }
            guard let (_, pair) = best else { break }
            var next: [String] = []
            next.reserveCapacity(symbols.count)
            var i = 0
            while i < symbols.count {
                if i + 1 < symbols.count, symbols[i] == pair.a, symbols[i + 1] == pair.b {
                    next.append(pair.a + pair.b)
                    i += 2
                } else {
                    next.append(symbols[i])
                    i += 1
                }
            }
            symbols = next
        }
        return symbols.map { vocab[$0] ?? vocab["[UNK]"] ?? 0 }
    }

    /// GPT-2's reversible byte → printable-unicode map.
    private static func bytesToUnicode() -> [UInt8: Character] {
        var bs: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0...255 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }
        var map: [UInt8: Character] = [:]
        for (b, c) in zip(bs, cs) { map[UInt8(b)] = Character(UnicodeScalar(c)!) }
        return map
    }
}
