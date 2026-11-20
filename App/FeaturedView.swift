// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The Featured tab: the banners every source publishes, with equal
/// standing, and the packages sources added or updated since Codling first
/// read them.
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
    @Published private(set) var loaded = false

    static let arrivalLimit = 60

    func load(sources: SourcesModel, reloadBanners: Bool) async {
        guard let store = sources.store else { return }
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
        arrivals = (try? await store.arrivals(limit: Self.arrivalLimit)) ?? []
        loaded = true
    }
}

struct FeaturedView: View {
    @EnvironmentObject private var sources: SourcesModel
    @StateObject private var model = FeaturedModel()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 10) {
                    if !model.banners.isEmpty {
                        FeaturedCarousel(items: model.banners)
                            .padding(.horizontal, -16)
                        CardFooter(text: "Banners from every source you added, in a new order each time.")
                    }

                    CardHeading(title: "New and Updated", symbol: "sparkles")
                        .padding(.top, 8)
                    if model.arrivals.isEmpty {
                        Card {
                            Text(model.loaded ? emptyText : "Loading")
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        let rows = model.arrivals.compactMap { arrival in
                            sources.info(for: arrival.package.source).map { ArrivalRow(arrival: arrival, info: $0) }
                        }
                        CardRows(items: rows, dividerInset: 72) { row in
                            NavigationLink(destination: PackageView(source: row.info, identifier: row.arrival.package.package,
                                                                    summary: row.arrival.package)) {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        CatalogRow(package: row.arrival.package, source: row.info, showSource: true)
                                        Text("\(row.arrival.updated ? "Updated" : "New") \(row.arrival.date.formatted(.relative(presentation: .named)))")
                                            .font(.caption.weight(.semibold))
                                            .foregroundColor(row.arrival.updated ? .blue : .green)
                                            .padding(.leading, 56)
                                    }
                                    Chevron()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(CardRowButtonStyle())
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Featured")
            .systemButton()
            .refreshable {
                await sources.refresh(force: false)
                await model.load(sources: sources, reloadBanners: true)
            }
            .task(id: sources.indexGeneration) {
                await model.load(sources: sources, reloadBanners: false)
            }
        }
        .navigationViewStyle(.stack)
    }

    private var emptyText: String {
        "Packages your sources add or update show here, from the next refresh on. Pull down to refresh."
    }
}

/// A new or updated package with the source it is from.
private struct ArrivalRow: Identifiable {
    let arrival: IndexStore.Arrival
    let info: SourceInfo

    var id: String { arrival.id }
}

/// The banners side by side, all the same size, each with its source's name.
private struct FeaturedCarousel: View {
    let items: [FeaturedModel.Item]

    var body: some View {
        let width = min(UIScreen.main.bounds.width - 64, 340)
        let size = CGSize(width: width, height: (width * 148 / 263).rounded())
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        if let package = item.package {
                            NavigationLink(destination: PackageView(source: item.source, identifier: package.package, summary: package)) {
                                BannerView(banner: item.banner, size: size, cornerRadius: 12)
                            }
                            .buttonStyle(.plain)
                        } else {
                            BannerView(banner: item.banner, size: size, cornerRadius: 12)
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
            .padding(.vertical, 6)
        }
    }
}
