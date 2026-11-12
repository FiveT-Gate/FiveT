import Foundation
import CryptoKit

/// A .fivet backup file: "FIVETBK1" + an AES-256-GCM box (nonce, text, tag) around the connections.json-format
/// text, so passwords and one-time-code secrets are never on disk in the clear. The key comes from BackupKey
/// (a git-ignored file build.sh creates once), so only a FiveT built with that key can open the file.
enum BackupFile {
    private static let magic = Data("FIVETBK1".utf8)

    private static var key: SymmetricKey {
        // shortcut: the key sits inside the app, so someone who takes it out of the binary can open backups;
        // upgrade to a passphrase if that matters.
        var bytes = Data()
        var i = BackupKey.hex.startIndex
        while i < BackupKey.hex.endIndex {
            let j = BackupKey.hex.index(i, offsetBy: 2)
            bytes.append(UInt8(BackupKey.hex[i..<j], radix: 16) ?? 0)
            i = j
        }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes), salt: magic,
                                      info: Data("fivet backup 1".utf8), outputByteCount: 32)
    }

    static func seal(_ plain: Data) throws -> Data {
        guard let box = try AES.GCM.seal(plain, using: key, authenticating: magic).combined else {
            throw NSError(domain: "fivet", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encrypt the backup."])
        }
        return magic + box
    }

    /// The text inside a backup file. A file from before backups were encrypted (1.19.0 to 1.21.x) has no
    /// header and comes back as it is, so old exports still import; FiveT never writes one again.
    static func open(_ file: Data) throws -> Data {
        guard file.starts(with: magic) else { return file }
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: file.dropFirst(magic.count)), using: key, authenticating: magic) }
        catch { throw NSError(domain: "fivet", code: 3, userInfo: [NSLocalizedDescriptionKey: "This backup is damaged or was made by a different FiveT build, so this FiveT cannot decrypt it."]) }
    }

    /// "2026-11-13_FiveT-backup.fivet": today's date (Gregorian, this Mac's time zone), then the backup's name.
    static func defaultName(_ name: String = "FiveT-backup", now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return "\(f.string(from: now))_\(name).fivet"
    }
}
