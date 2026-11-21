// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// How a source's Release file was vouched for.
enum Signature: Equatable {
    /// A good signature from a trusted key; the name on the key.
    case signed(by: String)
    /// Signed with a key this device does not trust, so as good as unsigned.
    case untrustedKey(String)
    /// No signature at all.
    case unsigned
    /// The source is marked Trusted: yes, so apt asks for no signature.
    case trustedWithoutSignature
}

enum SignatureError: Error {
    case bad(String)
    case gpgvMissing
    case gpgvFailed(String)

    var message: String {
        switch self {
        case .bad(let detail):
            return "The Release file's signature does not match it. It may have been changed on the way. \(detail)"
        case .gpgvMissing:
            return "gpgv is not installed, so signatures cannot be checked. Install the gnupg package."
        case .gpgvFailed(let detail):
            return "gpgv could not check the signature: \(detail)"
        }
    }
}

/// Checks Release signatures with the jailbreak's gpgv, as apt does, against
/// the keys apt trusts.
struct SignatureCheck {
    let jailbreakRoot: String
    let workDirectory: URL

    private var gpgv: String { jailbreakRoot + "/usr/bin/gpgv" }

    /// The keyrings for a source: its Signed-By files, or else every binary
    /// keyring in trusted.gpg.d and trusted.gpg.
    func keyrings(for source: Source) -> [String] {
        if !source.signedBy.isEmpty {
            return source.signedBy
        }
        let directory = jailbreakRoot + "/etc/apt/trusted.gpg.d"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        var keyrings = names.sorted().filter { $0.hasSuffix(".gpg") }.map { directory + "/" + $0 }
        let legacy = jailbreakRoot + "/etc/apt/trusted.gpg"
        if FileManager.default.fileExists(atPath: legacy) {
            keyrings.append(legacy)
        }
        return keyrings
    }

    /// Checks an InRelease file and returns the text it signs.
    func verifyClearsigned(_ data: Data, source: Source) throws -> (text: String, signature: Signature) {
        let input = workDirectory.appendingPathComponent(UUID().uuidString + ".InRelease")
        let output = workDirectory.appendingPathComponent(UUID().uuidString + ".Release")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        try data.write(to: input)
        let signature = try run(source: source, arguments: ["--output", tool(output.path), tool(input.path)])
        if case .signed = signature {
            let signed = try Data(contentsOf: output)
            return (String(decoding: signed, as: UTF8.self), signature)
        }
        // Not verified: the text between the armor lines, for reading only.
        return (Self.unarmored(String(decoding: data, as: UTF8.self)), signature)
    }

    /// Checks a Release file against its detached Release.gpg.
    func verifyDetached(release: Data, signature: Data, source: Source) throws -> Signature {
        let releaseFile = workDirectory.appendingPathComponent(UUID().uuidString + ".Release")
        let signatureFile = workDirectory.appendingPathComponent(UUID().uuidString + ".Release.gpg")
        defer {
            try? FileManager.default.removeItem(at: releaseFile)
            try? FileManager.default.removeItem(at: signatureFile)
        }
        try release.write(to: releaseFile)
        try signature.write(to: signatureFile)
        return try run(source: source, arguments: [tool(signatureFile.path), tool(releaseFile.path)])
    }

    /// A real path as gpgv sees it: on RootHide, gpgv sees the jailbreak
    /// root as / and the system volume under /rootfs.
    private func tool(_ path: String) -> String {
        ToolPath.convert(path, root: jailbreakRoot)
    }

    private func run(source: Source, arguments: [String]) throws -> Signature {
        guard FileManager.default.isExecutableFile(atPath: gpgv) else {
            throw SignatureError.gpgvMissing
        }
        let home = workDirectory.appendingPathComponent("gnupg")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var full = ["gpgv", "--status-fd", "1"]
        // A source's Signed-By is written for apt, as gpgv reads it; the
        // keyrings Codling found itself are real paths.
        let keyringPaths = source.signedBy.isEmpty ? keyrings(for: source).map { tool($0) } : source.signedBy
        for keyring in keyringPaths {
            full += ["--keyring", keyring]
        }
        full += arguments
        let search = [jailbreakRoot + "/usr/bin", jailbreakRoot + "/bin", "/usr/bin", "/bin"].map { tool($0) }
        let environment = ["PATH=" + search.joined(separator: ":"), "GNUPGHOME=" + tool(home.path)]
        let result = Subprocess.run(path: gpgv, arguments: full, environment: environment, timeoutMilliseconds: 30_000)
        guard let result else {
            throw SignatureError.gpgvFailed("it did not start")
        }
        let status = String(decoding: result.output, as: UTF8.self)
        let lines = status.split(separator: "\n").map { $0.replacingOccurrences(of: "[GNUPG:] ", with: "") }
        if lines.contains(where: { $0.hasPrefix("BADSIG") }) {
            throw SignatureError.bad(lines.first { $0.hasPrefix("BADSIG") } ?? "")
        }
        if result.status == 0, let good = lines.first(where: { $0.hasPrefix("GOODSIG ") }),
           lines.contains(where: { $0.hasPrefix("VALIDSIG ") }) {
            // GOODSIG <long key id> <user id>
            let parts = good.split(separator: " ", maxSplits: 2)
            return .signed(by: parts.count == 3 ? String(parts[2]) : String(parts.dropFirst().first ?? ""))
        }
        if let missing = lines.first(where: { $0.hasPrefix("NO_PUBKEY ") || $0.hasPrefix("ERRSIG ") }) {
            let key = missing.split(separator: " ").dropFirst().first.map(String.init) ?? "?"
            return .untrustedKey(key)
        }
        if lines.contains(where: { $0.hasPrefix("NODATA") }) || status.isEmpty && result.status != 0 {
            return .unsigned
        }
        let errors = String(decoding: result.errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw SignatureError.gpgvFailed(errors.isEmpty ? "exit status \(result.status)" : errors)
    }

    /// The text of a clearsigned message, without the armor and dash-escaping.
    static func unarmored(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN PGP SIGNED MESSAGE-----") }) else {
            return text
        }
        lines.removeFirst(begin + 1)
        // Armor headers ("Hash: SHA512") run to the first blank line.
        if let blank = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            lines.removeFirst(blank + 1)
        }
        if let end = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN PGP SIGNATURE-----") }) {
            lines.removeSubrange(end...)
        }
        return lines.map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }.joined(separator: "\n")
    }
}

/// Runs a program as the mobile user and collects what it prints. (Foundation's
/// Process is not available on iOS.)
enum Subprocess {
    struct Output {
        let status: Int32
        let output: Data
        let errors: Data
    }

    static func run(path: String, arguments: [String], environment: [String], timeoutMilliseconds: Int32) -> Output? {
        let argumentStrings = arguments.map { strdup($0) }
        let environmentStrings = environment.map { strdup($0) }
        defer {
            argumentStrings.forEach { free($0) }
            environmentStrings.forEach { free($0) }
        }
        let argumentPointers: [UnsafePointer<CChar>?] = argumentStrings.map { $0.map { UnsafePointer($0) } } + [nil]
        let environmentPointers: [UnsafePointer<CChar>?] = environmentStrings.map { $0.map { UnsafePointer($0) } } + [nil]
        var result = codling_result()
        defer { codling_result_free(&result) }
        let started = argumentPointers.withUnsafeBufferPointer { argumentList in
            environmentPointers.withUnsafeBufferPointer { environmentList in
                codling_run(path, argumentList.baseAddress, environmentList.baseAddress, false, timeoutMilliseconds, &result)
            }
        }
        guard started == 0, !result.timed_out else {
            return nil
        }
        let output = result.output.map { Data(bytes: $0, count: result.output_length) } ?? Data()
        let errors = result.errors.map { Data(bytes: $0, count: result.errors_length) } ?? Data()
        return Output(status: result.status, output: output, errors: errors)
    }
}

enum Digest {
    /// The lowercase hex digest of data with one of a Release file's algorithms.
    static func hex(_ data: Data, algorithm: String) -> String? {
        switch algorithm {
        case "SHA512": return SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "SHA256": return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "SHA1": return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "MD5Sum": return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        default: return nil
        }
    }

    /// Checks data against a Release entry with its strongest digest. Returns
    /// the algorithm used, or nil when the entry has none Codling knows.
    static func verify(_ data: Data, against entry: ReleaseFile.Entry) -> (algorithm: String, matches: Bool)? {
        for algorithm in ["SHA512", "SHA256", "SHA1", "MD5Sum"] {
            if let expected = entry.digests[algorithm], let actual = hex(data, algorithm: algorithm) {
                return (algorithm, actual == expected && Int64(data.count) == entry.size)
            }
        }
        return nil
    }
}
