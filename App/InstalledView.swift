// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The packages dpkg has installed, read from its status file.
struct InstalledView: View {
    let environment: RuntimeEnvironment
    @ObservedObject var model: InstalledPackagesModel
    @State private var query = ""

    var body: some View {
        NavigationView {
            content
                .navigationTitle("Installed")
        }
        .navigationViewStyle(.stack)
        .task { await model.load(statusPath: environment.dpkgStatusPath) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Reading the installed packages")
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await model.load(statusPath: environment.dpkgStatusPath) }
                }
            }
            .padding()
        case .loaded(let packages):
            let shown = filtered(packages)
            List {
                Section {
                    ForEach(shown) { package in
                        NavigationLink(destination: PackageDetailView(package: package)) {
                            PackageRow(package: package)
                        }
                    }
                } footer: {
                    Text(footer(shown: shown.count, total: packages.count))
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Name, identifier or author")
            .refreshable { await model.load(statusPath: environment.dpkgStatusPath) }
        }
    }

    private func filtered(_ packages: [InstalledPackage]) -> [InstalledPackage] {
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else {
            return packages
        }
        return packages.filter { package in
            [package.name, package.identifier, package.author ?? ""].contains {
                $0.localizedCaseInsensitiveContains(words)
            }
        }
    }

    private func footer(shown: Int, total: Int) -> String {
        let noun = total == 1 ? "package" : "packages"
        return shown == total ? "\(total) \(noun) installed" : "\(shown) of \(total) \(noun)"
    }
}

private struct PackageRow: View {
    let package: InstalledPackage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(package.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(package.version)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            if !package.summary.isEmpty {
                Text(package.summary)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PackageDetailView: View {
    let package: InstalledPackage
    @EnvironmentObject private var queue: QueueModel

    /// The fields shown in the summary, in this order; the rest follow.
    private static let summaryFields = ["Version", "Section", "Author", "Maintainer", "Architecture", "Installed-Size"]

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(package.name)
                        .font(.title2.bold())
                    Text(package.identifier)
                        .font(.footnote.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    if !package.summary.isEmpty {
                        Text(package.summary)
                    }
                    if !package.details.isEmpty {
                        Text(package.details)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Details") {
                ForEach(Self.summaryFields, id: \.self) { name in
                    if let value = package.field(name) {
                        FieldRow(name: name == "Installed-Size" ? "Installed Size" : name,
                                 value: name == "Installed-Size" ? Self.size(value) : InstalledPackage.withoutEmail(value))
                    }
                }
                if let depends = package.field("Depends") {
                    FieldRow(name: "Depends", value: depends)
                }
            }
            Section {
                if queue.operation(for: package.identifier) != nil {
                    Button("Take Off Queue") {
                        queue.remove(package.identifier)
                    }
                } else {
                    Button("Remove", role: .destructive) {
                        queue.add(.remove(package.identifier), name: package.name)
                    }
                }
            } footer: {
                Text(queue.operation(for: package.identifier) != nil
                     ? "Queued. Review it in the Queue tab."
                     : "Removing queues the change; the Queue tab shows everything apt would remove before anything happens.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(package.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// dpkg's Installed-Size is in KiB.
    private static func size(_ kibibytes: String) -> String {
        guard let value = Int64(kibibytes.trimmingCharacters(in: .whitespaces)) else {
            return kibibytes
        }
        return ByteCountFormatter.string(fromByteCount: value * 1024, countStyle: .file)
    }
}

private struct FieldRow: View {
    let name: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
