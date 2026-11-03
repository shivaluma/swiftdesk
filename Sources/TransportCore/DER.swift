import Foundation

/// Minimal DER (ASN.1 Distinguished Encoding Rules) writer: just enough to build one self-signed X.509 v3
/// certificate. Kept internal and tiny on purpose; the output is validated in tests by round-tripping through
/// `SecCertificateCreateWithData`, which rejects any malformed encoding.
enum DER {
    enum Tag: UInt8 {
        case boolean = 0x01
        case integer = 0x02
        case bitString = 0x03
        case octetString = 0x04
        case null = 0x05
        case objectIdentifier = 0x06
        case utf8String = 0x0C
        case utcTime = 0x17
        case generalizedTime = 0x18
        case sequence = 0x30
        case set = 0x31
    }

    /// Tag-length-value with a definite-length encoding (short form below 128, long form otherwise).
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    static func length(_ n: Int) -> [UInt8] {
        precondition(n >= 0)
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(Tag.sequence.rawValue, items.flatMap { $0 }) }
    static func set(_ items: [[UInt8]]) -> [UInt8] { tlv(Tag.set.rawValue, items.flatMap { $0 }) }
    static func null() -> [UInt8] { [Tag.null.rawValue, 0x00] }
    static func boolean(_ v: Bool) -> [UInt8] { tlv(Tag.boolean.rawValue, [v ? 0xFF : 0x00]) }
    static func octetString(_ bytes: [UInt8]) -> [UInt8] { tlv(Tag.octetString.rawValue, bytes) }
    static func utf8String(_ s: String) -> [UInt8] { tlv(Tag.utf8String.rawValue, Array(s.utf8)) }

    /// BIT STRING with a leading "unused bits" octet.
    static func bitString(_ bytes: [UInt8], unusedBits: UInt8 = 0) -> [UInt8] {
        tlv(Tag.bitString.rawValue, [unusedBits] + bytes)
    }

    /// Context-specific constructed tag `[n]` (EXPLICIT tagging).
    static func explicit(_ n: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0xA0 | n, content) }

    static func integer(_ value: Int) -> [UInt8] {
        precondition(value >= 0)
        var bytes: [UInt8] = []
        var v = value
        repeat {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        } while v > 0
        return unsignedInteger(bytes)
    }

    /// Non-negative big-endian magnitude: strips redundant leading zeros and adds one if the sign bit is set.
    static func unsignedInteger(_ magnitude: [UInt8]) -> [UInt8] {
        var bytes = Array(magnitude.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(Tag.integer.rawValue, bytes)
    }

    /// Dotted OID string, e.g. "1.2.840.10045.2.1". Arcs are base-128 encoded.
    static func oid(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").map { UInt64($0)! }
        precondition(arcs.count >= 2)
        var body: [UInt8] = []
        func base128(_ value: UInt64) {
            var chunk: [UInt8] = [UInt8(value & 0x7F)]
            var v = value >> 7
            while v > 0 {
                chunk.insert(UInt8(v & 0x7F) | 0x80, at: 0)
                v >>= 7
            }
            body += chunk
        }
        base128(arcs[0] * 40 + arcs[1])
        for arc in arcs.dropFirst(2) { base128(arc) }
        return tlv(Tag.objectIdentifier.rawValue, body)
    }

    /// RFC 5280 §4.1.2.5: UTCTime for years 1950–2049, GeneralizedTime from 2050.
    static func time(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year!
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        let rest = two(c.month!) + two(c.day!) + two(c.hour!) + two(c.minute!) + two(c.second!) + "Z"
        if year < 2050 {
            return tlv(Tag.utcTime.rawValue, Array((two(year % 100) + rest).utf8))
        }
        return tlv(Tag.generalizedTime.rawValue, Array((String(year) + rest).utf8))
    }
}

/// Builds the to-be-signed part and final encoding of a self-signed ECDSA P-256 X.509 v3 certificate.
///
/// The certificate is only a carrier for the public key whose SHA-256 fingerprint peers pin; nobody validates
/// it against a CA. It still has to be well formed and carry sane extensions, because Network.framework's TLS
/// stack parses it during the handshake and rejects certificates it cannot use for TLS 1.3 client/server auth.
enum SelfSignedCertificate {
    static let oidEcPublicKey = "1.2.840.10045.2.1"
    static let oidPrime256v1 = "1.2.840.10045.3.1.7"
    static let oidEcdsaWithSHA256 = "1.2.840.10045.4.3.2"
    static let oidCommonName = "2.5.4.3"
    static let oidOrganization = "2.5.4.10"
    static let oidBasicConstraints = "2.5.29.19"
    static let oidKeyUsage = "2.5.29.15"
    static let oidExtKeyUsage = "2.5.29.37"
    static let oidSubjectKeyIdentifier = "2.5.29.14"
    static let oidServerAuth = "1.3.6.1.5.5.7.3.1"
    static let oidClientAuth = "1.3.6.1.5.5.7.3.2"

    struct Template {
        var commonName: String
        var serial: [UInt8]                 // positive, ≤ 20 octets (RFC 5280 §4.1.2.2)
        var notBefore: Date
        var notAfter: Date
        var publicKeyX963: [UInt8]          // 65-byte uncompressed P-256 point (0x04 || X || Y)
        var subjectKeyIdentifier: [UInt8]   // 20 octets
    }

    static func name(commonName: String) -> [UInt8] {
        DER.sequence([
            DER.set([DER.sequence([DER.oid(oidOrganization), DER.utf8String("SwiftDesk")])]),
            DER.set([DER.sequence([DER.oid(oidCommonName), DER.utf8String(commonName)])]),
        ])
    }

    static func signatureAlgorithm() -> [UInt8] {
        // RFC 5758 §3.2: ecdsa-with-SHA256 AlgorithmIdentifier has absent (not NULL) parameters.
        DER.sequence([DER.oid(oidEcdsaWithSHA256)])
    }

    static func tbsCertificate(_ t: Template) -> [UInt8] {
        precondition(t.publicKeyX963.count == 65 && t.publicKeyX963.first == 0x04, "expected uncompressed P-256 point")
        let subject = name(commonName: t.commonName)
        let spki = DER.sequence([
            DER.sequence([DER.oid(oidEcPublicKey), DER.oid(oidPrime256v1)]),
            DER.bitString(t.publicKeyX963),
        ])
        let extensions = DER.sequence([
            // basicConstraints: critical, cA = FALSE (empty SEQUENCE).
            DER.sequence([DER.oid(oidBasicConstraints), DER.boolean(true), DER.octetString(DER.sequence([]))]),
            // keyUsage: critical, digitalSignature only (bit 0 → 0x80 with 7 unused bits).
            DER.sequence([DER.oid(oidKeyUsage), DER.boolean(true), DER.octetString(DER.bitString([0x80], unusedBits: 7))]),
            // extKeyUsage: serverAuth + clientAuth, since every device acts as both TLS server and client.
            DER.sequence([DER.oid(oidExtKeyUsage),
                          DER.octetString(DER.sequence([DER.oid(oidServerAuth), DER.oid(oidClientAuth)]))]),
            DER.sequence([DER.oid(oidSubjectKeyIdentifier), DER.octetString(DER.octetString(t.subjectKeyIdentifier))]),
        ])
        return DER.sequence([
            DER.explicit(0, DER.integer(2)),            // version v3
            DER.unsignedInteger(t.serial),
            signatureAlgorithm(),
            subject,                                    // issuer == subject (self-signed)
            DER.sequence([DER.time(t.notBefore), DER.time(t.notAfter)]),
            subject,
            spki,
            DER.explicit(3, extensions),
        ])
    }

    /// `signature` is the DER `ECDSA-Sig-Value` produced by `SecKeyCreateSignature(.ecdsaSignatureMessageX962SHA256)`.
    static func certificate(tbs: [UInt8], signature: [UInt8]) -> [UInt8] {
        DER.sequence([tbs, signatureAlgorithm(), DER.bitString(signature)])
    }
}
