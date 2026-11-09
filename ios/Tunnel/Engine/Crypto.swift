import Foundation
import CommonCrypto
import CryptoKit

enum MT {
    static let handshakeLen = 64
    static let skipLen = 8
    static let prekeyLen = 32
    static let keyLen = 32
    static let ivLen = 16
    static let protoTagPos = 56
    static let dcIdxPos = 60

    static let tagAbridged: [UInt8] = [0xef, 0xef, 0xef, 0xef]
    static let tagIntermediate: [UInt8] = [0xee, 0xee, 0xee, 0xee]
    static let tagSecure: [UInt8] = [0xdd, 0xdd, 0xdd, 0xdd]

    static let reservedFirstBytes: Set<UInt8> = [0xef]
    static let reservedStarts: [[UInt8]] = [
        [0x48, 0x45, 0x41, 0x44], [0x50, 0x4F, 0x53, 0x54],
        [0x47, 0x45, 0x54, 0x20], [0xee, 0xee, 0xee, 0xee],
        [0xdd, 0xdd, 0xdd, 0xdd], [0x16, 0x03, 0x01, 0x02],
        [0x4F, 0x50, 0x54, 0x49],
    ]

    static let dcDefaultIPs: [Int: String] = [
        1: "149.154.175.50", 2: "149.154.167.51", 3: "149.154.175.100",
        4: "149.154.167.91", 5: "149.154.171.5", 203: "91.105.192.100",
    ]
    static let dcTestIPs: [Int: String] = [
        1: "149.154.175.10", 2: "149.154.167.40", 3: "149.154.175.117",
    ]

    static let wsPath = "/apiws"
    static let wsPathTest = "/apiws_test"

    static func wsDomains(dc: Int, media: Bool) -> [String] {
        let d = dc == 203 ? 2 : dc
        if !media { return ["kws\(d).web.telegram.org"] }
        return ["kws\(d)-1.web.telegram.org", "kws\(d).web.telegram.org"]
    }
}

func randomBytes(_ n: Int) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: n)
    _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
    return b
}

func sha256(_ data: [UInt8]) -> [UInt8] {
    Array(SHA256.hash(data: data))
}

/// AES-256-CTR keystream, big-endian counter (as Python's modes.CTR).
final class AESCTR {
    private var ref: CCCryptorRef?

    init(key: [UInt8], iv: [UInt8]) {
        var r: CCCryptorRef?
        _ = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { v in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding), v.baseAddress, k.baseAddress, key.count,
                    nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &r)
            }
        }
        ref = r
    }

    deinit { if let ref { CCCryptorRelease(ref) } }

    func update(_ input: [UInt8]) -> [UInt8] {
        if input.isEmpty { return [] }
        var out = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        _ = input.withUnsafeBytes { i in
            out.withUnsafeMutableBytes { o in
                CCCryptorUpdate(ref, i.baseAddress, input.count, o.baseAddress, input.count, &moved)
            }
        }
        return out
    }

    func update(_ input: Data) -> Data {
        if input.isEmpty { return Data() }
        var out = Data(count: input.count)
        var moved = 0
        let n = input.count
        _ = input.withUnsafeBytes { i in
            out.withUnsafeMutableBytes { o in
                CCCryptorUpdate(ref, i.baseAddress, n, o.baseAddress, n, &moved)
            }
        }
        return out
    }
}

struct ClientHandshake {
    let dc: Int
    let isMedia: Bool
    let protoTag: [UInt8]
    let prekeyAndIV: [UInt8] // 48 bytes from the client's init
}

/// Port of _try_handshake: decrypts the client's obfuscated init with the secret.
func tryHandshake(_ hs: [UInt8], secret: [UInt8]) -> ClientHandshake? {
    guard hs.count == MT.handshakeLen else { return nil }
    let prekeyIV = Array(hs[MT.skipLen..<(MT.skipLen + MT.prekeyLen + MT.ivLen)])
    let prekey = Array(prekeyIV[0..<MT.prekeyLen])
    let iv = Array(prekeyIV[MT.prekeyLen...])
    let key = sha256(prekey + secret)
    let dec = AESCTR(key: key, iv: iv).update(hs)
    let tag = Array(dec[MT.protoTagPos..<(MT.protoTagPos + 4)])
    guard tag == MT.tagAbridged || tag == MT.tagIntermediate || tag == MT.tagSecure else { return nil }
    let raw = UInt16(dec[MT.dcIdxPos]) | (UInt16(dec[MT.dcIdxPos + 1]) << 8)
    let dcIdx = Int(Int16(bitPattern: raw))
    return ClientHandshake(dc: abs(dcIdx), isMedia: dcIdx < 0, protoTag: tag, prekeyAndIV: prekeyIV)
}

/// Port of _generate_relay_init: a fresh standard obfuscated2 init towards Telegram.
func generateRelayInit(protoTag: [UInt8], dcIdx: Int) -> [UInt8] {
    var rnd = randomBytes(MT.handshakeLen)
    while MT.reservedFirstBytes.contains(rnd[0])
            || MT.reservedStarts.contains(Array(rnd[0..<4]))
            || rnd[4..<8].allSatisfy({ $0 == 0 }) {
        rnd = randomBytes(MT.handshakeLen)
    }
    let encKey = Array(rnd[MT.skipLen..<(MT.skipLen + MT.prekeyLen)])
    let encIV = Array(rnd[(MT.skipLen + MT.prekeyLen)..<(MT.skipLen + MT.prekeyLen + MT.ivLen)])
    let encrypted = AESCTR(key: encKey, iv: encIV).update(rnd)
    let dc16 = UInt16(bitPattern: Int16(dcIdx))
    let tailPlain = protoTag + [UInt8(dc16 & 0xff), UInt8(dc16 >> 8)] + randomBytes(2)
    var result = rnd
    for i in 0..<8 {
        let keystream = encrypted[56 + i] ^ rnd[56 + i]
        result[MT.protoTagPos + i] = tailPlain[i] ^ keystream
    }
    return result
}

/// clt_dec: client -> plain, clt_enc: plain -> client,
/// tg_enc: plain -> Telegram, tg_dec: Telegram -> plain.
final class CryptoCtx {
    let cltDec: AESCTR
    let cltEnc: AESCTR
    let tgEnc: AESCTR
    let tgDec: AESCTR

    init(clientPrekeyIV p: [UInt8], secret: [UInt8], relayInit r: [UInt8]) {
        let cltDecKey = sha256(Array(p[0..<MT.prekeyLen]) + secret)
        cltDec = AESCTR(key: cltDecKey, iv: Array(p[MT.prekeyLen...]))
        let rev = Array(p.reversed())
        let cltEncKey = sha256(Array(rev[0..<MT.prekeyLen]) + secret)
        cltEnc = AESCTR(key: cltEncKey, iv: Array(rev[MT.prekeyLen...]))
        _ = cltDec.update([UInt8](repeating: 0, count: 64))

        let rk = Array(r[MT.skipLen..<(MT.skipLen + MT.prekeyLen)])
        let riv = Array(r[(MT.skipLen + MT.prekeyLen)..<(MT.skipLen + MT.prekeyLen + MT.ivLen)])
        tgEnc = AESCTR(key: rk, iv: riv)
        let rdec = Array(r[MT.skipLen..<(MT.skipLen + MT.prekeyLen + MT.ivLen)].reversed())
        tgDec = AESCTR(key: Array(rdec[0..<MT.keyLen]), iv: Array(rdec[MT.keyLen...]))
        _ = tgEnc.update([UInt8](repeating: 0, count: 64))
    }
}

/// Port of MsgSplitter: cuts the re-encrypted stream on MTProto transport
/// packet boundaries so each packet goes in its own WebSocket frame.
final class MsgSplitter {
    private let tag: [UInt8]
    private var cipher = [UInt8]()
    private var plain = [UInt8]()
    private var disabled = false

    init(protoTag: [UInt8]) { tag = protoTag }

    func split(cipherChunk: [UInt8], plainChunk: [UInt8]) -> [[UInt8]] {
        if cipherChunk.isEmpty { return [] }
        if disabled { return [cipherChunk] }
        cipher += cipherChunk
        plain += plainChunk
        var parts: [[UInt8]] = []
        var offset = 0
        let total = cipher.count
        while offset < total {
            guard let len = nextPacketLen(offset, total - offset) else { break }
            if len <= 0 {
                parts.append(Array(cipher[offset...]))
                offset = total
                disabled = true
                break
            }
            parts.append(Array(cipher[offset..<(offset + len)]))
            offset += len
        }
        if offset > 0 {
            cipher.removeFirst(offset)
            plain.removeFirst(offset)
        }
        return parts
    }

    func flush() -> [UInt8]? {
        if cipher.isEmpty { return nil }
        defer { cipher.removeAll(); plain.removeAll() }
        return cipher
    }

    private func nextPacketLen(_ off: Int, _ avail: Int) -> Int? {
        if avail <= 0 { return nil }
        if tag == MT.tagAbridged {
            let first = plain[off]
            var payload: Int
            var header: Int
            if first == 0x7f || first == 0xff {
                if avail < 4 { return nil }
                payload = (Int(plain[off + 1]) | Int(plain[off + 2]) << 8 | Int(plain[off + 3]) << 16) * 4
                header = 4
            } else {
                payload = Int(first & 0x7f) * 4
                header = 1
            }
            if payload <= 0 { return 0 }
            let len = header + payload
            return avail < len ? nil : len
        }
        if tag == MT.tagIntermediate || tag == MT.tagSecure {
            if avail < 4 { return nil }
            let v = UInt32(plain[off]) | UInt32(plain[off + 1]) << 8 | UInt32(plain[off + 2]) << 16 | UInt32(plain[off + 3]) << 24
            let payload = Int(v & 0x7fff_ffff)
            if payload <= 0 { return 0 }
            let len = 4 + payload
            return avail < len ? nil : len
        }
        return 0
    }
}
