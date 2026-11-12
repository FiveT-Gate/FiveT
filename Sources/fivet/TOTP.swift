import Foundation
import CryptoKit

/// RFC 6238 time-based one-time passwords (the same algorithm FortiToken,
/// Google Authenticator, etc. use): HMAC-SHA1, 30 second steps, 6 digits.
enum TOTP {
    static let period: TimeInterval = 30

    static func base32Decode(_ input: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var map = [Character: Int]()
        for (i, ch) in alphabet.enumerated() { map[ch] = i }

        let cleaned = input.uppercased().filter { $0 != "=" && $0 != " " && $0 != "-" }
        guard !cleaned.isEmpty else { return nil }

        var bits = 0
        var value = 0
        var out = Data()
        for ch in cleaned {
            guard let v = map[ch] else { return nil }
            value = (value << 5) | v
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xff))
                bits -= 8
                value &= (1 << bits) - 1
            }
        }
        return out
    }

    static func code(secret: String, digits: Int = 6, at date: Date = Date()) -> String? {
        guard let key = base32Decode(secret), !key.isEmpty else { return nil }
        let counter = UInt64(date.timeIntervalSince1970 / period)
        var big = counter.bigEndian
        let message = Data(bytes: &big, count: 8)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key))
        let bytes = Array(mac)
        let offset = Int(bytes[bytes.count - 1] & 0x0f)
        let binary = (UInt32(bytes[offset] & 0x7f) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
        let modulo = UInt32(pow(10.0, Double(digits)))
        return String(format: "%0\(digits)u", binary % modulo)
    }

    static func secondsRemaining(at date: Date = Date()) -> Int {
        let t = date.timeIntervalSince1970
        return Int(period - t.truncatingRemainder(dividingBy: period))
    }
}
