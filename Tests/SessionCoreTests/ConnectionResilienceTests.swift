import Foundation
import Synchronization
import Testing
import TransportCore
import WireProtocol
@testable import SessionCore

/// Pure dropout policies: silence detection, the Viewer's back-off schedule, the Host's reconnect grace and the
/// handshake's resume gate.
@Suite("Connection resilience")
struct ConnectionResilienceTests {
    let ms: UInt64 = 1_000_000
    let viewerFP = Data(repeating: 0xBB, count: 32)

    // MARK: LinkSilenceDetector

    @Test func silenceIsReportedOncePerEpisode() {
        var d = LinkSilenceDetector(thresholdNanos: 1_000 * ms)
        #expect(d.update(lastHeardNanos: 0, nowNanos: 500 * ms) == nil)
        #expect(d.update(lastHeardNanos: 0, nowNanos: 999 * ms) == nil)
        #expect(d.update(lastHeardNanos: 0, nowNanos: 1_000 * ms) == .silent)
        #expect(d.isSilent)
        #expect(d.update(lastHeardNanos: 0, nowNanos: 5_000 * ms) == nil)       // still silent: no repeat
        #expect(d.update(lastHeardNanos: 5_100 * ms, nowNanos: 5_200 * ms) == .resumed)
        #expect(!d.isSilent)
        #expect(d.update(lastHeardNanos: 5_100 * ms, nowNanos: 5_300 * ms) == nil)
        #expect(d.update(lastHeardNanos: 5_100 * ms, nowNanos: 6_100 * ms) == .silent)
    }

    @Test func clockSkewNeverReadsAsSilence() {
        var d = LinkSilenceDetector(thresholdNanos: 1_000 * ms)
        // A receive stamped after the timer read its clock (another thread) is a zero gap, not an underflow.
        #expect(d.update(lastHeardNanos: 2_000 * ms, nowNanos: 1_999 * ms) == nil)
    }

    // MARK: ReconnectBackoff

    @Test func backoffScheduleDoublesToTheCapWithinTheBudget() {
        let schedule = ReconnectBackoff.schedule()
        #expect(schedule.prefix(6) == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(8)])
        var total: Duration = .zero
        for delay in schedule { total += delay }
        #expect(total == .seconds(60), "attempts start at most 60 s after the drop")
        #expect(schedule.last == .milliseconds(4_500), "the last wait is shortened to the budget")
        #expect(schedule.count == 11)
    }

    @Test func backoffGivesUpAfterTheBudget() {
        var b = ReconnectBackoff()
        #expect(b.nextDelay(elapsed: .zero) == .milliseconds(500))
        // Attempts themselves take time (a handshake timing out): the schedule follows real elapsed time.
        #expect(b.nextDelay(elapsed: .seconds(5)) == .seconds(1))
        #expect(b.nextDelay(elapsed: .seconds(59)) == .seconds(1))     // only 1 s of budget left
        #expect(b.nextDelay(elapsed: .seconds(60)) == nil)
        #expect(b.nextDelay(elapsed: .seconds(90)) == nil)
        #expect(b.attempts == 3)
    }

    @Test func backoffIsConfigurable() {
        var config = ReconnectBackoff.Configuration()
        config.initialDelay = .milliseconds(100)
        config.maxDelay = .milliseconds(300)
        config.budget = .seconds(1)
        #expect(ReconnectBackoff.schedule(config) == [.milliseconds(100), .milliseconds(200), .milliseconds(300),
                                                      .milliseconds(300), .milliseconds(100)])
    }

    // MARK: ReconnectPolicy

    @Test func onlyFailuresAndBusyAreRetried() {
        #expect(ReconnectPolicy.shouldRetry(after: .failed("The network connection was lost")))
        #expect(ReconnectPolicy.shouldRetry(after: .closed))
        #expect(!ReconnectPolicy.shouldRetry(after: .failed(PeerConnection.pinMismatchMessage)))
        #expect(!ReconnectPolicy.shouldRetry(after: .ready))
        #expect(ReconnectPolicy.shouldRetry(after: DenyReason.busy))
        for reason in DenyReason.allCases where reason != .busy {
            #expect(!ReconnectPolicy.shouldRetry(after: reason), "\(reason)")
        }
    }

    // MARK: ReconnectGrace

    private func entry(viaPassword: Bool = false, at nanos: UInt64 = 1_000 * 1_000_000) -> ReconnectGrace.Entry {
        ReconnectGrace.Entry(fingerprint: viewerFP, peerName: "Viewer Mac", viaPassword: viaPassword,
                             sessionStartedAt: Date(timeIntervalSince1970: 1_000), droppedAtNanos: nanos)
    }

    @Test func graceAllowsTheSameIdentityWithinTheWindow() {
        var g = ReconnectGrace(window: .seconds(120))
        g.sessionDropped(entry())
        let t0 = 1_000 * ms
        #expect(true == g.allowsResume(fingerprint: viewerFP, capabilities: .sessionResume, enabled: true,
                               passwordAccessEnabled: false, nowNanos: t0 + 1_000 * ms))
        #expect(true == g.allowsResume(fingerprint: viewerFP, capabilities: [.passwordAuth, .sessionResume], enabled: true,
                               passwordAccessEnabled: false, nowNanos: t0 + 120_000 * ms))
        // Past the window: forgotten.
        #expect(false == g.allowsResume(fingerprint: viewerFP, capabilities: .sessionResume, enabled: true,
                                passwordAccessEnabled: false, nowNanos: t0 + 120_001 * ms))
        #expect(g.entry == nil)
    }

    @Test func graceRefusesAnythingElse() {
        var g = ReconnectGrace()
        g.sessionDropped(entry())
        let now = 2_000 * ms
        #expect(false == g.allowsResume(fingerprint: Data(repeating: 0xCC, count: 32), capabilities: .sessionResume,
                                enabled: true, passwordAccessEnabled: false, nowNanos: now), "another identity")
        #expect(false == g.allowsResume(fingerprint: viewerFP, capabilities: .passwordAuth, enabled: true,
                                passwordAccessEnabled: false, nowNanos: now), "Viewer without sessionResume")
        #expect(false == g.allowsResume(fingerprint: viewerFP, capabilities: .sessionResume, enabled: false,
                                passwordAccessEnabled: false, nowNanos: now), "Host setting off")
        #expect(false == g.allowsResume(fingerprint: Data(), capabilities: .sessionResume, enabled: true,
                                passwordAccessEnabled: false, nowNanos: now), "no TLS identity")
        #expect(true == g.allowsResume(fingerprint: viewerFP, capabilities: .sessionResume, enabled: true,
                               passwordAccessEnabled: false, nowNanos: now))
    }

    @Test func revokeAndConsumeEndTheGrace() {
        var g = ReconnectGrace()
        g.sessionDropped(entry())
        g.revoke()   // Stop Sharing / Deny / Stop Listening / setting off
        #expect(false == g.allowsResume(fingerprint: viewerFP, capabilities: .sessionResume, enabled: true,
                                passwordAccessEnabled: false, nowNanos: 1_500 * ms))
        g.sessionDropped(entry())
        #expect(g.consume() == entry())
        #expect(g.consume() == nil, "single use")
        #expect(false == g.allowsResume(fingerprint: viewerFP, capabilities: .sessionResume, enabled: true,
                                passwordAccessEnabled: false, nowNanos: 1_500 * ms))
    }

    @Test func passwordSessionNeedsPasswordAccessStillOn() {
        var g = ReconnectGrace()
        g.sessionDropped(entry(viaPassword: true))
        #expect(false == g.allowsResume(fingerprint: viewerFP, capabilities: .sessionResume, enabled: true,
                                passwordAccessEnabled: false, nowNanos: 2_000 * ms))
        #expect(true == g.allowsResume(fingerprint: viewerFP, capabilities: .sessionResume, enabled: true,
                               passwordAccessEnabled: true, nowNanos: 2_000 * ms))
    }

    @Test func zeroWindowNeverGrants() {
        var g = ReconnectGrace(window: .zero)
        g.sessionDropped(entry())
        #expect(g.entry == nil)
    }

    // MARK: HostHandshake resume gate

    private let hostFP = Data(repeating: 0xAA, count: 32)
    private let hello = Hello(deviceName: "Viewer Mac", appVersion: "1.0")

    private func auth(_ capabilities: PeerCapabilities) -> ControlMessage {
        .auth(Auth(viewerFingerprint: viewerFP, hostFingerprint: hostFP,
                   nonce: Auth.nonce(capabilities: capabilities, random: Data(count: 11))))
    }

    @Test func resumeSkipsThePromptOnlyForACapableViewer() {
        var h = HostHandshake(hostFingerprint: hostFP, peerFingerprint: viewerFP)
        _ = h.receive(.hello(hello), screenRecordingGranted: true)
        #expect(h.receive(auth([.passwordAuth, .sessionResume]), screenRecordingGranted: true, resume: true)
                == .resumeAccepted(hello))
        #expect(h.phase == .accepted(hello))

        var old = HostHandshake(hostFingerprint: hostFP, peerFingerprint: viewerFP)
        _ = old.receive(.hello(hello), screenRecordingGranted: true)
        #expect(old.receive(auth(.passwordAuth), screenRecordingGranted: true, resume: true) == .requestApproval(hello))
    }

    @Test func resumeWinsOverThePasswordChallengeButNotOverChecks() {
        let challenge = PasswordChallenge(salt: Data(count: 16), iterations: 1_000_000, nonce: Data(count: 32))
        var h = HostHandshake(hostFingerprint: hostFP, peerFingerprint: viewerFP)
        _ = h.receive(.hello(hello), screenRecordingGranted: true)
        #expect(h.receive(auth([.passwordAuth, .sessionResume]), screenRecordingGranted: true,
                          password: .available(challenge), resume: true) == .resumeAccepted(hello))

        var noScreen = HostHandshake(hostFingerprint: hostFP, peerFingerprint: viewerFP)
        _ = noScreen.receive(.hello(hello), screenRecordingGranted: true)
        guard case .deny(.permissionsMissing, _)? = noScreen.receive(auth(.sessionResume), screenRecordingGranted: false,
                                                                      resume: true) else {
            Issue.record("Screen Recording is still required"); return
        }

        var impostor = HostHandshake(hostFingerprint: hostFP, peerFingerprint: Data(repeating: 0xCC, count: 32))
        _ = impostor.receive(.hello(hello), screenRecordingGranted: true)
        guard case .deny(.identityMismatch, _)? = impostor.receive(auth(.sessionResume), screenRecordingGranted: true,
                                                                    resume: true) else {
            Issue.record("channel binding is still checked first"); return
        }

        var noGrace = HostHandshake(hostFingerprint: hostFP, peerFingerprint: viewerFP)
        _ = noGrace.receive(.hello(hello), screenRecordingGranted: true)
        #expect(noGrace.receive(auth(.sessionResume), screenRecordingGranted: true) == .requestApproval(hello))
    }

    // MARK: Viewer stall detection

    /// The Viewer pipeline reports a stall after 1 s with nothing from the Host and clears it on the next receive.
    @Test func viewerPipelineReportsStallAndRecovery() async {
        let transport = FakeTransport()
        let activity = LinkActivity()
        let pipeline = ViewerMediaPipeline(sessionId: 9, transport: transport, sinkSlot: FrameSinkSlot(),
                                           activity: activity)
        let changes = StallRecorder()
        pipeline.onLinkStall = { changes.append($0) }
        pipeline.start()
        defer { pipeline.stop() }
        // Healthy: the Host is heard every 100 ms for half a second.
        for _ in 0..<5 {
            activity.noteReceived()
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(changes.values.isEmpty)
        #expect(await eventuallyDetached(timeout: 3) { changes.values == [true] })
        activity.noteReceived()
        #expect(await eventuallyDetached(timeout: 1) { changes.values == [true, false] })
        // While stalled, keyframe re-requests back off instead of piling up behind the dead link.
        let requests = transport.controlMessages.filter { if case .requestKeyframe = $0 { true } else { false } }
        #expect(requests.count <= 3, "\(requests.count) keyframe requests in ~1.5 s without traffic")
    }
}

private final class StallRecorder: Sendable {
    private let state = Mutex<[Bool]>([])
    func append(_ value: Bool) { state.withLock { $0.append(value) } }
    var values: [Bool] { state.withLock { $0 } }
}
