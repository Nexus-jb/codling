// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A source's page: its featured banners, then its packages by section.
struct SourceDetailView: View {
    let sourceID: String
    @EnvironmentObject private var sources: SourcesModel
    @StateObject private var model = SourceDetailModel()
    @State private var confirmingRemoval = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let row = sources.rows.first(where: { $0.id == sourceID }), let info = sources.info(for: sourceID) {
            content(row: row, info: info)
        } else {
            Text("This source is no longer in apt's lists.")
                .foregroundColor(.secondary)
                .padding()
        }
    }

    private func content(row: SourcesModel.Row, info: SourceInfo) -> some View {
        List {
            Section {
                SourceRow(row: row, iconSize: 56)
            }
            if let entry = PiracySources.entry(for: row.source.uri) {
                Section {
                    Label("\(entry.name) is known for handing out paid tweaks and apps without their developers' permission. Cracked packages are often outdated or unstable and can carry malware.",
                          systemImage: "exclamationmark.shield.fill")
                        .foregroundColor(.red)
                } footer: {
                    Text(sources.isCodlingSource(row.source)
                         ? "Codling does not block any source. You can remove this one below."
                         : "Codling does not block any source. This one was added outside Codling; remove it in the app that added it.")
                }
            }
            if let featured = model.featured {
                Section {
                    BannerCarousel(featured: featured, source: info, model: model)
                        .listRowInsets(EdgeInsets())
                }
            }
            Section {
                if !model.loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if let error = model.error {
                    Text(error)
                        .foregroundColor(.red)
                } else if model.packages.isEmpty {
                    Text("Codling has no packages from this source. It may have none for this device, or its last refresh failed.")
                        .foregroundColor(.secondary)
                } else {
                    NavigationLink(destination: PackageListView(title: "All Packages", source: info, packages: model.packages)) {
                        CountRow(title: "All Packages", symbol: "square.stack.3d.up.fill", count: model.packages.count)
                    }
                    ForEach(model.sections) { section in
                        NavigationLink(destination: PackageListView(title: section.name, source: info,
                                                                    packages: model.packages.filter { $0.displaySection == section.name })) {
                            CountRow(title: section.name, symbol: SectionSymbol.name(for: section.name), count: section.count)
                        }
                    }
                }
            } header: {
                Text("Sections")
            }
            if sources.isCodlingSource(row.source) {
                Section {
                    Button("Remove Source", role: .destructive) {
                        confirmingRemoval = true
                    }
                } footer: {
                    Text("Added with Codling.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(row.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sources.indexGeneration) {
            await model.load(store: sources.store, source: row.source)
        }
        .refreshable {
            await model.load(store: sources.store, source: row.source, reloadBanners: true)
        }
        .confirmationDialog("Remove this source?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove \(row.source.host)", role: .destructive) {
                Task {
                    if let reason = await sources.remove(row.source) {
                        problem = reason
                    } else {
                        dismiss()
                    }
                }
            }
        } message: {
            Text("Its packages stay installed. Codling stops showing its packages and their updates.")
        }
        .alert("The source was not removed", isPresented: Binding(
            get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }
}

private struct CountRow: View {
    let title: String
    let symbol: String
    let count: Int

    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(count.formatted())
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// A source's featured banners, side by side; a banner opens its package
/// when the source has it.
private struct BannerCarousel: View {
    let featured: FeaturedBanners
    let source: SourceInfo
    @ObservedObject var model: SourceDetailModel

    var body: some View {
        let size = fitted(featured.itemSize)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(featured.banners.indices, id: \.self) { index in
                    let banner = featured.banners[index]
                    if let package = model.package(banner.package) {
                        NavigationLink(destination: PackageView(source: source, identifier: package.package, summary: package)) {
                            BannerView(banner: banner, size: size, cornerRadius: featured.cornerRadius)
                        }
                        .buttonStyle(.plain)
                    } else {
                        BannerView(banner: banner, size: size, cornerRadius: featured.cornerRadius)
                    }
                }
            }
            .padding(16)
        }
    }

    private func fitted(_ size: DepictionSize) -> CGSize {
        let available = UIScreen.main.bounds.width - 64
        let scale = min(1, available / size.width)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

private struct BannerView: View {
    let banner: FeaturedBanners.Banner
    let size: CGSize
    let cornerRadius: Double

    var body: some View {
        RemoteImage(urls: [banner.image], maxPixels: Int(size.width * 3)) {
            Color(.secondarySystemFill)
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .bottomLeading) {
            if !banner.title.isEmpty {
                Text(banner.title)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(banner.hideShadow ? 0 : 0.2), radius: 6, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(banner.title.isEmpty ? "Featured package" : banner.title)
    }
}

/// The packages of a source or section, with a filter.
struct PackageListView: View {
    let title: String
    let source: SourceInfo
    let packages: [PackageSummary]
    @State private var query = ""

    var body: some View {
        let shown = filtered
        List {
            Section {
                ForEach(shown) { package in
                    NavigationLink(destination: PackageView(source: source, identifier: package.package, summary: package)) {
                        CatalogRow(package: package, source: source, showSource: false)
                    }
                }
            } footer: {
                Text(shown.count == packages.count ? "\(packages.count.formatted()) packages"
                     : "\(shown.count.formatted()) of \(packages.count.formatted()) packages")
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Filter by name, author or identifier")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var filtered: [PackageSummary] {
        let words = PackageCatalog.searchWords(query)
        guard !words.isEmpty else { return packages }
        return packages.filter { package in
            let fields = [package.displayName, package.package, package.displayAuthor ?? "", package.summary ?? ""]
                .map { $0.lowercased() }
            return words.allSatisfy { word in fields.contains { $0.contains(word) } }
        }
    }
}

/// A package in a list: icon, name, version, summary and author.
struct CatalogRow: View {
    let package: PackageSummary
    let source: SourceInfo
    let showSource: Bool
    @Environment(\.device) private var device

    var body: some View {
        HStack(spacing: 12) {
            IconView(urls: source.url(package.icon).map { [$0] } ?? [], symbol: SectionSymbol.name(for: package.section))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(package.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    if package.isPaid {
                        PaidBadge()
                    }
                    Spacer(minLength: 4)
                    Text(package.version)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if let summary = package.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                if package.compatibility(systemVersion: device.systemVersion).verdict == .unsupported {
                    Label("Not for iOS \(device.systemVersion)", systemImage: "xmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.red)
                }
                let byline = [package.displayAuthor, showSource ? source.title : nil].compactMap { $0 }.joined(separator: " · ")
                if !byline.isEmpty {
                    Text(byline)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Search across the packages of every source.
struct SearchView: View {
    @EnvironmentObject private var sources: SourcesModel
    @StateObject private var model = SearchModel()
    @State private var query = ""

    var body: some View {
        NavigationView {
            List {
                let trimmed = query.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    Section {
                        Text(hint)
                            .foregroundColor(.secondary)
                    }
                } else if model.searchedQuery == trimmed && model.results.isEmpty {
                    Section {
                        Text("No package matches \u{201C}\(trimmed)\u{201D}.")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section {
                        ForEach(model.results) { package in
                            if let info = sources.info(for: package.source) {
                                NavigationLink(destination: PackageView(source: info, identifier: package.package, summary: package)) {
                                    CatalogRow(package: package, source: info, showSource: true)
                                }
                            }
                        }
                    } footer: {
                        if model.truncated {
                            Text("Showing the best \(SearchModel.limit) matches. Add words to narrow the search.")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Name, author or identifier")
            .disableAutocorrection(true)
            .textInputAutocapitalization(.never)
            .navigationTitle("Search")
            .task(id: "\(sources.indexGeneration) \(query)") {
                await model.search(query, store: sources.store)
            }
        }
        .navigationViewStyle(.stack)
    }

    private var hint: String {
        guard model.totalPackages > 0 else {
            return "Refresh your sources to search their packages."
        }
        let count = sources.rows.count
        return "Search \(model.totalPackages.formatted()) packages from your \(count == 1 ? "source" : "\(count) sources")."
    }
}
