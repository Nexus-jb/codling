// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The sources apt reads, and the state of their last refresh.
@MainActor
final class SourcesModel: ObservableObject {
    enum Activity: Equatable {
        case idle
        case waiting
        case refreshing
    }

    struct Row: Identifiable {
        let source: Source
        var activity: Activity = .idle
        var outcome: RefreshOutcome?
        var stored: StoredSource?

        var id: String { source.id }

        var title: String {
            outcome?.label ?? stored?.label ?? source.host
        }

        var packageCount: Int? {
            outcome?.packageCount ?? stored?.packageCount
        }

        var signature: Signature? {
            outcome?.signature ?? stored?.signature.flatMap(Signature.init(stored:))
        }

        var warnings: [String] {
            outcome?.warnings ?? (stored?.warnings ?? "").split(separator: "\n").map(String.init)
        }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var setupError: String?
    @Published private(set) var lastRefresh: (date: Date, seconds: Double, packages: Int)?
    /// Goes up after every refresh, so that lists read the index again.
    @Published private(set) var indexGeneration = 0

    private let environment: RuntimeEnvironment
    private var refresher: SourceRefresher?
    /// The package index, once the sources have been read.
    private(set) var store: IndexStore?
    private var refreshedThisLaunch = false

    /// How many sources download at once.
    private let parallelism = 6

    init(environment: RuntimeEnvironment) {
        self.environment = environment
    }

    var refreshing: Int { rows.filter { $0.activity == .refreshing }.count }
    var finished: Int { rows.filter { $0.activity == .idle && $0.outcome != nil }.count }

    /// Reads the sources and what the index remembers of them, then
    /// refreshes them when a refresh is due (refreshIsDue), once per launch.
    func start() async {
        await load()
        // A default source added just now has nothing in the index yet.
        if !refreshedThisLaunch, refreshIsDue || addedSourcesThisLaunch {
            refreshedThisLaunch = true
            await refresh(force: false)
        }
    }

    /// Reads the sources and what the index remembers of them, without
    /// refreshing.
    func load() async {
        if refresher == nil {
            prepare()
        }
        guard let store else { return }
        await addDefaultSourcesOnce()
        for index in rows.indices {
            rows[index].stored = try? await store.source(id: rows[index].id)
        }
    }

    /// How long a refresh counts: opening Codling again within it shows the
    /// index as it is, without refreshing.
    static let refreshInterval: TimeInterval = 30 * 60
    private static let refreshedAtKey = "SourcesRefreshedAt"

    /// Whether the sources were ever refreshed on this device.
    static var refreshedBefore: Bool {
        UserDefaults.standard.object(forKey: refreshedAtKey) != nil
    }

    /// Whether the index holds packages, so that Codling can open on it
    /// while the sources refresh behind it.
    var hasIndex: Bool {
        rows.contains { ($0.stored?.packageCount ?? 0) > 0 }
    }

    /// Whether the sources were last refreshed longer ago than
    /// refreshInterval, or never.
    var refreshIsDue: Bool {
        guard let date = UserDefaults.standard.object(forKey: Self.refreshedAtKey) as? Date else { return true }
        let age = Date().timeIntervalSince(date)
        return age < 0 || age >= Self.refreshInterval
    }

    /// The sources Codling comes with: Nexus, Havoc and Chariz. The
    /// jailbreak brings its own source, which Codling does not add.
    static let defaultSources = ["https://repo.nexusjb.com/", "https://havoc.app/", "https://repo.chariz.com/"]
    /// Whether a default source was added on this launch.
    private var addedSourcesThisLaunch = false

    /// The key that records that a default source was added. Nexus keeps
    /// the key it had when it was the only one.
    private static func addedKey(for uri: String) -> String {
        uri == defaultSources[0] ? "AddedDefaultSource" : "AddedDefaultSource " + uri
    }

    /// Adds each default source once. After one is in apt's lists, Codling
    /// remembers that and never adds it again, so it stays gone when the
    /// person removes it, as with any source but the jailbreak's own. When
    /// the helper cannot add it, the next launch tries again.
    private func addDefaultSourcesOnce() async {
        let defaults = UserDefaults.standard
        var added = false
        for uri in Self.defaultSources where !defaults.bool(forKey: Self.addedKey(for: uri)) {
            if existing(uri: uri) != nil {
                defaults.set(true, forKey: Self.addedKey(for: uri))
                continue
            }
            let result = await Task.detached(priority: .userInitiated) { RootHelper.addSource(uri) }.value
            if case .success = result {
                defaults.set(true, forKey: Self.addedKey(for: uri))
                added = true
            }
        }
        if added {
            addedSourcesThisLaunch = true
            reloadSources()
        }
    }

    private func prepare() {
        guard let root = environment.jailbreakRoot else {
            setupError = "Codling could not find the jailbreak, so it cannot read the sources."
            return
        }
        let fileManager = FileManager.default
        do {
            let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
                .appendingPathComponent("com.nexusjb.codling", isDirectory: true)
            let caches = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("com.nexusjb.codling", isDirectory: true)
            for directory in [support, caches] {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let store = try IndexStore(path: support.appendingPathComponent("index.sqlite").path)
            self.store = store
            refresher = SourceRefresher(
                jailbreakRoot: root, architecture: environment.architecture, store: store,
                signatures: SignatureCheck(jailbreakRoot: root, workDirectory: caches),
                listsDirectory: caches.appendingPathComponent("lists", isDirectory: true),
                session: SourceRefresher.makeSession(version: environment.version, model: environment.deviceModel,
                                                     systemVersion: environment.systemVersion))
        } catch let error as IndexStoreError {
            setupError = error.message
            return
        } catch {
            setupError = "Codling could not prepare its index: \(error.localizedDescription)"
            return
        }
        let sources = SourceList.read(aptDirectory: root + "/etc/apt")
        rows = sources.map { Row(source: $0) }.sorted {
            $0.source.host.localizedCaseInsensitiveCompare($1.source.host) == .orderedAscending
        }
        if rows.isEmpty {
            setupError = "apt has no sources in \(root)/etc/apt."
        }
    }

    /// Refreshes every source, several at a time; each row updates as its
    /// source finishes.
    func refresh(force: Bool) async {
        guard !isRefreshing, let refresher, let store else { return }
        isRefreshing = true
        let started = Date()
        for index in rows.indices {
            rows[index].activity = .waiting
        }
        let sources = rows.map(\.source)
        let parallelism = self.parallelism
        await withTaskGroup(of: (String, RefreshOutcome).self) { group in
            var next = 0
            var running = 0
            while next < sources.count || running > 0 {
                while running < parallelism && next < sources.count {
                    let source = sources[next]
                    next += 1
                    running += 1
                    await self.setActivity(.refreshing, for: source.id)
                    group.addTask { (source.id, await refresher.refresh(source, force: force)) }
                }
                guard let (id, outcome) = await group.next() else { break }
                running -= 1
                await self.finish(id: id, outcome: outcome)
            }
        }
        try? await store.keepOnly(ids: Set(rows.map(\.id)))
        for index in rows.indices {
            rows[index].stored = try? await store.source(id: rows[index].id)
        }
        let packages = (try? await store.packageCount()) ?? 0
        lastRefresh = (Date(), Date().timeIntervalSince(started), packages)
        UserDefaults.standard.set(Date(), forKey: Self.refreshedAtKey)
        refreshedThisLaunch = true
        indexGeneration += 1
        isRefreshing = false
    }

    /// Whether Codling added a source, to its own sources file.
    func isCodlingSource(_ source: Source) -> Bool {
        source.file.hasSuffix("/" + SourceList.codlingFileName)
    }

    /// The source already in apt's lists at the same address, whatever its
    /// scheme.
    func existing(uri: String) -> Source? {
        func place(_ text: String) -> String {
            (text.range(of: "://").map { String(text[$0.upperBound...]) } ?? text).lowercased()
        }
        return rows.first { place($0.source.uri) == place(uri) }?.source
    }

    /// What answers at a repository's address: its name, or the reason
    /// nothing usable did.
    func inspect(uri: String) async -> Result<String?, RefreshError> {
        guard let refresher else {
            return .failure(.message(setupError ?? "Codling is not ready to read sources."))
        }
        return await refresher.inspect(uri: uri)
    }

    /// Adds a flat repository through the root helper, reads apt's lists
    /// again and refreshes the new source. Returns its row, with how the
    /// refresh went, or why it was not added.
    func add(uri: String) async -> Result<Row, RefreshError> {
        let result = await Task.detached(priority: .userInitiated) { RootHelper.addSource(uri) }.value
        if case .failure(let failure) = result {
            return .failure(.message(failure.message))
        }
        reloadSources()
        guard let id = rows.first(where: { $0.source.uri == uri })?.id else {
            return .failure(.message("apt does not list \(uri) after Codling added it."))
        }
        await refresh(id: id)
        guard let row = rows.first(where: { $0.id == id }) else {
            return .failure(.message("apt does not list \(uri) after Codling added it."))
        }
        return .success(row)
    }

    /// The security check of a source's packages, against the other
    /// sources and the installed packages; nil when the index cannot be read.
    func scan(sourceID: String, installed: [String: String], essential: Set<String>) async -> [SourceScan.Finding]? {
        guard let store,
              let packages = try? await store.packages(source: sourceID),
              let others = try? await store.otherOffers(sharingPackagesWith: sourceID) else {
            return nil
        }
        let titles = Dictionary(rows.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        return await Task.detached(priority: .userInitiated) {
            SourceScan.scan(packages: packages, others: others, sourceTitles: titles, installed: installed,
                            essential: essential)
        }.value
    }

    /// Whether a source is the one the jailbreak installs and updates its
    /// own packages from. Codling does not remove it: without it, apt
    /// cannot update or repair the jailbreak's packages.
    func isJailbreakSource(_ source: Source) -> Bool {
        source.host == "procurs.us" || source.host.hasSuffix(".procurs.us")
            || source.file.hasSuffix("/procursus.sources")
    }

    /// Removes a source from whichever sources file lists it, through the
    /// root helper. Returns the reason when it fails.
    func remove(_ source: Source) async -> String? {
        guard !isJailbreakSource(source) else { return Self.jailbreakSourceNote }
        let result = await Task.detached(priority: .userInitiated) { RootHelper.removeSource(source.uri) }.value
        switch result {
        case .failure(let failure):
            return failure.message
        case .success(let change) where !change.changed:
            return "Codling did not find \(source.uri) in apt's sources files."
        case .success:
            break
        }
        reloadSources()
        if let store {
            try? await store.keepOnly(ids: Set(rows.map(\.id)))
        }
        indexGeneration += 1
        return nil
    }

    /// Reads apt's lists again, keeping what the rows already know.
    private func reloadSources() {
        guard let root = environment.jailbreakRoot else {
            return
        }
        let known = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rows = SourceList.read(aptDirectory: root + "/etc/apt").map { known[$0.id] ?? Row(source: $0) }.sorted {
            $0.source.host.localizedCaseInsensitiveCompare($1.source.host) == .orderedAscending
        }
    }

    /// Refreshes one source, as when it was just added or the person asked
    /// for it alone.
    func refresh(id: String) async {
        guard !isRefreshing, let refresher, let store,
              let row = rows.first(where: { $0.id == id }), row.activity == .idle else {
            return
        }
        let source = row.source
        setActivity(.refreshing, for: id)
        let outcome = await refresher.refresh(source, force: true)
        finish(id: id, outcome: outcome)
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].stored = try? await store.source(id: id)
        }
        indexGeneration += 1
    }

    /// What removing a source does, for its confirmation.
    static func removalNote(for source: Source) -> String {
        "Its packages stay installed. Codling stops showing its packages and their updates."
    }

    /// Why the jailbreak's own source has no Remove button.
    static let jailbreakSourceNote = "This is the jailbreak's own source, so Codling keeps it: without it, apt cannot update or repair the jailbreak's packages, and packages that need them may not install."

    /// What package pages need to know about a source.
    func info(for id: String) -> SourceInfo? {
        rows.first { $0.id == id }.map { SourceInfo(id: $0.id, title: $0.title, source: $0.source) }
    }

    private func finish(id: String, outcome: RefreshOutcome) {
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].outcome = outcome
            rows[index].activity = .idle
        }
    }

    private func setActivity(_ activity: Activity, for id: String) {
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].activity = activity
        }
    }
}
