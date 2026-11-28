// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// Converting a rootless package on RootHide (RootlessConversion in
/// CodlingCore): Codling downloads the source's file, checks it against the
/// size and SHA256 hash the source's index lists, and hands it to RootHide
/// Patcher through the share sheet. The user chooses how to convert it there,
/// and shares the converted file back to Codling, which installs it as any
/// file the user opens.
@MainActor
final class RootlessConversionFlow: ObservableObject {
    /// What is being done, while it is.
    @Published private(set) var working: String?
    /// Why the last attempt stopped.
    @Published var problem: String?

    /// Where downloads for RootHide Patcher are kept. Only the newest is
    /// kept: each new one replaces the folder's contents.
    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("com.nexusjb.codling/convert", isDirectory: true)
    }

    /// Downloads the record's file, from the source or, when it was bought,
    /// from its payment provider, and opens the share sheet with it.
    func start(record: PackageRecord, source: SourceInfo, name: String, purchase: PurchaseRequest?,
               sources: SourcesModel, accounts: PaymentAccounts) async {
        guard working == nil else { return }
        let fileName = RootlessConversion.fileName(package: record.package, version: record.version,
                                                   filename: record.filename)
        let directory = Self.directory
        let destination = directory.appendingPathComponent(fileName)
        working = "Downloading \(name)"
        defer { working = nil }
        do {
            try? FileManager.default.removeItem(at: directory)
            if let purchase {
                try await accounts.download(package: record.package, name: name, request: purchase, to: destination)
            } else {
                guard let url = source.url(record.filename) else {
                    throw RefreshError.message("\(source.title) does not say where to download \(name).")
                }
                try await sources.downloadFile(url, to: destination)
            }
            working = "Checking \(name)"
            if let failure = await Self.check(destination, size: record.size, sha256: record.sha256) {
                try? FileManager.default.removeItem(at: destination)
                throw RefreshError.message(failure)
            }
        } catch {
            problem = (error as? PaymentProvider.Failure)?.message ?? (error as? RefreshError)?.message
                ?? RefreshError.describe(error)
            return
        }
        Presenter.share([destination])
    }

    /// Why the file is not the one the source's index lists, or nil when
    /// it is. A record without a hash is taken as it is, as apt would when
    /// the source does not list one.
    private static func check(_ file: URL, size: Int64?, sha256: String?) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
                return "Codling could not read the download."
            }
            if let size, Int64(data.count) != size {
                return "The download is \(data.count) bytes, but the source lists \(size). It may have been changed on the way."
            }
            if let sha256, !sha256.isEmpty {
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if digest != sha256.lowercased() {
                    return "The download does not match the SHA256 hash the source lists. It may have been changed on the way."
                }
            }
            return nil
        }.value
    }
}
