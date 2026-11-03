import Foundation
import Testing
@testable import SessionCore

@Suite("Password attempt limiter")
struct PasswordAttemptLimiterTests {
    private let minute: UInt64 = 60 * 1_000_000_000
    private let fpA = Data(repeating: 0xA1, count: 32)
    private let fpB = Data(repeating: 0xB2, count: 32)

    @Test func fiveFailuresLockTheFingerprintFor15Minutes() {
        var l = PasswordAttemptLimiter()
        let t0: UInt64 = 1_000 * minute
        for i in 0..<4 {
            #expect(l.check(fingerprint: fpA, address: "10.0.0.1", nowNanos: t0 + UInt64(i) * minute) == .allowed)
            l.recordFailure(fingerprint: fpA, address: "10.0.0.1", nowNanos: t0 + UInt64(i) * minute)
        }
        #expect(l.check(fingerprint: fpA, address: "10.0.0.1", nowNanos: t0 + 4 * minute) == .allowed)
        l.recordFailure(fingerprint: fpA, address: "10.0.0.1", nowNanos: t0 + 4 * minute)
        #expect(l.check(fingerprint: fpA, address: "10.0.0.1", nowNanos: t0 + 4 * minute) == .lockedOut)
        // Same fingerprint from another address: still locked (per-fingerprint).
        #expect(l.check(fingerprint: fpA, address: "10.0.0.9", nowNanos: t0 + 10 * minute) == .lockedOut)
        // Another fingerprint from the same address: locked (per-IP).
        #expect(l.check(fingerprint: fpB, address: "10.0.0.1", nowNanos: t0 + 10 * minute) == .lockedOut)
        // Another fingerprint from another address: fine.
        #expect(l.check(fingerprint: fpB, address: "10.0.0.2", nowNanos: t0 + 10 * minute) == .allowed)
        // Lockout lasts 15 min from the fifth failure.
        #expect(l.check(fingerprint: fpA, address: "10.0.0.1", nowNanos: t0 + 19 * minute - 1) == .lockedOut)
        #expect(l.check(fingerprint: fpA, address: "10.0.0.1", nowNanos: t0 + 19 * minute) == .allowed)
        // After the lockout the count starts over.
        l.recordFailure(fingerprint: fpA, address: "10.0.0.1", nowNanos: t0 + 20 * minute)
        #expect(l.check(fingerprint: fpA, address: "10.0.0.1", nowNanos: t0 + 20 * minute) == .allowed)
    }

    @Test func failuresOutsideTheWindowDoNotCount() {
        var l = PasswordAttemptLimiter()
        let t0: UInt64 = 1_000 * minute
        // One failure every 4 minutes: never 5 within 15 minutes.
        for i in 0..<10 {
            l.recordFailure(fingerprint: fpA, address: "10.0.0.1", nowNanos: t0 + UInt64(i) * 4 * minute)
            #expect(l.check(fingerprint: fpA, address: "10.0.0.1", nowNanos: t0 + UInt64(i) * 4 * minute) == .allowed)
        }
    }

    @Test func perAddressLockoutCatchesRotatingCertificates() {
        var l = PasswordAttemptLimiter()
        let t0: UInt64 = 1_000 * minute
        for i in 0..<5 {
            let fp = Data(repeating: UInt8(i), count: 32)   // a fresh identity per attempt
            l.recordFailure(fingerprint: fp, address: "192.168.1.66", nowNanos: t0 + UInt64(i))
        }
        #expect(l.check(fingerprint: Data(repeating: 0x77, count: 32), address: "192.168.1.66", nowNanos: t0 + 10) == .lockedOut)
        #expect(l.check(fingerprint: Data(repeating: 0x77, count: 32), address: "192.168.1.67", nowNanos: t0 + 10) == .allowed)
    }

    @Test func successResetsTheFingerprintButNotTheAddress() {
        var l = PasswordAttemptLimiter()
        let t0: UInt64 = 1_000 * minute
        for i in 0..<4 { l.recordFailure(fingerprint: fpA, address: "10.0.0.1", nowNanos: t0 + UInt64(i)) }
        l.recordSuccess(fingerprint: fpA, nowNanos: t0 + 5)
        // Fingerprint counter cleared; the address still has 4 → the 5th failure locks the address.
        l.recordFailure(fingerprint: fpA, address: "10.0.0.2", nowNanos: t0 + 6)
        #expect(l.check(fingerprint: fpA, address: "10.0.0.2", nowNanos: t0 + 7) == .allowed)
        l.recordFailure(fingerprint: fpB, address: "10.0.0.1", nowNanos: t0 + 8)
        #expect(l.check(fingerprint: fpB, address: "10.0.0.1", nowNanos: t0 + 9) == .lockedOut)
        #expect(l.check(fingerprint: fpA, address: "10.0.0.3", nowNanos: t0 + 9) == .allowed)
    }

    @Test func globalCapDisablesPasswordsUntilItCoolsDown() {
        var l = PasswordAttemptLimiter()
        let t0: UInt64 = 1_000 * minute
        // 30 failures from 30 identities on 30 addresses within 10 minutes (no per-key lockout).
        for i in 0..<30 {
            l.recordFailure(fingerprint: Data(repeating: UInt8(i), count: 32), address: "10.1.0.\(i)",
                            nowNanos: t0 + UInt64(i) * 10_000_000_000)
        }
        let after = t0 + 30 * 10_000_000_000
        #expect(l.recentGlobalFailures(nowNanos: after) == 30)
        #expect(l.check(fingerprint: fpA, address: "10.2.0.1", nowNanos: after) == .passwordDisabled)
        // The first failure ages out 10 minutes after it happened: 29 left → allowed again.
        #expect(l.check(fingerprint: fpA, address: "10.2.0.1", nowNanos: t0 + 10 * minute) == .allowed)
        #expect(l.globalFailures.count <= l.configuration.globalMaxFailures)
    }

    @Test func memoryIsBounded() {
        var config = PasswordAttemptLimiter.Configuration()
        config.maxTrackedKeys = 16
        var l = PasswordAttemptLimiter(configuration: config)
        for i in 0..<500 {
            l.recordFailure(fingerprint: Data([UInt8(i & 0xFF), UInt8(i >> 8)]), address: "10.\(i / 256).\(i % 256).1",
                            nowNanos: UInt64(i) * 1_000)
        }
        #expect(l.entries.count <= 16)
        #expect(l.globalFailures.count <= config.globalMaxFailures)
    }
}
