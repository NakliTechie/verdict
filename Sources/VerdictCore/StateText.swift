import Foundation

extension Wire {
    /// `state` on the wire is any JSON value (SPEC §3). A string passes through unchanged. Anything else
    /// becomes the exact text of Python `json.dumps(value, ensure_ascii=False, sort_keys=True)`, so a
    /// client that stringifies first and one that sends the object put the same prompt in front of every
    /// backend. JSONSerialization reads the value because JSONDecoder decodes `1.0` and `1` alike.
    enum StateText {
        /// `decodeRequest` hands `Request.init(from:)` the raw body under this key.
        static let bodyKey = CodingUserInfoKey(rawValue: "verdict.requestBody")!

        /// Render the `state` member of a request body whose `state` is not a string.
        static func render(requestBody: Data) throws(Failure) -> String {
            guard let top = (try? JSONSerialization.jsonObject(with: requestBody)) as? NSDictionary,
                  let value = top["state"] else {
                throw Failure(id: nil, code: .validation, message: "`state` did not parse as JSON.")
            }
            if let text = value as? String { return text }
            if (value as? NSArray)?.count == 0 || (value as? NSDictionary)?.count == 0 {
                throw Failure(id: nil, code: .validation, message: "`state` is empty.",
                              remedy: "Send a non-empty string, object or array.")
            }
            var out = ""
            try write(value, into: &out)
            return out
        }

        static func write(_ value: Any, into out: inout String) throws(Failure) {
            switch value {
            case let s as String:
                writeString(s, into: &out)
            case let n as NSNumber:
                out += try number(n)
            case let a as NSArray:
                out += "["
                for (i, item) in a.enumerated() {
                    if i > 0 { out += ", " }
                    try write(item, into: &out)
                }
                out += "]"
            case let d as NSDictionary:
                // Python sorts str keys by code point; Swift's String `<` compares canonical forms.
                let pairs = d.map { (key: $0.key as? String ?? "\($0.key)", value: $0.value) }
                    .sorted { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) }
                out += "{"
                for (i, pair) in pairs.enumerated() {
                    if i > 0 { out += ", " }
                    writeString(pair.key, into: &out)
                    out += ": "
                    try write(pair.value, into: &out)
                }
                out += "}"
            default:
                out += "null"   // NSNull, the only other value JSONSerialization returns
            }
        }

        /// Python's `ensure_ascii=False` escaping: quote, backslash, and C0 controls; everything else raw.
        static func writeString(_ s: String, into out: inout String) {
            out += "\""
            for u in s.unicodeScalars {
                switch u {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case "\u{08}": out += "\\b"
                case "\u{0C}": out += "\\f"
                case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
                default: out.unicodeScalars.append(u)
                }
            }
            out += "\""
        }

        static func number(_ n: NSNumber) throws(Failure) -> String {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            if let d = n as? NSDecimalNumber {
                // JSONSerialization falls back to a decimal past 64 bits or ~18 significant digits. A
                // fraction is a Python float; an integer that large has no exact 64-bit form (llamacpp-jev
                // rejects it too).
                let text = d.stringValue
                guard text.contains("."), let x = Double(text) else {
                    throw Failure(id: nil, code: .validation, message: "`state` holds the number \(text), outside the 64-bit integer range.",
                                  remedy: "Send that number as a string.")
                }
                return pythonFloat(x)
            }
            switch n.objCType.pointee {
            case CChar(UInt8(ascii: "d")), CChar(UInt8(ascii: "f")): return pythonFloat(n.doubleValue)
            case CChar(UInt8(ascii: "Q")): return String(n.uint64Value)
            default: return String(n.int64Value)
            }
        }

        /// Python `repr(float)`. Swift prints the same shortest round-trip digits; only the switch to
        /// exponent form differs (Swift at 2^53, Python past 1e16), so re-lay the digits by Python's rule:
        /// positional iff -4 < decpt <= 16, where value = 0.<digits> × 10^decpt.
        static func pythonFloat(_ x: Double) -> String {
            if x == 0 { return x.sign == .minus ? "-0.0" : "0.0" }
            let sign = x < 0 ? "-" : ""
            let text = x.magnitude.description
            let parts = text.split(separator: "e")
            let exponent = parts.count == 2 ? Int(parts[1])! : 0
            let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            var digits = Substring(mantissa.joined())
            var decpt = mantissa[0].count + exponent
            while digits.first == "0" {
                digits.removeFirst()
                decpt -= 1
            }
            while digits.last == "0" { digits.removeLast() }
            if decpt > -4 && decpt <= 16 {
                if decpt <= 0 { return sign + "0." + String(repeating: "0", count: -decpt) + digits }
                if decpt >= digits.count { return sign + digits + String(repeating: "0", count: decpt - digits.count) + ".0" }
                let point = digits.index(digits.startIndex, offsetBy: decpt)
                return sign + digits[..<point] + "." + digits[point...]
            }
            let e = decpt - 1
            let tail = digits.dropFirst()
            return sign + digits.prefix(1) + (tail.isEmpty ? "" : "." + tail)
                + "e" + (e < 0 ? "-" : "+") + (abs(e) < 10 ? "0" : "") + String(abs(e))
        }
    }
}
