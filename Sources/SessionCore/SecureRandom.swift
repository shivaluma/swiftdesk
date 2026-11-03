import Foundation
import Security

/// Cryptographically random session identifiers (PRD §7: "cryptographically random session tokens").
///
/// Uses `SecRandomCopyBytes` with the default generator rather than `SystemRandomNumberGenerator` so the source of
/// session secrets is the Security framework's CSPRNG by construction, not by implementation detail.
public enum SecureRandom {
    public enum Failure: Error, Equatable, Sendable {
        case generatorFailed(Int32)
    }

    /// `count` random bytes.
    public static func bytes(_ count: Int) throws -> Data {
        precondition(count >= 0)
        var data = Data(count: count)
        guard count > 0 else { return data }
        let status = data.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else { throw Failure.generatorFailed(status) }
        return data
    }

    /// A random, non-zero session id. Zero is avoided so "no session" can never collide with a real one.
    public static func sessionId() throws -> UInt32 {
        while true {
            let raw = try bytes(4)
            let value = raw.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if value != 0 { return value }
        }
    }

    /// A random 16-byte session token (`Accept.sessionTokenSize`).
    public static func sessionToken() throws -> Data {
        try bytes(16)
    }
}
