// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The Featured tab: the banners every source publishes, with equal
/// standing, the updates for installed packages, and the packages sources
/// added or updated since Codling first read them.
@MainActor
final class FeaturedModel: ObservableObject {
    struct Item: Identifiable {
        let id: Int
        let banner: FeaturedBanners.Banner
        let source: SourceInfo
        /// The banner's package, when the source has it.
        let package: PackageSummary?
    }

    @Published private(set) var banners: [Item] = []
    @Published private(set) var arrivals: [IndexStore.Arrival] = []
    @Published private(set) var updates: [PackageSummary] = []
    @Published private(set) var loaded = false

    static let arrivalLimit = 60

    func load(sources: SourcesModel, installed: [String: String], reloadBanners: Bool) async {
        guard let store = sources.store else { return }

        // What the index holds shows at once; the banners come from the
        // sources over the network, and follow.
        arrivals = (try? await store.arrivals(limit: Self.arrivalLimit)) ?? []
        let offers = (try? await store.offers(ofAny: Array(installed.keys))) ?? []
        updates = AvailableUpdates.find(installed: installed, offers: offers)
        loaded = true

        let infos = sources.rows.compactMap { sources.info(for: $0.id) }
        // Every source's banners, read at the same time.
        let fetched = await withTaskGroup(of: (Int, FeaturedBanners?).self) { group in
            for (index, info) in infos.enumerated() {
                group.addTask { (index, await FeaturedStore.shared.banners(for: info.source, reload: reloadBanners)) }
            }
            var results: [Int: FeaturedBanners] = [:]
            for await (index, banners) in group {
                results[index] = banners
            }
            return results
        }
        guard !Task.isCancelled else { return }

        // A random order of sources each time, then one banner from each in
        // turn: no source is always first.
        var lists: [[(FeaturedBanners.Banner, SourceInfo)]] = []
        for index in infos.indices.shuffled() {
            guard let featured = fetched[index] else { continue }
            lists.append(featured.banners.map { ($0, infos[index]) })
        }
        var items: [Item] = []
        for (offset, entry) in FeaturedMix.interleave(lists).enumerated() {
            var package: PackageSummary?
            if let identifier = entry.0.package {
                package = try? await store.newest(of: identifier, source: entry.1.id)
            }
            items.append(Item(id: offset, banner: entry.0, source: entry.1, package: package))
        }
        banners = items
    }
}

struct PackageCategory: Identifiable {
    let name: String
    let words: [String]

    var id: String { name }

    static let all = [
        PackageCategory(name: "Tweaks", words: ["tweak"]),
        PackageCategory(name: "Themes", words: ["theme"]),
        PackageCategory(name: "Development", words: ["devel"]),
    ]
}

struct FeaturedView: View {
    let environment: RuntimeEnvironment
    @EnvironmentObject private var sources: SourcesModel
    @EnvironmentObject private var installed: InstalledPackagesModel
    @StateObject private var model = FeaturedModel()
    @EnvironmentObject private var devicePanel: DeviceInfoPanel

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    WelcomeCard()

                    if !model.banners.isEmpty {
                        CardHeading(title: "Featured Tweaks", symbol: "star.fill")
                            .padding(.top, 6)
                        FeaturedCarousel(items: model.banners)
                            .padding(.horizontal, -16)
                    }

                    CardHeading(title: "Browse Categories", symbol: "square.grid.2x2")
                        .padding(.top, 6)
                    Card(padding: 14) {
                        HStack(spacing: 8) {
                            ForEach(PackageCategory.all) { category in
                                NavigationLink(destination: CategoryPackagesView(category: category)) {
                                    VStack(spacing: 8) {
                                        IconTile(symbol: SectionSymbol.name(for: category.name),
                                                 color: SectionSymbol.color(for: category.name), size: 50)
                                        Text(category.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.8)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    CardHeading(title: "Updates", symbol: "arrow.down.circle")
                        .padding(.top, 6)
                    updatesCard

                    CardHeading(title: "New & Updated", symbol: "clock")
                        .padding(.top, 6)
                    arrivalsCard

                    CommunityLinksCard()
                        .padding(.top, 6)

                    Card(padding: 0) {
                        Button {
                            devicePanel.show(DeviceDetails.read(environment: environment, installed: installed))
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "iphone")
                                    .font(.title3)
                                    .foregroundColor(.accentColor)
                                    .frame(width: 28)
                                    .accessibilityHidden(true)
                                Text("Device Info")
                                    .font(.body.weight(.semibold))
                                Spacer(minLength: 8)
                                Text(DeviceModel.name(for: environment.deviceModel))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Chevron()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(CardRowButtonStyle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Featured")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The welcome card is the page's title.
                ToolbarItem(placement: .principal) {
                    Text("")
                        .accessibilityHidden(true)
                }
            }
            .systemButton()
            .refreshable {
                await sources.refresh(force: false)
                await model.load(sources: sources, installed: installed.versions, reloadBanners: true)
            }
            .task(id: "\(sources.indexGeneration) \(installed.versions.count)") {
                await model.load(sources: sources, installed: installed.versions, reloadBanners: false)
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var updatesCard: some View {
        let rows = model.updates.compactMap { package in
            sources.info(for: package.source).map { UpdateRow(package: package, info: $0) }
        }
        if rows.isEmpty {
            Card(padding: 14) {
                Text(model.loaded ? "Everything installed is up to date with your sources." : "Loading")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            CardRows(items: rows, dividerInset: 72) { row in
                NavigationLink(destination: PackageView(source: row.info, identifier: row.package.package, summary: row.package)) {
                    CompactPackageRow(package: row.package, source: row.info,
                                      status: installed.version(of: row.package.package)
                                          .map { "Installed \($0), \(row.package.version) available" } ?? "",
                                      statusColor: .blue)
                }
                .buttonStyle(CardRowButtonStyle())
            }
        }
    }

    @ViewBuilder
    private var arrivalsCard: some View {
        let rows = model.arrivals.compactMap { arrival in
            sources.info(for: arrival.package.source).map { ArrivalRow(arrival: arrival, info: $0) }
        }
        if rows.isEmpty {
            Card(padding: 14) {
                Text(model.loaded ? emptyText : "Loading")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Card(padding: 0) {
                ForEach(ArrivalDay.group(rows)) { day in
                    Text(day.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                    Divider()
                        .padding(.leading, 16)
                    DividedRows(items: day.rows, dividerInset: 72) { row in
                        NavigationLink(destination: PackageView(source: row.info, identifier: row.arrival.package.package,
                                                                summary: row.arrival.package)) {
                            CompactPackageRow(package: row.arrival.package, source: row.info,
                                              status: row.arrival.updated
                                                  ? "Updated \(row.arrival.date.formatted(.relative(presentation: .named)))"
                                                  : "New",
                                              statusColor: row.arrival.updated ? .blue : .green)
                        }
                        .buttonStyle(CardRowButtonStyle())
                    }
                }
            }
        }
    }

    private var emptyText: String {
        "Packages your sources add or update show here, from the next refresh on. Pull down to refresh."
    }
}

/// A package in a short row: its icon, name and version, one line of its
/// summary, and a status line.
private struct CompactPackageRow: View {
    let package: PackageSummary
    let source: SourceInfo
    let status: String
    let statusColor: Color

    var body: some View {
        HStack(spacing: 12) {
            PackageIcon(urls: source.url(package.icon).map { [$0] } ?? [], section: package.section, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(package.displayName)
                        .font(.body.weight(.semibold))
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
                        .lineLimit(1)
                }
                if !status.isEmpty {
                    Text(status)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(statusColor)
                }
            }
            Chevron()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// An installed package's newer version, with the source it is from.
private struct UpdateRow: Identifiable {
    let package: PackageSummary
    let info: SourceInfo

    var id: String { package.id }
}

/// A new or updated package with the source it is from.
struct ArrivalRow: Identifiable {
    let arrival: IndexStore.Arrival
    let info: SourceInfo

    var id: String { arrival.id }
}

/// The arrivals of one day: Today, Yesterday, or the date.
struct ArrivalDay: Identifiable {
    let title: String
    let rows: [ArrivalRow]

    var id: String { title }

    static func group(_ rows: [ArrivalRow], calendar: Calendar = .current, now: Date = Date()) -> [ArrivalDay] {
        var days: [ArrivalDay] = []
        for row in rows {
            let title: String
            if calendar.isDate(row.arrival.date, inSameDayAs: now) {
                title = "Today"
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                      calendar.isDate(row.arrival.date, inSameDayAs: yesterday) {
                title = "Yesterday"
            } else {
                title = row.arrival.date.formatted(date: .abbreviated, time: .omitted)
            }
            if let last = days.last, last.title == title {
                days[days.count - 1] = ArrivalDay(title: title, rows: last.rows + [row])
            } else {
                days.append(ArrivalDay(title: title, rows: [row]))
            }
        }
        return days
    }
}

/// The top of the Featured tab.
private struct WelcomeCard: View {
    var body: some View {
        Card(padding: 16) {
            HStack(spacing: 14) {
                Image("CodlingIcon")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Welcome to")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.secondary)
                    Text("Codling")
                        .font(.largeTitle.bold())
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Codling's own pages elsewhere. A link shows only once it has an
/// address; until then the card does not show.
private struct CommunityLinksCard: View {
    struct Entry: Identifiable {
        let title: String
        let symbol: String
        let url: URL?

        var id: String { title }
    }

    static let links = [
        Entry(title: "Twitter", symbol: "at", url: nil),
        Entry(title: "Support", symbol: "headphones", url: nil),
        Entry(title: "Website", symbol: "globe", url: nil),
    ]

    @Environment(\.openURL) private var openURL

    var body: some View {
        let shown = Self.links.filter { $0.url != nil }
        if !shown.isEmpty {
            Card(padding: 0) {
                HStack(spacing: 0) {
                    ForEach(shown) { link in
                        if link.id != shown.first?.id {
                            Divider()
                                .frame(height: 24)
                        }
                        Button {
                            if let url = link.url {
                                openURL(url)
                            }
                        } label: {
                            Label(link.title, systemImage: link.symbol)
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                        }
                        .buttonStyle(CardRowButtonStyle())
                    }
                }
            }
        }
    }
}

/// The packages of one category, from every source.
struct CategoryPackagesView: View {
    let category: PackageCategory
    @EnvironmentObject private var sources: SourcesModel
    @State private var packages: [PackageSummary]?
    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let packages {
                    let shown = filtered(packages)
                    let rows = shown.compactMap { package in
                        sources.info(for: package.source).map { CategoryRow(package: package, info: $0) }
                    }
                    if !rows.isEmpty {
                        CardRows(items: rows, dividerInset: 72) { row in
                            NavigationLink(destination: PackageView(source: row.info, identifier: row.package.package,
                                                                    summary: row.package)) {
                                CatalogCardRow(package: row.package, source: row.info, showSource: true)
                            }
                            .buttonStyle(CardRowButtonStyle())
                        }
                    }
                    CardFooter(text: shown.count == packages.count
                               ? "\(packages.count.formatted()) packages from your sources"
                               : "\(shown.count.formatted()) of \(packages.count.formatted()) packages")
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(32)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .searchable(text: $query, prompt: "Filter by name, author or identifier")
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sources.indexGeneration) {
            packages = (try? await sources.store?.packages(inSectionsWith: category.words)) ?? []
        }
    }

    private struct CategoryRow: Identifiable {
        let package: PackageSummary
        let info: SourceInfo

        var id: String { package.id }
    }

    private func filtered(_ packages: [PackageSummary]) -> [PackageSummary] {
        let words = PackageCatalog.searchWords(query)
        guard !words.isEmpty else { return packages }
        return packages.filter { package in
            let fields = [package.displayName, package.package, package.displayAuthor ?? "", package.summary ?? ""]
                .map { $0.lowercased() }
            return words.allSatisfy { word in fields.contains { $0.contains(word) } }
        }
    }
}

/// The banners side by side, two to a screen, each with its source's name.
private struct FeaturedCarousel: View {
    let items: [FeaturedModel.Item]

    var body: some View {
        let width = ((min(UIScreen.main.bounds.width, 500) - 32 - 10) / 2).rounded(.down)
        let size = CGSize(width: width, height: (width * 148 / 263).rounded())
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        if let package = item.package {
                            NavigationLink(destination: PackageView(source: item.source, identifier: package.package, summary: package)) {
                                BannerView(banner: item.banner, size: size, cornerRadius: 14)
                            }
                            .buttonStyle(.plain)
                        } else {
                            BannerView(banner: item.banner, size: size, cornerRadius: 14)
                        }
                        Text(item.source.title)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .padding(.leading, 4)
                    }
                    .frame(width: size.width)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }
}
