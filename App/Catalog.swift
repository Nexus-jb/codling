// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What package pages need to know about a source.
struct SourceInfo: Equatable {
    let id: String
    let title: String
    let source: Source

    /// Where relative addresses in the source's package fields are resolved.
    var base: URL? {
        URL(string: source.uri)
    }

    var iconURLs: [URL] {
        source.repositoryFileURLs("CydiaIcon.png")
    }

    /// An http or https address from one of the source's package fields.
    func url(_ field: String?) -> URL? {
        DepictionURL.web(field, base: base)
    }
}

extension Source {
    /// Where a repository may keep a file such as CydiaIcon.png: beside its
    /// Release file, then at the top of the repository.
    func repositoryFileURLs(_ name: String) -> [URL] {
        var urls: [URL] = []
        if let directory = releaseDirectoryURL {
            urls.append(directory.appendingPathComponent(name))
        }
        if let top = URL(string: uri)?.appendingPathComponent(name), !urls.contains(top) {
            urls.append(top)
        }
        return urls
    }
}

/// Featured banners, read once per source while Codling runs.
actor FeaturedStore {
    static let shared = FeaturedStore()

    private var cache: [String: FeaturedBanners?] = [:]

    func banners(for source: Source, reload: Bool) async -> FeaturedBanners? {
        if !reload, let cached = cache[source.id] {
            return cached
        }
        var found: FeaturedBanners?
        for url in source.repositoryFileURLs("sileo-featured.json") {
            guard let data = try? await MediaLoader.shared.data(from: url) else { continue }
            if let banners = FeaturedBanners.parse(data, base: url) {
                found = banners
                break
            }
        }
        cache[source.id] = .some(found)
        return found
    }
}

struct SectionCount: Identifiable, Equatable {
    let name: String
    let count: Int

    var id: String { name }
}

/// A source's page: its packages by section, and its featured banners.
@MainActor
final class SourceDetailModel: ObservableObject {
    @Published private(set) var packages: [PackageSummary] = []
    @Published private(set) var sections: [SectionCount] = []
    @Published private(set) var featured: FeaturedBanners?
    @Published private(set) var loaded = false
    @Published private(set) var error: String?

    func load(store: IndexStore?, source: Source, reloadBanners: Bool = false) async {
        guard let store else { return }
        do {
            let packages = try await store.packages(source: source.id)
            self.packages = packages
            sections = PackageCatalog.sections(packages).map { SectionCount(name: $0.name, count: $0.count) }
            error = nil
        } catch let failure as IndexStoreError {
            error = failure.message
        } catch {
            self.error = "\(error)"
        }
        loaded = true
        featured = await FeaturedStore.shared.banners(for: source, reload: reloadBanners)
    }

    func package(_ identifier: String?) -> PackageSummary? {
        guard let identifier else { return nil }
        return packages.first { $0.package == identifier }
    }
}

/// Search across every source in the index.
@MainActor
final class SearchModel: ObservableObject {
    @Published private(set) var results: [PackageSummary] = []
    @Published private(set) var truncated = false
    @Published private(set) var searchedQuery = ""
    @Published private(set) var totalPackages = 0

    static let limit = 200

    func search(_ query: String, store: IndexStore?) async {
        guard let store else { return }
        totalPackages = (try? await store.packageCount()) ?? 0
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            truncated = false
            searchedQuery = ""
            return
        }
        // Wait for typing to pause.
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        let found = (try? await store.search(trimmed, limit: Self.limit)) ?? ([], false)
        guard !Task.isCancelled else { return }
        results = found.results
        truncated = found.truncated
        searchedQuery = trimmed
    }
}

/// A package's page: every version in its source, and its depiction.
@MainActor
final class PackageModel: ObservableObject {
    enum Depiction: Equatable {
        case absent
        case loading
        case native(NativeDepiction, base: URL)
        case web(URL)
        case failed(String)
    }

    @Published private(set) var versions: [PackageRecord] = []
    @Published private(set) var loaded = false
    @Published private(set) var depiction: Depiction = .absent

    var newest: PackageRecord? { versions.first }

    func load(store: IndexStore?, source: SourceInfo, package: String) async {
        guard let store, !loaded else { return }
        versions = (try? await store.versions(of: package, source: source.id)) ?? []
        loaded = true
        if let newest {
            await loadDepiction(newest, source: source)
        }
    }

    func reloadDepiction(source: SourceInfo) async {
        if let newest {
            await loadDepiction(newest, source: source)
        }
    }

    /// A Sileo depiction when the package has one and it can be read; else
    /// the web depiction; else none.
    private func loadDepiction(_ record: PackageRecord, source: SourceInfo) async {
        let web = source.url(record.depiction)
        guard let native = source.url(record.sileoDepiction) else {
            depiction = web.map(Depiction.web) ?? .absent
            return
        }
        depiction = .loading
        do {
            let data = try await MediaLoader.shared.data(from: native)
            let parsed = try await Task.detached(priority: .userInitiated) {
                try NativeDepiction.parse(data, base: native)
            }.value
            depiction = .native(parsed, base: native)
        } catch {
            if let web {
                depiction = .web(web)
            } else if let failure = error as? MediaLoader.LoadError {
                depiction = .failed("The description page could not be loaded. \(failure.message)")
            } else {
                depiction = .failed("The description page could not be read: it is not a valid Sileo depiction.")
            }
        }
    }
}

/// The packages that offer an identifier, for links from depictions.
@MainActor
final class PackageLookupModel: ObservableObject {
    @Published private(set) var offers: [PackageSummary] = []
    @Published private(set) var loaded = false

    func load(store: IndexStore?, identifier: String) async {
        guard let store else { return }
        offers = (try? await store.offers(of: identifier)) ?? []
        loaded = true
    }
}
