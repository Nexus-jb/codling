// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The packages dpkg has installed, read from its status file.
struct InstalledView: View {
    let environment: RuntimeEnvironment
    @ObservedObject var model: InstalledPackagesModel
    @EnvironmentObject private var sources: SourcesModel
    @State private var query = ""
    /// The newer versions the sources offer of installed packages.
    @State private var updates: [PackageSummary] = []

    var body: some View {
        NavigationView {
            content
                .navigationTitle("Installed")
                .systemButton()
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
            ScrollView {
                VStack(spacing: 8) {
                    if query.isEmpty {
                        updatesSection
                    }
                    if !shown.isEmpty {
                        CardRows(items: shown) { package in
                            NavigationLink(destination: PackageDetailView(package: package)) {
                                PackageRow(package: package)
                            }
                            .buttonStyle(CardRowButtonStyle())
                        }
                    }
                    CardFooter(text: footer(shown: shown.count, total: packages.count))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(WallBackground())
            .searchable(text: $query, prompt: "Name, identifier or author")
            .refreshable { await model.load(statusPath: environment.dpkgStatusPath) }
            .task(id: "\(sources.indexGeneration) \(model.versions.hashValue)") { await findUpdates() }
        }
    }

    /// The updates, above the installed packages; nothing when there are
    /// none.
    @ViewBuilder
    private var updatesSection: some View {
        let rows = updates.compactMap { package in
            sources.info(for: package.source).map { UpdateRow(package: package, info: $0) }
        }
        if !rows.isEmpty {
            CardHeading(title: rows.count == 1 ? "1 Update" : "\(rows.count) Updates", symbol: "arrow.down.circle")
            CardRows(items: rows, dividerInset: 72) { row in
                NavigationLink(destination: PackageView(source: row.info, identifier: row.package.package, summary: row.package)) {
                    CompactPackageRow(package: row.package, source: row.info,
                                      status: model.version(of: row.package.package)
                                          .map { "Installed \($0), \(row.package.version) available" } ?? "",
                                      statusColor: .blue)
                }
                .buttonStyle(CardRowButtonStyle())
            }
            CardHeading(title: "Installed", symbol: "shippingbox")
                .padding(.top, 6)
        }
    }

    private func findUpdates() async {
        guard let store = sources.store, !model.versions.isEmpty else {
            updates = []
            return
        }
        let offers = (try? await store.offers(ofAny: Array(model.versions.keys))) ?? []
        updates = AvailableUpdates.find(installed: model.versions, offers: offers)
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
        HStack(spacing: 14) {
            InstalledIcon(package: package)
            VStack(alignment: .leading, spacing: 2) {
                Text(package.name)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if !package.summary.isEmpty {
                    Text(package.summary)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 8)
            Text(package.version)
                .font(.footnote.monospacedDigit())
                .foregroundColor(.secondary)
                .lineLimit(1)
            Chevron()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// The icon a package names, when it loads; otherwise its section's symbol
/// on its section's color.
private struct InstalledIcon: View {
    let package: InstalledPackage
    var size: CGFloat = 40

    var body: some View {
        PackageIcon(urls: iconURL.map { [$0] } ?? [], section: package.section, size: size)
    }

    private var iconURL: URL? {
        guard let text = package.field("Icon"), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), ["https", "http", "file"].contains(scheme) else {
            return nil
        }
        return url
    }
}

private struct PackageDetailView: View {
    let package: InstalledPackage
    @EnvironmentObject private var queue: QueueModel

    /// The fields shown in the summary, in this order; the rest follow.
    private static let summaryFields = ["Version", "Section", "Author", "Maintainer", "Architecture", "Installed-Size"]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Card(padding: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        InstalledIcon(package: package, size: 60)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(package.name)
                                .font(.title3.bold())
                            Text(package.identifier)
                                .font(.footnote.monospaced())
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                            if !package.summary.isEmpty {
                                Text(package.summary)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if !package.details.isEmpty {
                        Text(package.details)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                    }
                }

                CardHeading(title: "Details", symbol: "info.circle")
                    .padding(.top, 8)
                CardRows(items: fields, dividerInset: 14) { field in
                    FieldRow(name: field.name, value: field.value)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }

                Card(padding: 14) {
                    let queued = queue.operation(for: package.identifier) != nil
                    ToolHeader(symbol: queued ? "tray.and.arrow.down" : "trash", color: queued ? .blue : .red,
                               title: queued ? "Queued" : "Remove") {
                        ToolNote(text: queued
                                 ? "Review it in the Queue tab."
                                 : "Removing queues the change; the Queue tab shows everything apt would remove before anything happens.")
                    }
                    if queued {
                        Button("Take Off Queue") {
                            queue.remove(package.identifier)
                        }
                        .buttonStyle(TintedButtonStyle())
                        .padding(.top, 12)
                    } else {
                        Button("Remove", role: .destructive) {
                            queue.add(.remove(package.identifier), name: package.name)
                        }
                        .buttonStyle(TintedButtonStyle(color: .red))
                        .padding(.top, 12)
                    }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(WallBackground())
        .navigationTitle(package.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct Field: Identifiable {
        let name: String
        let value: String

        var id: String { name }
    }

    private var fields: [Field] {
        var found: [Field] = Self.summaryFields.compactMap { name in
            package.field(name).map {
                Field(name: name == "Installed-Size" ? "Installed Size" : name,
                      value: name == "Installed-Size" ? Self.size($0) : InstalledPackage.withoutEmail($0))
            }
        }
        if let depends = package.field("Depends") {
            found.append(Field(name: "Depends", value: depends))
        }
        return found
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
                .font(.subheadline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// An installed package's newer version, with the source it is from.
private struct UpdateRow: Identifiable {
    let package: PackageSummary
    let info: SourceInfo

    var id: String { package.id }
}
