// FiveT's release key: signs what release.sh publishes, so FiveT installs only real releases.
// Built by release.sh together with Sources/fivet/UpdateSignature.swift (the message format):
//   swiftc -O Tools/update-signing/main.swift Sources/fivet/UpdateSignature.swift -o build/tools/update-signing
//
//   update-signing keygen [--test]                   make the key (once), print its public half
//   update-signing public [--test]                   print the public half (no password needed)
//   update-signing sign <version> <build> <sha256> [--test]   print the Base64 signature for latest.json
//   update-signing verify <version> <build> <sha256> <signature>   exit 0 when valid for this build's keys
//   update-signing backup <file>                     save the release key, encrypted with a passphrase
//   update-signing restore <file>                    put a backup into this Mac's keychain (a new release Mac)
//
// Two keys, both in the login keychain:
// - The release key ("FiveT update signing key") trusts no program: every use shows the macOS
//   keychain prompt, so nothing running on this Mac can take it or sign with it unnoticed. Click
//   Allow, never Always Allow. Its public half is kept in the item's comment, readable without it.
// - The test key ("FiveT update test key") signs fake releases for the fivet-test-copy skill. Only
//   builds that are never shipped accept it (UpdateSignature), so it is readable without a prompt.
// Keys go to /usr/bin/security on stdin (`security -i`), never on a command line `ps` would show.
import Foundation
import CryptoKit
import CommonCrypto

struct Slot {
    let service: String
    let locked: Bool          // every read needs the user's approval
    var expected: [String]    // the public keys the app accepts for this slot
}
let release = Slot(service: "FiveT update signing key", locked: true, expected: UpdateSignature.releaseKeys)
#if DISTRIBUTION
let test = Slot(service: "FiveT update test key", locked: false, expected: [])
#else
let test = Slot(service: "FiveT update test key", locked: false, expected: [UpdateSignature.testKey])
#endif
let account = "fivet"

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("update-signing: " + message + "\n").utf8))
    exit(code)
}

@discardableResult
func security(_ args: [String], stdin: String? = nil) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let out = Pipe(), input = Pipe()
    p.standardOutput = out
    p.standardError = out
    p.standardInput = stdin == nil ? FileHandle.nullDevice : input
    do { try p.run() } catch { fail("cannot run /usr/bin/security: \(error)") }
    if let stdin {
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try? input.fileHandleForWriting.close()
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// The public half, from the item's comment ("pub=<base64>"): no prompt.
func storedPublic(_ slot: Slot) -> String? {
    let r = security(["find-generic-password", "-s", slot.service, "-a", account])
    guard r.status == 0, let line = r.output.split(separator: "\n").first(where: { $0.contains("\"icmt\"") }),
          let start = line.range(of: "pub=") else { return nil }
    return String(line[start.upperBound...].prefix { $0 != "\"" })
}

/// The private key. For the release key, macOS asks the user first.
func storedKey(_ slot: Slot) -> Curve25519.Signing.PrivateKey? {
    if slot.locked { FileHandle.standardError.write(Data("update-signing: macOS asks for your Mac password to use FiveT's release key (click Allow, not Always Allow)\n".utf8)) }
    let r = security(["find-generic-password", "-s", slot.service, "-a", account, "-w"])
    guard r.status == 0, let raw = Data(base64Encoded: r.output.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

func store(_ key: Curve25519.Signing.PrivateKey, in slot: Slot) {
    let b64 = key.rawRepresentation.base64EncodedString()
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    // -T "" : no program may read it without asking. Without -T, /usr/bin/security (which made it) may.
    let trust = slot.locked ? " -T \"\"" : ""
    let r = security(["-i"], stdin: "add-generic-password -s \"\(slot.service)\" -a \(account) -l \"\(slot.service)\" -j \"pub=\(pub)\"\(trust) -w \(b64)\n")
    guard storedPublic(slot) == pub else {
        fail("could not store the key in the login keychain: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}

func requireKey(_ slot: Slot) -> Curve25519.Signing.PrivateKey {
    guard storedPublic(slot) != nil else {
        fail(slot.locked ? "FiveT's release key is not in this Mac's login keychain. Restore it from its backup:  update-signing restore <file>"
                         : "no test key yet:  update-signing keygen --test")
    }
    guard let key = storedKey(slot) else { fail("the keychain did not hand out the key (was the prompt denied?)") }
    return key
}

func readPassphrase(_ prompt: String) -> String {
    guard isatty(STDIN_FILENO) == 1, let p = getpass(prompt) else { fail("run this in a Terminal window: it asks for a passphrase") }
    return String(cString: p)
}

/// PBKDF2-HMAC-SHA256, 600 000 rounds: a guessed passphrase costs an attacker real time per try.
func derive(_ passphrase: String, salt: Data, rounds: UInt32) -> SymmetricKey {
    var out = [UInt8](repeating: 0, count: 32)
    let pw = Array(passphrase.utf8)
    let status = salt.withUnsafeBytes { s in
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                             s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &out, out.count)
    }
    guard status == kCCSuccess else { fail("could not derive a key from the passphrase") }
    return SymmetricKey(data: out)
}

struct Backup: Codable {
    var format = "fivet-release-key-backup-1"
    var publicKey: String
    var rounds: UInt32
    var salt: String
    var sealed: String
}

/// A backup inside this git repository would be committed (and uploaded) by the next release.
func refuseInsideRepo(_ path: String) {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let r = Process()
    r.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    r.arguments = ["-C", url.deletingLastPathComponent().path, "rev-parse", "--show-toplevel"]
    let pipe = Pipe()
    r.standardOutput = pipe
    r.standardError = FileHandle.nullDevice
    try? r.run()
    r.waitUntilExit()
    if r.terminationStatus == 0 {
        fail("\(path) is inside a git repository, where the next release would commit it. Save the backup somewhere else, e.g. ~/Documents.")
    }
}

var args = Array(CommandLine.arguments.dropFirst())
let useTest = args.contains("--test")
args.removeAll { $0 == "--test" }
let slot = useTest ? test : release

switch args.first {
case "keygen":
    if storedPublic(slot) != nil { fail("that key already exists; `update-signing public\(useTest ? " --test" : "")` prints it") }
    let key = Curve25519.Signing.PrivateKey()
    store(key, in: slot)
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "public":
    guard let pub = storedPublic(slot) else { fail("no such key in this Mac's login keychain") }
    print(pub)

case "sign":
    guard args.count == 4, let build = Int(args[2]), build > 0, args[3].count == 64, args[3].allSatisfy(\.isHexDigit) else {
        fail("usage: update-signing sign <version> <build> <sha256> [--test]", 2)
    }
    guard let pub = storedPublic(slot), slot.expected.contains(pub) else {
        fail("the key in this keychain is not one FiveT accepts (UpdateSignature); copies of FiveT would refuse this release")
    }
    let key = requireKey(slot)
    let signature = try key.signature(for: UpdateSignature.message(version: args[1], build: build, sha256: args[3])).base64EncodedString()
    guard UpdateSignature.isValid(signature, version: args[1], build: build, sha256: args[3], keys: slot.expected) else {
        fail("the signature does not verify")
    }
    print(signature)

case "verify":
    guard args.count == 5, let build = Int(args[2]) else { fail("usage: update-signing verify <version> <build> <sha256> <signature>", 2) }
    let ok = UpdateSignature.isValid(args[4], version: args[1], build: build, sha256: args[3])
    print(ok ? "valid" : "INVALID")
    exit(ok ? 0 : 1)

case "backup":
    guard args.count == 2 else { fail("usage: update-signing backup <file outside this repository>", 2) }
    let path = (args[1] as NSString).expandingTildeInPath
    refuseInsideRepo(path)
    guard !FileManager.default.fileExists(atPath: path) else { fail("\(path) exists already") }
    let key = requireKey(release)
    let pass = readPassphrase("Passphrase for the backup (write it down, at least 12 characters): ")
    guard pass.count >= 12 else { fail("that passphrase is too short") }
    guard readPassphrase("The same passphrase again: ") == pass else { fail("the two passphrases differ") }
    var salt = Data(count: 16)
    _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
    let rounds: UInt32 = 600_000
    let sealed = try AES.GCM.seal(key.rawRepresentation, using: derive(pass, salt: salt, rounds: rounds))
    let backup = Backup(publicKey: key.publicKey.rawRepresentation.base64EncodedString(), rounds: rounds,
                        salt: salt.base64EncodedString(), sealed: sealed.combined!.base64EncodedString())
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard FileManager.default.createFile(atPath: path, contents: try enc.encode(backup), attributes: [.posixPermissions: 0o600]) else {
        fail("could not write \(path) (does its folder exist?). Nothing was saved.")
    }
    // Read it back and open it with the passphrase: a backup that cannot be restored is no backup.
    guard let written = FileManager.default.contents(atPath: path), let check = try? JSONDecoder().decode(Backup.self, from: written),
          let box = try? AES.GCM.SealedBox(combined: Data(base64Encoded: check.sealed) ?? Data()),
          let raw = try? AES.GCM.open(box, using: derive(pass, salt: Data(base64Encoded: check.salt) ?? Data(), rounds: check.rounds)),
          raw == key.rawRepresentation else {
        try? FileManager.default.removeItem(atPath: path)
        fail("the backup written to \(path) did not read back correctly; it was removed. Try another place.")
    }
    print("Saved and checked \(path). Keep it, and the passphrase, somewhere safe off this Mac (a password manager, a USB stick).")

case "restore":
    guard args.count == 2 else { fail("usage: update-signing restore <backup file>", 2) }
    if storedPublic(release) != nil { fail("this keychain has a release key already") }
    let path = (args[1] as NSString).expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: path), let backup = try? JSONDecoder().decode(Backup.self, from: data),
          let salt = Data(base64Encoded: backup.salt), let combined = Data(base64Encoded: backup.sealed) else { fail("that is not a FiveT release key backup") }
    let pass = readPassphrase("Passphrase of the backup: ")
    guard let box = try? AES.GCM.SealedBox(combined: combined),
          let raw = try? AES.GCM.open(box, using: derive(pass, salt: salt, rounds: backup.rounds)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("wrong passphrase, or a damaged backup") }
    store(key, in: release)
    let pub = key.publicKey.rawRepresentation.base64EncodedString()
    print(release.expected.contains(pub) ? "Restored; it is the key FiveT accepts." : "Restored, but it is NOT a key FiveT accepts (\(pub)).")

default:
    fail("usage: update-signing keygen|public [--test] | sign <version> <build> <sha256> [--test] | verify <version> <build> <sha256> <signature> | backup <file> | restore <file>", 2)
}
