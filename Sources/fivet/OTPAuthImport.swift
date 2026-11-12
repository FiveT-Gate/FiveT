import Foundation
import AppKit
import Vision
import CoreImage

/// Reads one-time-code secrets from what authenticator setups hand out: an `otpauth://totp/…` link
/// (the text inside a setup QR code), a Google Authenticator export (`otpauth-migration://offline?data=…`,
/// the QR code "Transfer accounts" shows), or a picture of either QR code.
///
/// FiveT makes 6-digit, 30-second, SHA-1 codes (TOTP.swift), the kind FortiGate and most VPN gateways
/// use. A secret meant for other settings would give codes the gateway rejects, so it is refused with
/// a reason instead of imported.
enum OTPAuthImport {
    struct Account: Equatable {
        var secret: String   // Base32, upper case, no spaces or padding
        var issuer: String
        var name: String
        /// For a Google Authenticator export spread over several QR codes: "QR code 1 of 3".
        var exportPart: String? = nil

        var label: String {
            if issuer.isEmpty { return name.isEmpty ? "unnamed account" : name }
            // Google Authenticator exports often repeat the issuer inside the name ("Example:alice").
            let bare = name.hasPrefix(issuer + ":") ? String(name.dropFirst(issuer.count + 1)).trimmed : name
            return bare.isEmpty ? issuer : "\(issuer): \(bare)"
        }
    }

    struct Failure: Error, Equatable { let message: String }

    /// True when `text` looks like something `accounts(in:)` reads, so a paste into the secret field
    /// can be taken apart instead of stored as the secret.
    static func looksLikeLink(_ text: String) -> Bool {
        text.trimmed.lowercased().hasPrefix("otpauth")
    }

    /// Some QR generators leave spaces in the label ("otpauth://totp/ACME Co:bob?…"). macOS 14
    /// encodes them itself; macOS 13 cannot read such a link unless they are encoded first.
    private static func components(_ text: String) -> URLComponents? {
        URLComponents(string: text) ?? URLComponents(string: text.replacingOccurrences(of: " ", with: "%20"))
    }

    /// What a QR code that holds no secret holds, in the error ("a web link (https://)").
    private static func notASecret(_ text: String) -> Failure {
        let t = text.trimmed
        var what = "text"
        if let scheme = components(t)?.scheme?.lowercased(), !scheme.isEmpty, scheme.count <= 20,
           scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "+" || $0 == "." }) {
            what = ["http", "https"].contains(scheme) ? "a web link (\(scheme)://)" : "a \(scheme): link"
        }
        return Failure(message: "This QR code holds \(what), not a one-time-code secret (that starts with otpauth://). A FortiToken Mobile activation code cannot be used here: ask your IT team for the TOTP secret or its QR code.")
    }

    /// Every usable account in `text`. Throws when there is none, saying why.
    static func accounts(in text: String) throws -> [Account] {
        let t = text.trimmed
        guard t.utf8.count <= 16_384 else { throw Failure(message: "This is too long to be a one-time-code setup code.") }
        guard let url = components(t), let scheme = url.scheme?.lowercased() else { throw notASecret(t) }
        switch scheme {
        case "otpauth": return [try account(fromOTPAuth: url)]
        case "otpauth-migration": return try accounts(fromMigration: url)
        default: throw notASecret(t)
        }
    }

    // MARK: otpauth://totp/Issuer:name?secret=…&issuer=…&algorithm=SHA1&digits=6&period=30

    private static func account(fromOTPAuth url: URLComponents) throws -> Account {
        let kind = (url.host ?? "").lowercased()
        if kind == "hotp" { throw hotp }
        guard kind == "totp" else { throw notASecret("otpauth://\(kind)") }
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] { query[item.name.lowercased()] = item.value ?? "" }
        try checkSupported(algorithm: query["algorithm"], digits: query["digits"].map { Int($0) ?? -1 },
                           period: query["period"].map { Int($0) ?? -1 })
        guard let raw = query["secret"], let secret = normalized(raw) else {
            throw Failure(message: "The link has no valid secret in it (secret= must be Base32).")
        }
        // The label is "Issuer:name" or just "name"; the issuer parameter, when present, wins.
        let label = String(url.path.drop { $0 == "/" })
        var issuer = "", name = label
        if let colon = label.firstIndex(of: ":") {
            issuer = String(label[..<colon]).trimmed
            name = String(label[label.index(after: colon)...]).trimmed
        }
        if let i = query["issuer"], !i.trimmed.isEmpty { issuer = i.trimmed }
        return Account(secret: secret, issuer: issuer, name: name)
    }

    private static let hotp = Failure(message: "This is a counter-based (HOTP) code. FiveT makes time-based (TOTP) codes only, the kind VPN gateways use.")

    /// Refuses settings FiveT's TOTP cannot produce. nil means "not given" (the defaults apply).
    private static func checkSupported(algorithm: String?, digits: Int?, period: Int?) throws {
        var odd: [String] = []
        if let a = algorithm, !a.isEmpty, a.uppercased() != "SHA1" { odd.append(a.uppercased()) }
        if let d = digits, d != 6 { odd.append(d > 0 ? "\(d) digits" : "an unknown number of digits") }
        if let p = period, p != 30 { odd.append(p > 0 ? "\(p)-second steps" : "an unknown time step") }
        guard odd.isEmpty else {
            throw Failure(message: "This code uses \(odd.joined(separator: ", ")). FiveT makes 6-digit, 30-second SHA-1 codes, the standard for FortiToken and most VPN gateways, so it cannot import this one.")
        }
    }

    /// Upper case, without spaces, dashes or padding; nil unless it is valid, non-empty Base32.
    static func normalized(_ secret: String) -> String? {
        let s = secret.uppercased().filter { $0 != " " && $0 != "-" && $0 != "=" }
        guard !s.isEmpty, let key = TOTP.base32Decode(s), !key.isEmpty else { return nil }
        return s
    }

    // MARK: Google Authenticator export

    /// `otpauth-migration://offline?data=<base64 MigrationPayload>`: a protocol buffer holding one
    /// OtpParameters message (field 1) per account: 1 secret (bytes), 2 name, 3 issuer, 4 algorithm
    /// (1 = SHA-1), 5 digits (1 = six, 2 = eight), 6 type (1 = HOTP, 2 = TOTP). No period: always 30 s.
    private static func accounts(fromMigration url: URLComponents) throws -> [Account] {
        guard (url.host ?? "").lowercased() == "offline",
              let raw = url.queryItems?.first(where: { $0.name == "data" })?.value,
              let data = base64(raw) else {
            throw Failure(message: "This Google Authenticator export could not be read.")
        }
        var out: [Account] = []
        var skipped: [String] = []
        let fields = try Protobuf.fields(data)
        // batch_size (3) and batch_index (4): an export too big for one QR code comes in several.
        var size = 0, index = 0
        for f in fields {
            if case .varint(let v) = f.value {
                if f.number == 3 { size = Int(truncatingIfNeeded: v) } else if f.number == 4 { index = Int(truncatingIfNeeded: v) }
            }
        }
        // Both numbers come from the export: a crafted one must not make FiveT count past Int.max.
        let part = size > 1 ? ((0..<size).contains(index) ? "QR code \(index &+ 1) of \(size)" : "part of a \(size)-code export") : nil
        for field in fields where field.number == 1 {
            guard case .bytes(let message) = field.value else { continue }
            var secret = Data(), name = "", issuer = ""
            var algorithm = 0, digits = 0, type = 0
            for f in try Protobuf.fields(message) {
                switch (f.number, f.value) {
                case (1, .bytes(let b)): secret = b
                case (2, .bytes(let b)): name = String(decoding: b, as: UTF8.self)
                case (3, .bytes(let b)): issuer = String(decoding: b, as: UTF8.self)
                case (4, .varint(let v)): algorithm = Int(truncatingIfNeeded: v)
                case (5, .varint(let v)): digits = Int(truncatingIfNeeded: v)
                case (6, .varint(let v)): type = Int(truncatingIfNeeded: v)
                default: break
                }
            }
            let account = Account(secret: base32Encode(secret), issuer: issuer, name: name, exportPart: part)
            // 0 means "unspecified", which Google Authenticator treats as the default.
            if type == 1 || !(algorithm == 0 || algorithm == 1) || !(digits == 0 || digits == 1) || secret.isEmpty {
                skipped.append(account.label)
                continue
            }
            out.append(account)
        }
        guard !out.isEmpty else {
            if !skipped.isEmpty {
                throw Failure(message: "None of the accounts in this export makes 6-digit, 30-second SHA-1 codes (\(skipped.joined(separator: ", "))), so FiveT cannot use them."
                              + (part.map { " This is \($0) of the export: your VPN account may be in another one." } ?? ""))
            }
            throw Failure(message: "This Google Authenticator export has no accounts in it.")
        }
        return out
    }

    /// Standard or URL-safe Base64, with or without padding.
    private static func base64(_ s: String) -> Data? {
        var t = s.trimmed.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: " ", with: "+")   // a '+' that became a space on the way
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    static func base32Encode(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = "", buffer = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    // MARK: QR codes in pictures

    /// The text of every QR code in the picture. Only a very big picture (a 5K screenshot, a 48-megapixel
    /// photo: over 13 megapixels) is tried at 2560 px on its long side first, because Vision on the full
    /// picture peaks near 230 MB for the one and 340 MB for the other, and a QR code of ordinary size
    /// reads fine at that scale. Everything smaller goes in at full size, as it always did: a smaller copy
    /// can read one of two codes of very different sizes and so lose the other. A big picture the
    /// smaller copy finds nothing in goes in full too.
    static func qrTexts(in image: CGImage) -> [String] {
        if image.width * image.height > 13_000_000, let small = scaled(image, longSide: 2560) {
            let found = detectQRCodes(in: small)
            if !found.isEmpty { return found }
        }
        return detectQRCodes(in: image)
    }

    private static func scaled(_ image: CGImage, longSide: Int) -> CGImage? {
        let factor = Double(longSide) / Double(max(image.width, image.height))
        let width = max(1, Int(Double(image.width) * factor)), height = max(1, Int(Double(image.height) * factor))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Vision first, Core Image as a second opinion.
    private static func detectQRCodes(in image: CGImage) -> [String] {
        var texts: [String] = []
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        for r in request.results ?? [] {
            if let s = r.payloadStringValue, !texts.contains(s) { texts.append(s) }
        }
        if texts.isEmpty, let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                    options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) {
            for case let f as CIQRCodeFeature in detector.features(in: CIImage(cgImage: image)) {
                if let s = f.messageString, !texts.contains(s) { texts.append(s) }
            }
        }
        return texts
    }

    /// The accounts in a picture of one or more QR codes.
    static func accounts(in image: NSImage) throws -> [Account] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure(message: "This picture could not be read.")
        }
        let texts = qrTexts(in: cg)
        guard !texts.isEmpty else {
            throw Failure(message: "No QR code found in the picture. Take a screenshot of just the QR code (⌃⇧⌘4 copies it) and try again.")
        }
        var out: [Account] = []
        var firstError: Failure?
        for t in texts {
            do { out += try accounts(in: t) } catch let e as Failure { firstError = firstError ?? e }
        }
        if out.isEmpty { throw firstError ?? notASecret(texts[0]) }
        return out
    }
}

/// Just enough of the protocol buffer wire format to read a Google Authenticator export.
enum Protobuf {
    enum Value { case varint(UInt64), bytes(Data), fixed }
    struct Field { let number: Int; let value: Value }

    static func fields(_ data: Data) throws -> [Field] {
        let bytes = [UInt8](data)
        var i = 0, out: [Field] = []
        func varint() throws -> UInt64 {
            var v: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard i < bytes.count, shift < 64 else { throw OTPAuthImport.Failure(message: "This Google Authenticator export is damaged.") }
                let b = bytes[i]; i += 1
                v |= UInt64(b & 0x7f) << shift
                if b & 0x80 == 0 { return v }
                shift += 7
            }
        }
        while i < bytes.count {
            let key = try varint()
            let number = Int(truncatingIfNeeded: key >> 3)
            switch key & 7 {
            case 0: out.append(Field(number: number, value: .varint(try varint())))
            case 1: i += 8; out.append(Field(number: number, value: .fixed))
            case 2:
                let n = try varint()
                guard n <= UInt64(bytes.count - i) else { throw OTPAuthImport.Failure(message: "This Google Authenticator export is damaged.") }
                out.append(Field(number: number, value: .bytes(Data(bytes[i..<(i + Int(n))]))))
                i += Int(n)
            case 5: i += 4; out.append(Field(number: number, value: .fixed))
            default: throw OTPAuthImport.Failure(message: "This Google Authenticator export is damaged.")
            }
            guard i <= bytes.count else { throw OTPAuthImport.Failure(message: "This Google Authenticator export is damaged.") }
        }
        return out
    }
}
