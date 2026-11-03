import Foundation
import Testing
@testable import WireProtocol

/// PASSWORD_CHALLENGE (17) / PASSWORD_RESPONSE (18), DENY(authFailed) and the AUTH capability marker.
@Suite("Password access messages")
struct PasswordMessageTests {
    private let challenge = PasswordChallenge(salt: Data(repeating: 0x11, count: 16), iterations: 0x000F_4240,
                                              nonce: Data(repeating: 0x22, count: 32))

    @Test func typeBytes() {
        #expect(ControlMessageType.passwordChallenge.rawValue == 17)
        #expect(ControlMessageType.passwordResponse.rawValue == 18)
        #expect(DenyReason.authFailed.rawValue == 8)
    }

    @Test func challengeExactBytes() throws {
        let payload = ControlMessage.passwordChallenge(challenge).encodePayload()
        #expect(Array(payload) == [UInt8](repeating: 0x11, count: 16) + [0x00, 0x0F, 0x42, 0x40]
                + [UInt8](repeating: 0x22, count: 32))
        #expect(try ControlMessage.decode(type: 17, payload: payload) == .passwordChallenge(challenge))
        #expect(Array(ControlFraming.frame(.passwordChallenge(challenge)).prefix(5)) == [0, 0, 0, 53, 17])
    }

    @Test func responseExactBytes() throws {
        let proof = Data((0..<32).map { UInt8($0) })
        let payload = ControlMessage.passwordResponse(.proof(proof)).encodePayload()
        #expect(Array(payload) == [1] + Array(proof))
        #expect(try ControlMessage.decode(type: 18, payload: payload) == .passwordResponse(.proof(proof)))

        let none = ControlMessage.passwordResponse(.none).encodePayload()
        #expect(Array(none) == [UInt8](repeating: 0, count: 33))
        #expect(try ControlMessage.decode(type: 18, payload: none) == .passwordResponse(.none))
    }

    @Test func noneNeverCarriesAProof() throws {
        // Constructing "none" with bytes zeroes them, so the encoding stays canonical.
        let response = PasswordResponse(kind: .none, proof: Data(repeating: 0xFF, count: 32))
        #expect(response.proof == Data(count: 32))
        #expect(try ControlMessage.decode(type: 18, payload: ControlMessage.passwordResponse(response).encodePayload())
                == .passwordResponse(.none))
        // On the wire, a "none" with data is malformed.
        var payload = Data(count: 33)
        payload[32] = 1
        #expect(throws: WireError.malformed("password response without proof carries data")) {
            try ControlMessage.decode(type: 18, payload: payload)
        }
    }

    @Test(arguments: [UInt8(2), 3, 0x80, 0xFF])
    func unknownResponseKindRejected(_ kind: UInt8) {
        var payload = Data(count: 33)
        payload[0] = kind
        #expect(throws: WireError.malformed("invalid password response kind \(kind)")) {
            try ControlMessage.decode(type: 18, payload: payload)
        }
    }

    @Test func fixedSizesAreStrict() {
        #expect(throws: WireError.truncated) { try ControlMessage.decode(type: 17, payload: Data(count: 51)) }
        #expect(throws: WireError.malformed("trailing bytes")) { try ControlMessage.decode(type: 17, payload: Data(count: 53)) }
        #expect(throws: WireError.truncated) { try ControlMessage.decode(type: 18, payload: Data([1] + [UInt8](repeating: 0, count: 31))) }
        #expect(throws: WireError.malformed("trailing bytes")) { try ControlMessage.decode(type: 18, payload: Data([1] + [UInt8](repeating: 0, count: 33))) }
        #expect(throws: WireError.truncated) { try ControlMessage.decode(type: 18, payload: Data()) }
    }

    @Test func misSizedFieldsAreNormalizedOnEncode() throws {
        let short = PasswordChallenge(salt: Data([1, 2]), iterations: 5, nonce: Data(repeating: 9, count: 40))
        let payload = ControlMessage.passwordChallenge(short).encodePayload()
        #expect(payload.count == 52)
        guard case .passwordChallenge(let decoded) = try ControlMessage.decode(type: 17, payload: payload) else {
            Issue.record("not a challenge"); return
        }
        #expect(decoded.salt == Data([1, 2] + [UInt8](repeating: 0, count: 14)))
        #expect(decoded.nonce == Data(repeating: 9, count: 32))
        #expect(decoded.salt.startIndex == 0 && decoded.nonce.startIndex == 0)

        let response = ControlMessage.passwordResponse(.proof(Data([7]))).encodePayload()
        #expect(response.count == 33)
    }

    @Test func streamDecoderDeliversPasswordMessages() throws {
        var decoder = ControlStreamDecoder()
        var stream = ControlFraming.frame(.passwordChallenge(challenge))
        stream.append(ControlFraming.frame(.passwordResponse(.none)))
        stream.append(ControlFraming.frame(.deny(Deny(reason: .authFailed, message: "Incorrect password"))))
        var out: [ControlMessage] = []
        for byte in stream { out += try decoder.append(Data([byte])) }
        #expect(out == [.passwordChallenge(challenge), .passwordResponse(.none),
                        .deny(Deny(reason: .authFailed, message: "Incorrect password"))])
    }

    @Test func fuzzedPasswordPayloadsOnlyThrowWireErrors() {
        var rng = SeededRNG(seed: 0x9A55)
        var decodedCount = 0
        for _ in 0..<20_000 {
            let type = rng.chance(0.5) ? UInt8(17) : 18
            var payload: Data
            if rng.chance(0.5) {
                payload = (type == 17 ? ControlMessage.passwordChallenge(challenge) : .passwordResponse(.proof(rng.bytes(32))))
                    .encodePayload()
                for _ in 0..<Int.random(in: 1...3, using: &rng) {
                    payload[Int.random(in: 0..<payload.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
                }
                if rng.chance(0.2) { payload = payload.prefix(Int.random(in: 0...payload.count, using: &rng)) }
            } else {
                payload = rng.bytes(Int.random(in: 0...70, using: &rng))
            }
            do {
                let decoded = try ControlMessage.decode(type: type, payload: payload)
                #expect(decoded.encodePayload() == payload)   // canonical
                decodedCount += 1
            } catch is WireError {
            } catch {
                Issue.record("non-WireError \(error)")
            }
        }
        #expect(decodedCount > 0)
    }

    // MARK: AUTH capability marker

    @Test func capabilityNonceLayout() {
        let random = Data((0..<16).map { UInt8(0xA0 + $0) })
        let nonce = Auth.nonce(capabilities: .passwordAuth, random: random)
        #expect(nonce.count == Auth.nonceSize)
        #expect(Array(nonce.prefix(5)) == [0x53, 0x44, 0x43, 0x31, 0x01])
        #expect(nonce.suffix(11) == random.prefix(11))
        let auth = Auth(viewerFingerprint: Data(count: 32), hostFingerprint: Data(count: 32), nonce: nonce)
        #expect(auth.capabilities == .passwordAuth)
        // Survives the wire.
        guard case .auth(let decoded)? = try? ControlMessage.decode(type: 2, payload: ControlMessage.auth(auth).encodePayload()) else {
            Issue.record("auth did not decode"); return
        }
        #expect(decoded.capabilities.contains(.passwordAuth))
        // Short random input is zero-padded to the fixed size.
        #expect(Auth.nonce(capabilities: [], random: Data()).count == 16)
    }

    @Test func legacyNonceHasNoCapabilities() {
        let legacy = Auth(viewerFingerprint: Data(count: 32), hostFingerprint: Data(count: 32),
                          nonce: Data((0..<16).map { UInt8($0) }))
        #expect(legacy.capabilities == [])
        let almost = Auth(viewerFingerprint: Data(count: 32), hostFingerprint: Data(count: 32),
                          nonce: Data([0x53, 0x44, 0x43, 0x32, 0x01] + [UInt8](repeating: 0, count: 11)))
        #expect(almost.capabilities == [])
        let sliced = Data([0xFF] + [0x53, 0x44, 0x43, 0x31, 0x01] + [UInt8](repeating: 0, count: 11)).dropFirst()
        #expect(Auth(viewerFingerprint: Data(), hostFingerprint: Data(), nonce: sliced).capabilities == .passwordAuth)
    }
}
