import Foundation

/// Brute-force protection for password access, as a pure value type (in memory only; resets when SwiftDesk quits).
///
/// - Per Viewer fingerprint **and** per remote IP: `maxFailures` (5) wrong passwords within `failureWindow` (15 min)
///   lock that key out for `lockoutDuration` (15 min). A locked-out connection gets DENY(rateLimited) with no prompt.
///   Both keys are needed: a new self-signed certificate is free, a new IP address is not.
/// - Globally: `globalMaxFailures` (30) within `globalWindow` (10 min) disable password acceptance altogether until
///   older failures age out; Viewers then get the normal operator prompt only.
/// - A successful login clears the fingerprint's failures (not the IP's: other devices may share it).
///
/// Memory is bounded: at most `maxTrackedKeys` keys are remembered (the stalest is forgotten first) and failure
/// lists never exceed `maxFailures` / `globalMaxFailures` entries.
public struct PasswordAttemptLimiter: Sendable, Equatable {
    public struct Configuration: Sendable, Equatable {
        public var maxFailures = 5
        public var failureWindowNanos: UInt64 = 15 * 60 * 1_000_000_000
        public var lockoutNanos: UInt64 = 15 * 60 * 1_000_000_000
        public var globalMaxFailures = 30
        public var globalWindowNanos: UInt64 = 10 * 60 * 1_000_000_000
        public var maxTrackedKeys = 512

        public init() {}
    }

    public enum Decision: Sendable, Equatable {
        /// Challenge with the password.
        case allowed
        /// This fingerprint or IP is locked out: DENY(rateLimited), no prompt.
        case lockedOut
        /// Too many failures overall: skip the password, show the operator prompt.
        case passwordDisabled
    }

    enum Key: Hashable, Sendable {
        case fingerprint(Data)
        case address(String)
    }

    struct Entry: Equatable, Sendable {
        var failures: [UInt64] = []
        var lockedUntil: UInt64?
        var lastSeen: UInt64 = 0
    }

    public let configuration: Configuration
    private(set) var entries: [Key: Entry] = [:]
    private(set) var globalFailures: [UInt64] = []

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Whether a connection from `fingerprint` at `address` may try the password now.
    public func check(fingerprint: Data, address: String, nowNanos: UInt64) -> Decision {
        for key in [Key.fingerprint(fingerprint), .address(address)] {
            if let until = entries[key]?.lockedUntil, nowNanos < until { return .lockedOut }
        }
        let recentGlobal = globalFailures.filter { nowNanos &- $0 < configuration.globalWindowNanos }.count
        return recentGlobal >= configuration.globalMaxFailures ? .passwordDisabled : .allowed
    }

    /// A wrong password from `fingerprint` at `address`.
    public mutating func recordFailure(fingerprint: Data, address: String, nowNanos: UInt64) {
        for key in [Key.fingerprint(fingerprint), .address(address)] {
            var entry = entries[key] ?? Entry()
            if let until = entry.lockedUntil, nowNanos >= until { entry = Entry() }
            entry.failures = entry.failures.filter { nowNanos &- $0 < configuration.failureWindowNanos }
            entry.failures.append(nowNanos)
            if entry.failures.count >= configuration.maxFailures {
                entry.lockedUntil = nowNanos &+ configuration.lockoutNanos
                entry.failures.removeAll()
            }
            entry.lastSeen = nowNanos
            entries[key] = entry
        }
        globalFailures = globalFailures.filter { nowNanos &- $0 < configuration.globalWindowNanos }
        globalFailures.append(nowNanos)
        if globalFailures.count > configuration.globalMaxFailures {
            globalFailures.removeFirst(globalFailures.count - configuration.globalMaxFailures)
        }
        trim(nowNanos: nowNanos)
    }

    /// A correct password: the fingerprint's failure history is cleared.
    public mutating func recordSuccess(fingerprint: Data, nowNanos: UInt64) {
        entries[.fingerprint(fingerprint)] = nil
    }

    /// Failures still counting toward a lockout or the global cap (for the Host UI).
    public func recentGlobalFailures(nowNanos: UInt64) -> Int {
        globalFailures.filter { nowNanos &- $0 < configuration.globalWindowNanos }.count
    }

    private mutating func trim(nowNanos: UInt64) {
        guard entries.count > configuration.maxTrackedKeys else { return }
        // Forget expired entries first, then the least recently seen.
        entries = entries.filter { _, entry in
            if let until = entry.lockedUntil { return nowNanos < until }
            return entry.failures.contains { nowNanos &- $0 < configuration.failureWindowNanos }
        }
        while entries.count > configuration.maxTrackedKeys,
              let stalest = entries.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
            entries[stalest] = nil
        }
    }
}
