import Foundation
import CryptoKit

/// Ed25519 signatures on FiveT releases.
///
/// The SHA-256 in latest.json proves the download is the file the feed names, but the feed and the
/// file come from the same server: whoever controls that server (or the account behind it)
/// could name any file. So release.sh also signs the release with FiveT's release key, whose private
/// half exists only in the release Mac's login keychain (Tools/update-signing), and FiveT installs
/// only a release signed with it. The signature covers version, build and checksum together, so an
/// old signed release cannot be relabelled as a newer one.
///
/// This file is compiled into the app and into Tools/update-signing, so both build the same message.
enum UpdateSignature {
    /// Public halves of FiveT's release keys (raw Ed25519, Base64). A release signed with any of them
    /// installs. To replace a key: add the new one here, ship that release signed with the old key,
    /// sign later releases with the new one, then drop the old one.
    static let releaseKeys = ["zWhFEaq9p3/NXzi7H4mzLqjpSM17Xot2hpd6STIxw9o="]

    #if DISTRIBUTION
    static let acceptedKeys = releaseKeys
    #else
    /// Builds that are never shipped (build.sh without --dmg; the copies the fivet-test-copy skill
    /// runs) also accept the test key, whose private half signs fake releases for testing the updater.
    /// Shipped builds (DISTRIBUTION) never accept it.
    static let testKey = "Ci/k4zkerab5cihh7smRfPQubhgDTGD9YRpeDb4CAaY="
    static let acceptedKeys = releaseKeys + [testKey]
    #endif

    /// The exact bytes that are signed.
    static func message(version: String, build: Int, sha256: String) -> Data {
        Data("FiveT update\nversion=\(version)\nbuild=\(build)\nsha256=\(sha256.lowercased())\n".utf8)
    }

    /// True when `signature` is a signature over this release by one of `keys`. A release without a
    /// build number or with a checksum that is not 64 hex digits is never valid.
    static func isValid(_ signature: String?, version: String, build: Int?, sha256: String,
                        keys: [String] = acceptedKeys) -> Bool {
        guard let build, build > 0, sha256.count == 64, sha256.allSatisfy(\.isHexDigit), !version.isEmpty,
              let signature, let sig = Data(base64Encoded: signature) else { return false }
        let msg = message(version: version, build: build, sha256: sha256)
        return keys.contains { k in
            guard let raw = Data(base64Encoded: k), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
            return key.isValidSignature(sig, for: msg)
        }
    }
}
