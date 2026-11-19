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
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var setupError: String?
    @Published private(set) var lastRefresh: (date: Date, seconds: Double, packages: Int)?

    private let environment: RuntimeEnvironment
    private var refresher: SourceRefresher?
    private var store: IndexStore?
    private var refreshedThisLaunch = false

    /// How many sources download at once.
    private let parallelism = 6

    init(environment: RuntimeEnvironment) {
        self.environment = environment
    }

    var refreshing: Int { rows.filter { $0.activity == .refreshing }.count }
    var finished: Int { rows.filter { $0.activity == .idle && $0.outcome != nil }.count }

    /// Reads the sources and what the index remembers of them, then refreshes
    /// once per launch.
    func start() async {
        if refresher == nil {
            prepare()
        }
        guard let store else { return }
        for index in rows.indices {
            rows[index].stored = try? await store.source(id: rows[index].id)
        }
        if !refreshedThisLaunch {
            refreshedThisLaunch = true
            await refresh(force: false)
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
        isRefreshing = false
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
