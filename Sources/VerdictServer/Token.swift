import Foundation
import Security

/// The bearer token gate. SPEC §11. One random token per Mac, in a 0600 file the caller reads.
public enum Token {
    public static let defaultFile: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/verdict/token")

    public struct Error: Swift.Error, CustomStringConvertible {
        public let description: String
    }

    /// Reads the token file, creating a fresh 32-byte random token (64 hex chars) if it is absent.
    public static func loadOrCreate(at url: URL = defaultFile) throws -> String {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: url) {
            let t = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValid(t) else { throw Error(description: "\(url.path) does not hold a 64-hex-character token; delete it to regenerate.") }
            return t
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw Error(description: "SecRandomCopyBytes failed: \(status)") }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try Data((token + "\n").utf8).write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }

    public static func isValid(_ t: String) -> Bool {
        t.count == 64 && t.allSatisfy { $0.isHexDigit }
    }

    /// Constant-time comparison so the gate does not leak prefix matches through timing.
    public static func matches(_ presented: String, _ expected: String) -> Bool {
        let a = Array(presented.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
