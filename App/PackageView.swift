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
    @StateObject private var model = PackageModel()
    @StateObject private var router = DepictionRouter()
    @State private var webHeight: CGFloat = 1
    @State private var webState: WebLoadState = .loading
    @State private var webReload = 0

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
                header
                depictionSection
                if model.loaded {
                    details
                }
            }
        }
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
                IconView(urls: source.url(record?.icon ?? summary?.icon).map { [$0] } ?? [],
                         symbol: SectionSymbol.name(for: record?.section ?? summary?.section), size: 72)
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
            if let summaryText = record?.summary ?? summary?.summary, !summaryText.isEmpty {
                Text(summaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
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
            Divider()
                .padding(.horizontal, 16)
            NativeDepictionContent(depiction: depiction)
                .padding(.vertical, 8)
        case .web(let url):
            Divider()
                .padding(.horizontal, 16)
            webDepiction(url)
        case .failed(let message):
            problem(message) {
                Task { await model.reloadDepiction(source: source) }
            }
            descriptionText
        case .absent:
            descriptionText
        }
    }

    private func webDepiction(_ url: URL) -> some View {
        WebDepictionView(url: url, height: $webHeight, state: $webState, reload: webReload) { link in
            router.open(link, base: url)
        }
        .frame(height: webState == .loading ? max(webHeight, 200) : max(webHeight, 1))
        .overlay {
            switch webState {
            case .loading:
                ProgressView()
            case .failed(let message):
                Color(.systemBackground)
                    .overlay(problem(message) { webReload += 1 })
            case .loaded:
                EmptyView()
            }
        }
    }

    private func problem(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
    }

    @ViewBuilder
    private var descriptionText: some View {
        if let details = record?.details, !details.isEmpty {
            Text(details)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Information")
                .font(.headline)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
        .padding(16)
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
                List {
                    Section("Offered by") {
                        ForEach(model.offers) { offer in
                            if let info = sources.info(for: offer.source) {
                                NavigationLink(destination: PackageView(source: info, identifier: offer.package, summary: offer)) {
                                    CatalogRow(package: offer, source: info, showSource: true)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
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
