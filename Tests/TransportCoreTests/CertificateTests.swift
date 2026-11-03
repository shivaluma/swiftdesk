import Foundation
import Security
import Testing
@testable import TransportCore

@Suite("DER encoder")
struct DEREncoderTests {
    @Test func lengthEncodings() {
        #expect(DER.length(0) == [0x00])
        #expect(DER.length(127) == [0x7F])
        #expect(DER.length(128) == [0x81, 0x80])
        #expect(DER.length(255) == [0x81, 0xFF])
        #expect(DER.length(256) == [0x82, 0x01, 0x00])
        #expect(DER.length(70_000) == [0x83, 0x01, 0x11, 0x70])
    }

    @Test func integerEncodings() {
        #expect(DER.integer(0) == [0x02, 0x01, 0x00])
        #expect(DER.integer(2) == [0x02, 0x01, 0x02])
        #expect(DER.integer(127) == [0x02, 0x01, 0x7F])
        #expect(DER.integer(128) == [0x02, 0x02, 0x00, 0x80])     // sign bit needs a leading zero
        #expect(DER.integer(256) == [0x02, 0x02, 0x01, 0x00])
        #expect(DER.unsignedInteger([0x00, 0x00, 0x05]) == [0x02, 0x01, 0x05])   // redundant zeros stripped
        #expect(DER.unsignedInteger([0xFF]) == [0x02, 0x02, 0x00, 0xFF])
    }

    @Test func objectIdentifierEncodings() {
        // Well-known encodings (X.690 / RFC 5480).
        #expect(DER.oid("1.2.840.10045.2.1") == [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
        #expect(DER.oid("1.2.840.10045.3.1.7") == [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        #expect(DER.oid("1.2.840.10045.4.3.2") == [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
        #expect(DER.oid("2.5.4.3") == [0x06, 0x03, 0x55, 0x04, 0x03])
    }

    @Test func timeUsesUTCTimeBefore2050AndGeneralizedTimeAfter() {
        let d2036 = Date(timeIntervalSince1970: 2_082_758_399)   // 2035-12-31T23:59:59Z
        let utc = DER.time(d2036)
        #expect(utc.first == DER.Tag.utcTime.rawValue)
        #expect(String(decoding: utc.dropFirst(2), as: UTF8.self) == "351231235959Z")
        let d2051 = Date(timeIntervalSince1970: 2_556_143_999)   // 2050-12-31T23:59:59Z
        let gen = DER.time(d2051)
        #expect(gen.first == DER.Tag.generalizedTime.rawValue)
        #expect(String(decoding: gen.dropFirst(2), as: UTF8.self) == "20501231235959Z")
    }

    @Test func bitStringAndExplicitTags() {
        #expect(DER.bitString([0x80], unusedBits: 7) == [0x03, 0x02, 0x07, 0x80])
        #expect(DER.explicit(0, DER.integer(2)) == [0xA0, 0x03, 0x02, 0x01, 0x02])
        #expect(DER.sequence([]) == [0x30, 0x00])
        #expect(DER.boolean(true) == [0x01, 0x01, 0xFF])
    }
}

@Suite("Self-signed certificate")
struct SelfSignedCertificateTests {
    /// Ephemeral (non-keychain) P-256 key, so these tests never touch the user's keychain.
    static func ephemeralKey() throws -> SecKey {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrIsPermanent: false,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue()
        }
        return key
    }

    @Test func certificateParsesAndCarriesThePublicKey() throws {
        let key = try Self.ephemeralKey()
        let der = try DeviceIdentity.makeCertificateDER(privateKey: key, commonName: "SwiftDesk Test-Mac")
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(SecCertificateCopyData(certificate) as Data == der)
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == "SwiftDesk Test-Mac")

        let certKey = try #require(SecCertificateCopyKey(certificate))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let a = try #require(SecKeyCopyExternalRepresentation(certKey, nil) as Data?)
        let b = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        #expect(a == b)
        #expect(a.count == 65 && a.first == 0x04)
        #expect(DeviceIdentity.publicKeysMatch(privateKey: key, certificate: certificate))
    }

    /// Minimal DER walker for tests: returns the raw TLVs of the outer certificate SEQUENCE.
    static func topLevelElements(_ der: Data) throws -> [Data] {
        func readTLV(_ bytes: [UInt8], at start: Int) throws -> (tlv: Range<Int>, content: Range<Int>) {
            guard start + 2 <= bytes.count else { throw CocoaError(.coderReadCorrupt) }
            var i = start + 1
            var length = Int(bytes[i]); i += 1
            if length & 0x80 != 0 {
                let n = length & 0x7F
                guard n > 0, n <= 3, i + n <= bytes.count else { throw CocoaError(.coderReadCorrupt) }
                length = bytes[i..<(i + n)].reduce(0) { $0 << 8 | Int($1) }
                i += n
            }
            guard i + length <= bytes.count else { throw CocoaError(.coderReadCorrupt) }
            return (start..<(i + length), i..<(i + length))
        }
        let bytes = Array(der)
        let outer = try readTLV(bytes, at: 0)
        var out: [Data] = []
        var pos = outer.content.lowerBound
        while pos < outer.content.upperBound {
            let e = try readTLV(bytes, at: pos)
            out.append(Data(bytes[e.tlv]))
            pos = e.tlv.upperBound
        }
        return out
    }

    /// Verifies the certificate's ECDSA-SHA256 signature over its TBSCertificate with the embedded public key.
    static func signatureIsValid(_ der: Data) throws -> Bool {
        let parts = try topLevelElements(der)
        guard parts.count == 3, let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let key = SecCertificateCopyKey(certificate) else { return false }
        let bitString = parts[2]
        guard bitString.first == 0x03 else { return false }
        // BIT STRING: tag, length (short or long form), unused-bits octet, then the DER ECDSA-Sig-Value.
        let lengthBytes = bitString[bitString.startIndex + 1] & 0x80 != 0 ? Int(bitString[bitString.startIndex + 1] & 0x7F) + 1 : 1
        let signature = bitString.dropFirst(1 + lengthBytes + 1)
        return SecKeyVerifySignature(key, .ecdsaSignatureMessageX962SHA256, parts[0] as CFData,
                                     Data(signature) as CFData, nil)
    }

    @Test func selfSignatureVerifies() throws {
        let key = try Self.ephemeralKey()
        let der = try DeviceIdentity.makeCertificateDER(privateKey: key, commonName: "SwiftDesk Sig")
        #expect(try Self.signatureIsValid(der))
    }

    @Test func certificateIsAcceptedBySecTrustAsItsOwnAnchor() throws {
        // Checks validity window and extensions are acceptable to Security.framework (anchors are not
        // signature-checked by SecTrust; `selfSignatureVerifies` covers that).
        let key = try Self.ephemeralKey()
        let der = try DeviceIdentity.makeCertificateDER(privateKey: key, commonName: "SwiftDesk Trust")
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let t = try #require(trust)
        #expect(SecTrustSetAnchorCertificates(t, [certificate] as CFArray) == errSecSuccess)
        #expect(SecTrustSetAnchorCertificatesOnly(t, true) == errSecSuccess)
        var error: CFError?
        let ok = SecTrustEvaluateWithError(t, &error)
        #expect(ok, "trust evaluation failed: \(String(describing: error))")
    }

    @Test func tamperedCertificateFailsSignatureCheck() throws {
        let key = try Self.ephemeralKey()
        var der = try DeviceIdentity.makeCertificateDER(privateKey: key, commonName: "SwiftDesk Tamper")
        // Flip one byte inside the subject CN ("SwiftDesk Tamper" -> "SwiftDesk Tampex").
        let range = try #require(der.range(of: Data("Tamper".utf8)))
        der[range.upperBound - 1] = UInt8(ascii: "x")
        #expect(try !Self.signatureIsValid(der))
    }

    @Test func serialsAreRandomAndPositive() throws {
        let key = try Self.ephemeralKey()
        let a = try DeviceIdentity.makeCertificateDER(privateKey: key, commonName: "SwiftDesk A")
        let b = try DeviceIdentity.makeCertificateDER(privateKey: key, commonName: "SwiftDesk A")
        #expect(a != b)   // random serial (and non-deterministic ECDSA signature)
        let ca = try #require(SecCertificateCreateWithData(nil, a as CFData))
        let serial = try #require(SecCertificateCopySerialNumberData(ca, nil) as Data?)
        #expect(serial.count == 16)
        #expect(serial.first! & 0x80 == 0)
    }
}

@Suite("Fingerprint formatting")
struct FingerprintTests {
    @Test func displayIsFirst16BytesAs8Groups() {
        let fp = Data((0..<32).map { UInt8($0 * 7 & 0xFF) })
        let display = DeviceIdentity.display(fp)
        #expect(display == "0007 0E15 1C23 2A31 383F 464D 545B 6269")
        #expect(display.split(separator: " ").count == 8)
        #expect(display.split(separator: " ").allSatisfy { $0.count == 4 })
    }

    @Test func displayIsUppercaseHex() {
        let fp = Data(repeating: 0xAB, count: 32)
        #expect(DeviceIdentity.display(fp) == "ABAB ABAB ABAB ABAB ABAB ABAB ABAB ABAB")
        #expect(DeviceIdentity.displayFull(fp).split(separator: " ").count == 16)
    }

    @Test func displayHandlesShortInput() {
        #expect(DeviceIdentity.display(Data([0x01, 0x02, 0x03])) == "0102 03")
        #expect(DeviceIdentity.display(Data()) == "")
    }

    @Test func fingerprintIsSHA256OfDER() {
        // SHA-256("abc"), FIPS 180-2 test vector.
        let fp = DeviceIdentity.fingerprint(ofCertificate: Data("abc".utf8))
        #expect(fp.count == 32)
        #expect(DeviceIdentity.displayFull(fp) ==
                "BA78 16BF 8F01 CFEA 4141 40DE 5DAE 2223 B003 61A3 9617 7A9C B410 FF61 F200 15AD")
    }
}
