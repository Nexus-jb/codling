// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// The result of refreshing one source.
struct RefreshOutcome {
    enum State {
        /// New package indexes were read.
        case updated
        /// Nothing changed since the last refresh.
        case unchanged
        case failed(String)
    }

    var state: State
    var label: String?
    var signature: Signature?
    var packageCount: Int?
    /// Things the user should know that do not stop the refresh.
    var warnings: [String] = []
}

/// Refreshes sources: downloads each Release file and checks its signature,
/// then downloads the package indexes it lists, checks their checksums, and
/// writes their packages to the index. A source whose Release file and
/// indexes have not changed is not downloaded again.
struct SourceRefresher {
    let jailbreakRoot: String
    let architecture: String
    let store: IndexStore
    let signatures: SignatureCheck
    /// Where the downloaded files are kept, under apt's names.
    let listsDirectory: URL
    let session: URLSession

    /// The most a package index may grow to once decompressed.
    static let indexLimit = 512 << 20

    static func makeSession(version: String, model: String, systemVersion: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Codling/\(version) (\(model); iOS \(systemVersion))",
            // Repositories that offer files for some devices only read these,
            // as Sileo and Zebra send them. They identify the model, not the device.
            "X-Machine": model,
            "X-Firmware": systemVersion,
            // Checksums are of the file as published: no transfer compression.
            "Accept-Encoding": "identity",
        ]
        return URLSession(configuration: configuration)
    }

    func refresh(_ source: Source, force: Bool) async -> RefreshOutcome {
        do {
            return try await refreshThrowing(source, force: force)
        } catch let error as RefreshError {
            return RefreshOutcome(state: .failed(error.message))
        } catch let error as SignatureError {
            return RefreshOutcome(state: .failed(error.message))
        } catch let error as IndexStoreError {
            return RefreshOutcome(state: .failed(error.message))
        } catch {
            return RefreshOutcome(state: .failed(RefreshError.describe(error)))
        }
    }

    private func refreshThrowing(_ source: Source, force: Bool) async throws -> RefreshOutcome {
        guard let directory = source.releaseDirectoryURL else {
            throw RefreshError.message("The address \(source.uri) is not a valid URL.")
        }
        let stored = try await store.source(id: source.id)
        let validators = force ? nil : stored
        var warnings: [String] = []

        // The Release file: InRelease, or Release with Release.gpg.
        var releaseText: String?
        var signature: Signature = .unsigned
        var etag: String?
        var modified: String?
        var releaseFiles: [(name: String, data: Data)] = []

        let inRelease = try await fetch(directory.appendingPathComponent("InRelease"), validators: validators)
        switch inRelease {
        case .notModified:
            return unchanged(stored, source: source)
        case .found(let data, let headers):
            let verified = try signatures.verifyClearsigned(data, source: source)
            releaseText = verified.text
            signature = verified.signature
            (etag, modified) = (headers.etag, headers.modified)
            releaseFiles = [("InRelease", data)]
        case .missing:
            let release = try await fetch(directory.appendingPathComponent("Release"), validators: validators)
            switch release {
            case .notModified:
                return unchanged(stored, source: source)
            case .found(let data, let headers):
                releaseText = String(decoding: data, as: UTF8.self)
                (etag, modified) = (headers.etag, headers.modified)
                releaseFiles = [("Release", data)]
                if case .found(let detached, _) = try await fetch(directory.appendingPathComponent("Release.gpg"), validators: nil) {
                    signature = try signatures.verifyDetached(release: data, signature: detached, source: source)
                    releaseFiles.append(("Release.gpg", detached))
                }
            case .missing:
                warnings.append("This source has no Release file, so its index cannot be checked.")
            }
        }
        if source.trusted {
            signature = .trustedWithoutSignature
        }
        switch signature {
        case .unsigned where releaseText != nil:
            warnings.append("This source is not signed, so Codling cannot tell whether its files were changed on the way.")
        case .untrustedKey(let key):
            warnings.append("This source is signed with a key this device does not trust (\(key)), so the signature proves nothing.")
        default:
            break
        }

        let release = releaseText.flatMap(ReleaseFile.init(text:))
        let releaseDigest = releaseText.map { Self.sha256(Data($0.utf8)) }
        var stateToSave = StoredSource(id: source.id, label: release?.label ?? release?.origin ?? stored?.label,
                                       releaseETag: etag, releaseModified: modified, releaseDigest: releaseDigest,
                                       indexDigests: nil, signature: signature.stored, refreshed: Date(),
                                       packageCount: stored?.packageCount ?? 0)

        // The package indexes, in the forms the Release file lists.
        let indexPaths = source.packageIndexPaths(architecture: architecture)
        let listed = indexPaths.map { release?.preferredFile(for: $0) }
        let digestLines = zip(indexPaths, listed).compactMap { path, file -> String? in
            guard let file, let digest = file.entry.digests["SHA256"] ?? file.entry.digests.values.first else { return nil }
            return "\(path) \(digest)"
        }.joined(separator: "\n")
        stateToSave.indexDigests = digestLines

        if !force, let stored, stored.packageCount > 0, release != nil, digestLines.count > 0,
           stored.indexDigests == digestLines {
            // The Release file changed, but not the indexes it lists.
            stateToSave.warnings = (warnings + (stored.warnings ?? "").split(separator: "\n").map(String.init)
                .filter { !warnings.contains($0) }).joined(separator: "\n")
            try await store.save(stateToSave, packages: nil)
            try saveLists(source: source, releaseFiles: releaseFiles, indexes: [])
            return RefreshOutcome(state: .unchanged, label: stateToSave.label, signature: signature,
                                  packageCount: stored.packageCount, warnings: warnings)
        }

        var records: [PackageRecord] = []
        var indexes: [(path: String, data: Data)] = []
        for (path, file) in zip(indexPaths, listed) {
            let text: Data
            if let file {
                let url = directory.appendingPathComponent(file.path)
                guard case .found(let data, _) = try await fetch(url, validators: nil) else {
                    throw RefreshError.message("The Release file lists \(file.path), but the server does not have it.")
                }
                guard let check = Digest.verify(data, against: file.entry) else {
                    throw RefreshError.message("The Release file gives no checksum Codling can check for \(file.path).")
                }
                guard check.matches else {
                    throw RefreshError.message("\(file.path) does not match its \(check.algorithm) checksum in the Release file. It may have been changed on the way, or the source is being updated: try again in a few minutes.")
                }
                text = try Self.decompress(data, compression: file.compression, name: file.path)
            } else if let release, !release.entries.isEmpty {
                // Listed files, but none for this index: as apt does, skip it.
                warnings.append("This source has no packages for \(architecture) (\(path)).")
                continue
            } else {
                // No Release file, or one without checksums: try the usual
                // forms of the index, which cannot be checked.
                guard let probed = try await probe(directory: directory, indexPath: path) else {
                    throw RefreshError.message("The source has no package index (\(path)).")
                }
                text = probed
                if release != nil {
                    warnings.append("The Release file lists no checksums, so the index cannot be checked.")
                }
            }
            indexes.append((path, text))
            records += PackageIndex.parse(text, architecture: architecture)
        }

        stateToSave.warnings = warnings.joined(separator: "\n")
        try await store.save(stateToSave, packages: records)
        try saveLists(source: source, releaseFiles: releaseFiles, indexes: indexes)
        return RefreshOutcome(state: .updated, label: stateToSave.label, signature: signature,
                              packageCount: records.count, warnings: warnings)
    }

    private func unchanged(_ stored: StoredSource?, source: Source) -> RefreshOutcome {
        RefreshOutcome(state: .unchanged, label: stored?.label,
                       signature: stored?.signature.flatMap(Signature.init(stored:)),
                       packageCount: stored?.packageCount,
                       warnings: (stored?.warnings ?? "").split(separator: "\n").map(String.init))
    }

    /// Tries Packages.xz, .bz2, .gz and plain Packages in turn.
    private func probe(directory: URL, indexPath: String) async throws -> Data? {
        for compression in ReleaseFile.compressions {
            let path = compression.isEmpty ? indexPath : indexPath + "." + compression
            if case .found(let data, _) = try await fetch(directory.appendingPathComponent(path), validators: nil) {
                return try Self.decompress(data, compression: compression, name: path)
            }
        }
        return nil
    }

    /// Keeps the downloaded files under the names apt gives them, for apt to
    /// use later.
    private func saveLists(source: Source, releaseFiles: [(name: String, data: Data)], indexes: [(path: String, data: Data)]) throws {
        try FileManager.default.createDirectory(at: listsDirectory, withIntermediateDirectories: true)
        for file in releaseFiles {
            let name = AptNaming.listFileName(for: source.releaseDirectory + file.name)
            try file.data.write(to: listsDirectory.appendingPathComponent(name), options: .atomic)
        }
        for index in indexes {
            let name = AptNaming.listFileName(for: source.releaseDirectory + index.path)
            try index.data.write(to: listsDirectory.appendingPathComponent(name), options: .atomic)
        }
    }

    // MARK: Downloads

    enum Fetched {
        case found(Data, (etag: String?, modified: String?))
        case notModified
        case missing
    }

    private func fetch(_ url: URL, validators: StoredSource?) async throws -> Fetched {
        var request = URLRequest(url: url)
        if let etag = validators?.releaseETag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let modified = validators?.releaseModified {
            request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RefreshError.message("\(url.absoluteString) did not answer over HTTP.")
        }
        switch http.statusCode {
        case 200:
            return .found(data, (http.value(forHTTPHeaderField: "ETag"), http.value(forHTTPHeaderField: "Last-Modified")))
        case 304:
            return validators == nil ? .missing : .notModified
        case 403, 404, 410:
            return .missing
        default:
            throw RefreshError.message("\(url.host ?? url.absoluteString) answered \(http.statusCode) (\(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))) for \(url.lastPathComponent).")
        }
    }

    static func decompress(_ data: Data, compression: String, name: String) throws -> Data {
        let kind: Int32
        switch compression {
        case "": kind = Int32(codling_compression_none.rawValue)
        case "gz": kind = Int32(codling_compression_gzip.rawValue)
        case "bz2": kind = Int32(codling_compression_bzip2.rawValue)
        case "xz": kind = Int32(codling_compression_xz.rawValue)
        default: throw RefreshError.message("\(name) is compressed in a way Codling cannot read.")
        }
        var output: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = data.withUnsafeBytes { raw in
            codling_decompress(kind, raw.bindMemory(to: UInt8.self).baseAddress, data.count, indexLimit, &output, &length)
        }
        guard status == Int32(codling_decompress_ok.rawValue), let output else {
            throw RefreshError.message(status == Int32(codling_decompress_too_large.rawValue)
                ? "\(name) is larger than \(indexLimit >> 20) MB once decompressed."
                : "\(name) could not be decompressed: the file is damaged.")
        }
        return Data(bytesNoCopy: output, count: length, deallocator: .free)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum RefreshError: Error {
    case message(String)

    var message: String {
        switch self {
        case .message(let text): return text
        }
    }

    /// An English description of a download error.
    static func describe(_ error: Error) -> String {
        guard let url = error as? URLError else {
            return "\(error)"
        }
        switch url.code {
        case .notConnectedToInternet: return "The device is not connected to the internet."
        case .timedOut: return "The server did not answer in time."
        case .cannotFindHost, .dnsLookupFailed: return "The server's name could not be found."
        case .cannotConnectToHost: return "The server refused the connection."
        case .networkConnectionLost: return "The connection was lost during the download."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "A secure connection to the server could not be made: its certificate is not valid."
        case .appTransportSecurityRequiresSecureConnection:
            return "The source uses plain HTTP, which this build does not allow."
        case .cancelled: return "The refresh was cancelled."
        default: return "The download failed (\(url.code.rawValue))."
        }
    }
}

extension Signature {
    /// The form kept in the index.
    var stored: String {
        switch self {
        case .signed(let name): return "signed:" + name
        case .untrustedKey(let key): return "untrusted:" + key
        case .unsigned: return "unsigned"
        case .trustedWithoutSignature: return "trusted"
        }
    }

    init?(stored: String) {
        if stored.hasPrefix("signed:") {
            self = .signed(by: String(stored.dropFirst(7)))
        } else if stored.hasPrefix("untrusted:") {
            self = .untrustedKey(String(stored.dropFirst(10)))
        } else if stored == "unsigned" {
            self = .unsigned
        } else if stored == "trusted" {
            self = .trustedWithoutSignature
        } else {
            return nil
        }
    }
}
