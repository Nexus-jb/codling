// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A .deb the user opened in Codling from another app, through the share
/// sheet or Files. Codling copies it to the files inbox in its caches, and
/// the root helper's take-file keeps it where only root can write and reads
/// its control fields. The user then sees what the package says it is, with
/// a warning that no source vouches for it, and installs it through the
/// queue's review like any other package.
@MainActor
final class OpenedFiles: ObservableObject {
    enum State: Identifiable, Equatable {
        /// The file's name, while the helper reads it.
        case reading(String)
        case ready(OpenedPackage, file: String)
        case failed(String)

        var id: String {
            switch self {
            case .reading(let file): return "reading " + file
            case .ready(let package, _): return package.token
            case .failed(let message): return "failed " + message
            }
        }
    }

    /// What the sheet shows; nil when no file is open.
    @Published var state: State?
    /// Whether the sheet is up. The state stays while it slides away.
    @Published var shown = false

    /// The sheet went away.
    func dismissed() {
        shown = false
        state = nil
    }

    /// Takes the file iOS handed Codling, and shows the package or why it
    /// cannot be installed.
    func open(_ url: URL) async {
        guard url.isFileURL else { return }
        let file = url.lastPathComponent
        state = .reading(file)
        shown = true
        let token = PackageOperation.newFileToken()
        let result = await Task.detached(priority: .userInitiated) { () -> Result<RootHelper.FileCopy, RootHelper.Failure> in
            if let message = OpenedFileInbox.copy(url, token: token) {
                return .failure(.failed(status: 74, message: message))
            }
            let taken = RootHelper.takeFile(token)
            // The helper deletes the inbox's copy once it opens it; this is
            // for when it never got that far.
            try? FileManager.default.removeItem(at: OpenedFileInbox.file(token: token))
            return taken
        }.value
        switch result {
        case .failure(let failure):
            state = .failed(failure.message)
        case .success(let copy):
            if let package = OpenedPackage(token: copy.token, control: copy.control), copy.token == token {
                state = .ready(package, file: file)
            } else {
                state = .failed("dpkg-deb read this file, but the package's name or version is not one Codling can install.")
            }
        }
    }

}

/// Where Codling, which runs as mobile, leaves an opened file for the
/// helper: TOKEN.deb in Library/Caches/com.nexusjb.codling/files, which
/// take-file reads without following links.
enum OpenedFileInbox {
    static let directory = URL(fileURLWithPath: "/var/mobile/Library/Caches/com.nexusjb.codling/files", isDirectory: true)
    /// The largest file Codling takes, as the helper does.
    static let sizeLimit: Int64 = 1 << 30

    static func file(token: String) -> URL {
        directory.appendingPathComponent(token + ".deb")
    }

    /// Copies the file to the inbox as TOKEN.deb. iOS gives Codling a copy
    /// in its Documents/Inbox, which goes once it is copied. Returns why the
    /// copy failed, or nil.
    static func copy(_ url: URL, token: String) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
            let components = url.standardizedFileURL.pathComponents
            if let documents = components.lastIndex(of: "Documents"), components.index(after: documents) < components.count,
               components[components.index(after: documents)] == "Inbox" {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let manager = FileManager.default
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize.map({ Int64($0) }), size > 0 else {
            return "Codling cannot read this file."
        }
        guard size <= sizeLimit else {
            return "This file is larger than 1 GB, which is more than any package Codling installs."
        }
        let target = file(token: token)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try manager.copyItem(at: url, to: target)
        } catch {
            return "Codling could not copy this file: \(error.localizedDescription)"
        }
        return nil
    }
}

/// An opened .deb, for the user to install or close.
struct OpenedPackageView: View {
    let state: OpenedFiles.State
    let environment: RuntimeEnvironment
    @ObservedObject var queue: QueueModel
    let onInstall: (OpenedPackage) -> Void
    let onClose: () -> Void
    @EnvironmentObject private var installed: InstalledPackagesModel

    var body: some View {
        NavigationView {
            content
                .navigationTitle("Install from File")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", action: onClose)
                    }
                }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .reading(let file):
            VStack(spacing: 14) {
                ProgressView()
                Text("Reading \(file)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WallBackground())
        case .failed(let message):
            ScrollView {
                Card(padding: 14) {
                    ToolHeader(symbol: "xmark.octagon", color: .red, title: "Codling cannot install this file") {
                        ToolNote(text: message)
                    }
                }
                .toolColumn()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(WallBackground())
        case .ready(let package, let file):
            ScrollView {
                VStack(spacing: 12) {
                    heading(package)
                    trustCard
                    if let problem = problem(package) {
                        Card(padding: 14) {
                            ToolHeader(symbol: "nosign", color: .red, title: "Not for this jailbreak") {
                                ToolNote(text: problem)
                            }
                        }
                    }
                    installButton(package)
                    if let installedVersion = installed.version(of: package.package) {
                        CardFooter(text: replacing(package, installed: installedVersion))
                    }
                    if queue.isBusy {
                        CardFooter(text: "Codling is making another change. You can install this when it is done.")
                    }
                    if let summary = package.summary {
                        Card(padding: 14) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(summary)
                                    .font(.subheadline.weight(.semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                if let details = package.details {
                                    Text(details)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    details(package, file: file)
                }
                .toolColumn()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(WallBackground())
        }
    }

    private func heading(_ package: OpenedPackage) -> some View {
        Card(padding: 14) {
            HStack(spacing: 12) {
                PackageIcon(urls: [], section: package.section, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(package.displayName)
                        .font(.title3.weight(.bold))
                        .lineLimit(growing: 2)
                    if let author = package.authorName {
                        Text(author)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(growing: 1)
                    }
                    Text("Version \(package.version)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var trustCard: some View {
        Card(padding: 14) {
            ToolHeader(symbol: "exclamationmark.shield", color: .orange, title: "Not from one of your sources") {
                ToolNote(text: "You opened this file yourself, so no source vouches for it: Codling cannot check who made it or whether it was changed. Install it only if you trust where it came from. Its dependencies come from your sources, and the review shows them first.")
            }
        }
    }

    private func installButton(_ package: OpenedPackage) -> some View {
        Button(installTitle(package)) {
            onInstall(package)
        }
        .buttonStyle(CapsuleButtonStyle())
        .disabled(queue.isBusy || problem(package) != nil)
    }

    /// Install, or what installing the file does to the installed version:
    /// Update, Reinstall or Downgrade.
    private func installTitle(_ package: OpenedPackage) -> String {
        guard let version = installed.version(of: package.package) else { return "Install" }
        let order = DebianVersion.compare(DebianVersion(package.version), DebianVersion(version))
        return order > 0 ? "Update" : order == 0 ? "Reinstall" : "Downgrade"
    }

    private func details(_ package: OpenedPackage, file: String) -> some View {
        VStack(spacing: 0) {
            InfoRow(name: "Identifier", value: package.package, monospaced: true, first: true)
            InfoRow(name: "Version", value: package.version)
            if !package.architecture.isEmpty {
                InfoRow(name: "Architecture", value: package.architecture, monospaced: true)
            }
            if let section = package.section {
                InfoRow(name: "Section", value: section)
            }
            if let depends = package.depends {
                InfoRow(name: "Depends on", value: depends)
            }
            if let conflicts = package.conflicts {
                InfoRow(name: "Conflicts with", value: conflicts)
            }
            if let size = package.installedSize {
                InfoRow(name: "Installed size",
                        value: ByteCountFormatter.string(fromByteCount: size * 1024, countStyle: .file))
            }
            InfoRow(name: "File", value: file)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 22)
    }

    /// Why the package cannot be installed here, or nil.
    private func problem(_ package: OpenedPackage) -> String? {
        switch package.fit(deviceArchitecture: environment.architecture) {
        case .fits:
            return nil
        case .otherArchitecture(let architecture):
            switch architecture {
            case "iphoneos-arm":
                return "This package is for rootful jailbreaks (iphoneos-arm). Codling supports rootless and RootHide jailbreaks, which use other paths, so it cannot install it."
            case "iphoneos-arm64":
                return "This package is for rootless jailbreaks (iphoneos-arm64), and this device uses \(environment.scheme.title) (\(environment.architecture))."
            case "iphoneos-arm64e":
                return "This package is for RootHide (iphoneos-arm64e), and this device uses \(environment.scheme.title) (\(environment.architecture))."
            default:
                return "This package is for \(architecture), and this device takes \(environment.architecture) packages."
            }
        }
    }

    private func replacing(_ package: OpenedPackage, installed version: String) -> String {
        let order = DebianVersion.compare(DebianVersion(package.version), DebianVersion(version))
        if order == 0 {
            return "Version \(version) is installed. Installing the file puts the same version in again."
        }
        return order < 0
            ? "Version \(version) is installed, which is newer than this file. Installing the file goes back to \(package.version), and undo can bring \(version) back."
            : "Version \(version) is installed. Installing the file upgrades it to \(package.version)."
    }
}
