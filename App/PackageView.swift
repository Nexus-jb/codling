// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A package's page: its header, its depiction and its details. Installing
/// comes in a later version of Codling, so this page has no Install button.
struct PackageView: View {
    let source: SourceInfo
    let identifier: String
    /// What the list showed, for the header while the page loads.
    var summary: PackageSummary?

    @EnvironmentObject private var sources: SourcesModel
    @EnvironmentObject private var installed: InstalledPackagesModel
    @Environment(\.device) private var device
    @StateObject private var model = PackageModel()
    @StateObject private var router = DepictionRouter()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if case .native(let depiction, _) = model.depiction, let headerImage = depiction.headerImage {
                    RemoteImage(urls: [headerImage], maxPixels: 1600) {
                        Color(.secondarySystemFill)
                    }
                    .frame(height: 170)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Card(padding: 14) {
                        header
                    }
                    depictionSection
                    if model.loaded {
                        details
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.load(store: sources.store, source: source, package: identifier)
        }
        .depictionRouting(router, base: depictionBase)
    }

    private var record: PackageRecord? { model.newest }

    private var name: String {
        if let name = record?.name, !name.isEmpty {
            return name
        }
        return summary?.displayName ?? identifier
    }

    private var depictionBase: URL? {
        switch model.depiction {
        case .native(_, let base): return base
        case .web(let url): return url
        default: return source.base
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                PackageIcon(urls: source.url(record?.icon ?? summary?.icon).map { [$0] } ?? [],
                            section: record?.section ?? summary?.section, size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    if let author = author {
                        Text(author)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text(record?.version ?? summary?.version ?? "")
                            .font(.footnote.monospacedDigit())
                            .foregroundColor(.secondary)
                        if PackageCatalog.tags(record?.tag ?? summary?.tag).contains("cydia::commercial") {
                            PaidBadge()
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if let installedVersion = installed.version(of: identifier) {
                Label(installedText(installedVersion), systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.green)
            }
            if let record {
                CompatibilityCard(report: Compatibility.check(depends: record.depends, tag: record.tag, name: record.name,
                                                              summary: record.summary, systemVersion: device.systemVersion),
                                  architecture: record.architecture)
            }
            if model.loaded {
                PackageActions(identifier: identifier, name: name, available: record?.version,
                               isPaid: PackageCatalog.tags(record?.tag ?? summary?.tag).contains("cydia::commercial"))
            }
            if let summaryText = record?.summary ?? summary?.summary, !summaryText.isEmpty {
                Text(summaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var author: String? {
        guard let person = record?.author ?? record?.maintainer ?? summary?.author ?? summary?.maintainer else { return nil }
        let name = Person.name(person)
        return name.isEmpty ? nil : name
    }

    private func installedText(_ version: String) -> String {
        guard let available = record?.version, DebianVersion(available) > DebianVersion(version) else {
            return "Installed: \(version)"
        }
        return "Installed: \(version). Version \(available) is available."
    }

    // MARK: Depiction

    @ViewBuilder
    private var depictionSection: some View {
        switch model.depiction {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(24)
        case .native(let depiction, _):
            Card(padding: 0) {
                NativeDepictionContent(depiction: depiction)
                    .padding(.vertical, 8)
            }
        case .web(let url):
            // Pages in a web view inside Codling stop before they draw on a
            // jailbroken device, so the page opens in the browser sheet, as
            // in Sileo.
            descriptionText
            WebDepictionLink(title: "Full Description") {
                router.perform(.web(url))
            }
        case .failed(let message):
            problem(message) {
                Task { await model.reloadDepiction(source: source) }
            }
            descriptionText
        case .absent:
            descriptionText
        }
    }

    private func problem(_ message: String, retry: @escaping () -> Void) -> some View {
        Card(padding: 14) {
            ToolHeader(symbol: "exclamationmark.triangle", color: .orange, title: "The description did not load") {
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Try Again", action: retry)
                .buttonStyle(TintedButtonStyle())
                .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var descriptionText: some View {
        if let details = record?.details, !details.isEmpty {
            Card(padding: 14) {
                Text(details)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeading(title: "Package Details", symbol: "info.circle")
                .padding(.top, 8)
            Card(padding: 14) {
                detailRows
            }
        }
    }

    @ViewBuilder
    private var detailRows: some View {
        if let record {
            InfoRow(name: "Version", value: record.version)
            if let version = installed.version(of: identifier) {
                InfoRow(name: "Installed", value: version)
            }
            InfoRow(name: "Section", value: PackageCatalog.displaySection(record.section))
            if let author = record.author {
                InfoRow(name: "Author", value: Person.name(author))
            }
            if let maintainer = record.maintainer {
                InfoRow(name: "Maintainer", value: Person.name(maintainer))
            }
            if let size = record.size {
                InfoRow(name: "Download Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            InfoRow(name: "Identifier", value: record.package)
            InfoRow(name: "Source", value: source.title)
            if let depends = record.depends, !depends.isEmpty {
                InfoRow(name: "Depends", value: depends)
            }
            if model.versions.count > 1 {
                InfoRow(name: "Other Versions", value: model.versions.dropFirst().map(\.version).joined(separator: ", "))
            }
        } else {
            Text("This source no longer lists this package. Refresh your sources to update the list.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}

/// Install, Upgrade and Remove. Each queues the change; the Queue tab
/// reviews it with apt before anything happens.
private struct PackageActions: View {
    let identifier: String
    let name: String
    /// The newest version this source offers; nil when it no longer lists
    /// the package.
    let available: String?
    let isPaid: Bool
    @EnvironmentObject private var installed: InstalledPackagesModel
    @EnvironmentObject private var queue: QueueModel

    var body: some View {
        let installedVersion = installed.version(of: identifier)
        let upgradable = installedVersion.flatMap { current in
            available.map { DebianVersion($0) > DebianVersion(current) }
        } ?? false
        VStack(alignment: .leading, spacing: 8) {
            if let queued = queue.operation(for: identifier) {
                HStack {
                    Label(queuedText(queued, installed: installedVersion != nil), systemImage: "clock.fill")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Take Off Queue") {
                        queue.remove(identifier)
                    }
                    .buttonStyle(.bordered)
                }
                Text("Review it in the Queue tab.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 10) {
                    if installedVersion == nil {
                        if !isPaid && available != nil {
                            action("Install", .install(identifier), prominent: true)
                        }
                    } else {
                        if upgradable && !isPaid {
                            action("Upgrade", .install(identifier), prominent: true)
                        }
                        action("Remove", .remove(identifier), prominent: false)
                            .tint(.red)
                    }
                }
                if isPaid && (installedVersion == nil || upgradable) {
                    Text("Installing and upgrading paid packages comes in a later version of Codling.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func action(_ title: String, _ operation: PackageOperation, prominent: Bool) -> some View {
        let button = Button {
            queue.add(operation, name: name)
        } label: {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(minWidth: 90)
        }
        .controlSize(.large)
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func queuedText(_ operation: PackageOperation, installed: Bool) -> String {
        switch operation {
        case .install: return installed ? "Queued to upgrade" : "Queued to install"
        case .remove: return "Queued to remove"
        case .restore: return "Queued to restore"
        }
    }
}

/// A row that opens a web page in the browser sheet.
struct WebDepictionLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: "safari")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
            .font(.body.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
    }
}

private struct InfoRow: View {
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
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

/// A package a depiction links to, by identifier: its page when one source
/// offers it, a choice when several do.
struct PackageLookupView: View {
    let identifier: String
    @EnvironmentObject private var sources: SourcesModel
    @StateObject private var model = PackageLookupModel()

    var body: some View {
        Group {
            if !model.loaded {
                ProgressView()
            } else if model.offers.count == 1, let offer = model.offers.first, let info = sources.info(for: offer.source) {
                PackageView(source: info, identifier: offer.package, summary: offer)
            } else if model.offers.isEmpty {
                Text("None of your sources offers \(identifier).")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        CardHeading(title: "Offered by", symbol: "tray.full")
                        let offers = model.offers.filter { sources.info(for: $0.source) != nil }
                        CardRows(items: offers, dividerInset: 72) { offer in
                            if let info = sources.info(for: offer.source) {
                                NavigationLink(destination: PackageView(source: info, identifier: offer.package, summary: offer)) {
                                    CatalogCardRow(package: offer, source: info, showSource: true)
                                }
                                .buttonStyle(CardRowButtonStyle())
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
                .navigationTitle(identifier)
            }
        }
        .task {
            await model.load(store: sources.store, identifier: identifier)
        }
    }
}

/// A native depiction that another depiction links to.
struct DepictionPageView: View {
    let url: URL
    let title: String
    @StateObject private var router = DepictionRouter()
    @State private var phase: Phase = .loading

    enum Phase {
        case loading
        case loaded(NativeDepiction)
        case failed(String)
    }

    var body: some View {
        ScrollView {
            switch phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(32)
            case .loaded(let depiction):
                NativeDepictionContent(depiction: depiction)
                    .padding(.vertical, 8)
            case .failed(let message):
                VStack(spacing: 10) {
                    Text(message)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {
                        Task { await load() }
                    }
                }
                .padding(32)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .depictionRouting(router, base: url)
    }

    private func load() async {
        phase = .loading
        do {
            let data = try await MediaLoader.shared.data(from: url)
            let depiction = try await Task.detached(priority: .userInitiated) {
                try NativeDepiction.parse(data, base: url)
            }.value
            phase = .loaded(depiction)
        } catch let error as MediaLoader.LoadError {
            phase = .failed("The page could not be loaded. \(error.message)")
        } catch {
            phase = .failed("The page could not be read: it is not a valid Sileo depiction.")
        }
    }
}
