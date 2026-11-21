// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A source's page: its featured banners, then its packages by section.
struct SourceDetailView: View {
    let sourceID: String
    @EnvironmentObject private var sources: SourcesModel
    @EnvironmentObject private var installed: InstalledPackagesModel
    @State private var findings: [SourceScan.Finding]?
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
        ScrollView {
            VStack(spacing: 12) {
                Card {
                    SourceHeader(row: row)
                }
                if let entry = PiracySources.entry(for: row.source.uri) {
                    Card {
                        StatusLine(symbol: "exclamationmark.shield.fill", text: "Known for piracy", color: .red, font: .body.weight(.semibold))
                        Text("\(entry.name) is known for handing out paid tweaks and apps without their developers' permission. Cracked packages are often outdated or unstable and can carry malware.")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                    }
                    CardFooter(text: "Codling does not block any source. You can remove this one below.")
                }
                if let featured = model.featured {
                    CardHeading(title: "Featured Packages", symbol: "star.fill")
                        .padding(.top, 8)
                    BannerCarousel(featured: featured, source: info, model: model)
                        .padding(.horizontal, -16)
                }

                CardHeading(title: "Sections", symbol: "square.stack.3d.up")
                    .padding(.top, 8)
                Card(padding: 0) {
                    sections(info: info)
                }

                CardHeading(title: "Security Check", symbol: "checkmark.shield")
                    .padding(.top, 8)
                Card {
                    securityCheck
                }

                Card(padding: 0) {
                    Button(role: .destructive) {
                        confirmingRemoval = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "trash")
                                .font(.title3)
                            Text("Remove Source")
                                .font(.body.weight(.semibold))
                            Spacer()
                        }
                        .foregroundColor(.red)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 15)
                    }
                    .buttonStyle(CardRowButtonStyle())
                }
                .padding(.top, 8)
                CardFooter(text: sources.isCodlingSource(row.source)
                           ? "Added with Codling."
                           : "Listed in \((row.source.file as NSString).lastPathComponent).")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(WallBackground())
        .navigationTitle(row.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sources.indexGeneration) {
            await model.load(store: sources.store, source: row.source)
            findings = await sources.scan(sourceID: sourceID, installed: installed.versions,
                                          essential: installed.essential)
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
            Text(SourcesModel.removalNote(for: row.source, jailbreak: sources.isJailbreakSource(row.source)))
        }
        .alert("The source was not removed", isPresented: Binding(
            get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }
}

private extension SourceDetailView {
    @ViewBuilder
    func sections(info: SourceInfo) -> some View {
        if !model.loaded {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(16)
        } else if let error = model.error {
            Text(error)
                .foregroundColor(.red)
                .padding(16)
        } else if model.packages.isEmpty {
            Text("Codling has no packages from this source. It may have none for this device, or its last refresh failed.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
        } else {
            NavigationLink(destination: PackageListView(title: "All Packages", source: info, packages: model.packages)) {
                CountRow(title: "All Packages", symbol: "square.stack.3d.up.fill", color: .blue, count: model.packages.count)
            }
            .buttonStyle(CardRowButtonStyle())
            ForEach(model.sections) { section in
                Divider()
                    .padding(.leading, 66)
                NavigationLink(destination: PackageListView(title: section.name, source: info,
                                                            packages: model.packages.filter { $0.displaySection == section.name })) {
                    CountRow(title: section.name, symbol: SectionSymbol.name(for: section.name),
                             color: SectionSymbol.color(for: section.name), count: section.count)
                }
                .buttonStyle(CardRowButtonStyle())
            }
        }
    }

    @ViewBuilder
    var securityCheck: some View {
        if let findings {
            VStack(alignment: .leading, spacing: 10) {
                if findings.isEmpty {
                    StatusLine(symbol: "checkmark.shield.fill", text: "Nothing found", color: .green, font: .body.weight(.semibold))
                }
                ForEach(findings) { finding in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol(for: finding))
                            .accessibilityHidden(true)
                        Text(SourceScan.describe(finding))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundColor(color(for: finding))
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking")
                    .foregroundColor(.secondary)
            }
        }
        Divider()
            .padding(.vertical, 12)
        Text("Compares this source with your other sources and installed packages: packages sold elsewhere and free here, packages that say they are cracks, and newer copies of the jailbreak's own packages. Codling cannot see inside packages.")
            .font(.subheadline)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    func symbol(for finding: SourceScan.Finding) -> String {
        switch finding.kind {
        case .paidElsewhere: return "dollarsign.circle.fill"
        case .crack: return "exclamationmark.shield.fill"
        case .replacesSystem: return "exclamationmark.triangle.fill"
        }
    }

    func color(for finding: SourceScan.Finding) -> Color {
        switch finding.kind {
        case .paidElsewhere, .crack: return .red
        case .replacesSystem: return .orange
        }
    }
}

private struct CountRow: View {
    let title: String
    let symbol: String
    let color: Color
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, color: color, size: 36)
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(count.formatted())
                .foregroundColor(.secondary)
                .monospacedDigit()
            Chevron()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private func fitted(_ size: DepictionSize) -> CGSize {
        let available = UIScreen.main.bounds.width - 64
        let scale = min(1, available / size.width)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

struct BannerView: View {
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
        ScrollView {
            VStack(spacing: 8) {
                if !shown.isEmpty {
                    CardRows(items: shown, dividerInset: 72) { package in
                        NavigationLink(destination: PackageView(source: source, identifier: package.package, summary: package)) {
                            CatalogCardRow(package: package, source: source, showSource: false)
                        }
                        .buttonStyle(CardRowButtonStyle())
                    }
                }
                CardFooter(text: shown.count == packages.count ? "\(packages.count.formatted()) packages"
                           : "\(shown.count.formatted()) of \(packages.count.formatted()) packages")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(WallBackground())
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

/// A package as a row of a card: the catalog row, with a chevron.
struct CatalogCardRow: View {
    let package: PackageSummary
    let source: SourceInfo
    let showSource: Bool

    var body: some View {
        HStack(spacing: 8) {
            CatalogRow(package: package, source: source, showSource: showSource)
            Chevron()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            PackageIcon(urls: source.url(package.icon).map { [$0] } ?? [], section: package.section)
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
                if CompatibilityMemo.unsupported(package, systemVersion: device.systemVersion) {
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

/// A search result with the source it is from.
private struct SearchRow: Identifiable {
    let package: PackageSummary
    let info: SourceInfo

    var id: String { package.id }
}

/// Search across the packages of every source, as Sileo lays it out: a
/// field ready to type in, with Cancel, and short rows of results.
struct SearchView: View {
    @EnvironmentObject private var sources: SourcesModel
    @EnvironmentObject private var installed: InstalledPackagesModel
    @StateObject private var model = SearchModel()
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 10) {
                    let trimmed = query.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty && model.searchedQuery == trimmed && model.results.isEmpty {
                        Text("No package matches \u{201C}\(trimmed)\u{201D}.")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    } else if !trimmed.isEmpty {
                        let rows = model.results.compactMap { package in
                            sources.info(for: package.source).map { SearchRow(package: package, info: $0) }
                        }
                        if !rows.isEmpty {
                            CardRows(items: rows, dividerInset: 72) { row in
                                NavigationLink(destination: PackageView(source: row.info, identifier: row.package.package,
                                                                        summary: row.package)) {
                                    SearchResultRow(package: row.package, source: row.info,
                                                    installed: installed.version(of: row.package.package) != nil)
                                }
                                .buttonStyle(CardRowButtonStyle())
                            }
                        }
                        if model.truncated {
                            CardFooter(text: "Showing the best \(SearchModel.limit) matches. Add words to narrow the search.")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .background(WallBackground())
            // The title is part of the header above the field, which stays in
            // place while the results scroll under it.
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("")
                        .accessibilityHidden(true)
                }
            }
            .systemButton()
            .task(id: "\(sources.indexGeneration) \(query)") {
                await model.search(query, store: sources.store)
            }
            .onAppear {
                // Opening Search puts the cursor in the field, as in Sileo.
                guard query.isEmpty else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true }
            }
        }
        .navigationViewStyle(.stack)
    }

    /// The title with the count beside it, and the field.
    private var header: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Search")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text(count)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            searchField
        }
        .padding(.bottom, 8)
        .background(Palette.canvas)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                TextField("Search for Packages", text: $query)
                    .focused($focused)
                    .submitLabel(.search)
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.never)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glassSurface(cornerRadius: 12, inset: true)
            if focused || !query.isEmpty {
                Button("Cancel") {
                    query = ""
                    focused = false
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: focused || !query.isEmpty)
        .padding(.horizontal, 16)
    }

    /// How much there is to search, for the top of the screen.
    private var count: String {
        guard model.totalPackages > 0 else { return "" }
        let sourceCount = sources.rows.count
        return "\(model.totalPackages.formatted()) packages · \(sourceCount) \(sourceCount == 1 ? "source" : "sources")"
    }
}

/// A search result, short as in Sileo: the icon, with a check when the
/// package is installed; the name; the author, version and source; one line
/// of the summary; and, when it does not run on this iOS, a red mark.
private struct SearchResultRow: View {
    let package: PackageSummary
    let source: SourceInfo
    let installed: Bool
    @Environment(\.device) private var device

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PackageIcon(urls: source.url(package.icon).map { [$0] } ?? [], section: package.section, size: 44)
                .overlay(alignment: .bottomTrailing) {
                    if installed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.green)
                            .background(Circle().fill(Palette.canvas).padding(2))
                            .offset(x: 5, y: 5)
                            .accessibilityHidden(true)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(package.displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if package.isPaid {
                        PaidBadge()
                    }
                }
                Text([package.displayAuthor, package.version, source.title].compactMap { $0 }.joined(separator: " • "))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let summary = package.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if CompatibilityMemo.unsupported(package, systemVersion: device.systemVersion) {
                    Label("Not for iOS \(device.systemVersion)", systemImage: "xmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.red)
                        .padding(.top, 1)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityValue(installed ? "Installed" : "")
    }
}

/// Whether packages are made for another iOS, worked out once per package
/// version: rows ask again each time they appear while scrolling, and the
/// check reads names and summaries with regular expressions.
@MainActor
enum CompatibilityMemo {
    private static var verdicts: [String: Bool] = [:]

    static func unsupported(_ package: PackageSummary, systemVersion: String) -> Bool {
        let key = "\(package.id)\n\(package.version)\n\(systemVersion)"
        if let known = verdicts[key] {
            return known
        }
        if verdicts.count > 20_000 {
            verdicts.removeAll()
        }
        let verdict = package.compatibility(systemVersion: systemVersion).verdict == .unsupported
        verdicts[key] = verdict
        return verdict
    }
}
