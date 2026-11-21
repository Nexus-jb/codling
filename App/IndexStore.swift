// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3

/// What Codling remembers about a source between refreshes.
struct StoredSource: Equatable {
    var id: String
    var label: String?
    /// Validators of the last Release or InRelease download, for a
    /// conditional request.
    var releaseETag: String?
    var releaseModified: String?
    /// SHA-256 of the Release text the index was built from.
    var releaseDigest: String?
    /// The digest of each index file the packages came from, as the Release
    /// file gave it ("path digest" lines).
    var indexDigests: String?
    var signature: String?
    var refreshed: Date?
    var packageCount: Int
    /// The warnings of the refresh that read the packages, one per line.
    var warnings: String?
}

enum IndexStoreError: Error {
    case sqlite(String)

    var message: String {
        switch self {
        case .sqlite(let detail): return "The package index could not be written: \(detail)"
        }
    }
}

/// The local package index, in SQLite: every source's packages, read once
/// at refresh and then searched without reading the indexes again.
actor IndexStore {
    private var database: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(handle)
            throw IndexStoreError.sqlite(message)
        }
        database = handle
        // The index is a cache of what the sources publish: an index from an
        // older build is dropped and read again.
        // The seen table is not a cache: it is kept, so that packages a
        // source already had are not shown as new after the index is read again.
        let version = try Self.integer(handle, "PRAGMA user_version")
        if version < Self.schemaVersion {
            try Self.execute(handle, "DROP TABLE IF EXISTS packages; DROP TABLE IF EXISTS sources;")
        }
        try Self.execute(handle, """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS sources (
                id TEXT PRIMARY KEY, label TEXT, release_etag TEXT, release_modified TEXT,
                release_digest TEXT, index_digests TEXT, signature TEXT, refreshed REAL,
                package_count INTEGER NOT NULL DEFAULT 0, warnings TEXT);
            CREATE TABLE IF NOT EXISTS packages (
                source TEXT NOT NULL, package TEXT NOT NULL, version TEXT NOT NULL, architecture TEXT,
                name TEXT, section TEXT, author TEXT, maintainer TEXT, summary TEXT, description TEXT,
                depiction TEXT, sileo_depiction TEXT, icon TEXT, filename TEXT, size INTEGER,
                sha256 TEXT, depends TEXT, tag TEXT);
            CREATE INDEX IF NOT EXISTS packages_by_source ON packages(source);
            CREATE INDEX IF NOT EXISTS packages_by_package ON packages(package);
            CREATE INDEX IF NOT EXISTS packages_by_version ON packages(source, package, version);
            CREATE TABLE IF NOT EXISTS seen (
                source TEXT NOT NULL, package TEXT NOT NULL, version TEXT NOT NULL,
                first_seen REAL NOT NULL, updated INTEGER NOT NULL,
                PRIMARY KEY (source, package, version));
            CREATE INDEX IF NOT EXISTS seen_by_time ON seen(first_seen);
            PRAGMA user_version = \(Self.schemaVersion);
            """)
    }

    /// 3: package_count counts packages rather than versions.
    /// 4: the seen table, for new and updated packages.
    private static let schemaVersion = 4

    private static func integer(_ database: OpaquePointer?, _ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw IndexStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    deinit {
        sqlite3_close(database)
    }

    func source(id: String) throws -> StoredSource? {
        let statement = try prepare("""
            SELECT label, release_etag, release_modified, release_digest, index_digests, signature,
                   refreshed, package_count, warnings FROM sources WHERE id = ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return StoredSource(id: id, label: column(statement, 0), releaseETag: column(statement, 1),
                            releaseModified: column(statement, 2), releaseDigest: column(statement, 3),
                            indexDigests: column(statement, 4), signature: column(statement, 5),
                            refreshed: sqlite3_column_type(statement, 6) == SQLITE_NULL
                                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                            packageCount: Int(sqlite3_column_int64(statement, 7)), warnings: column(statement, 8))
    }

    /// Saves a source's state and, when packages is not nil, replaces its
    /// packages, in one transaction.
    func save(_ source: StoredSource, packages: [PackageRecord]?) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            var stored = source
            if let packages {
                let delete = try prepare("DELETE FROM packages WHERE source = ?")
                bind(delete, 1, source.id)
                let deleted = sqlite3_step(delete)
                sqlite3_finalize(delete)
                guard deleted == SQLITE_DONE else { throw error() }
                let insert = try prepare("""
                    INSERT INTO packages (source, package, version, architecture, name, section, author,
                        maintainer, summary, description, depiction, sileo_depiction, icon, filename, size,
                        sha256, depends, tag) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """)
                defer { sqlite3_finalize(insert) }
                for record in packages {
                    sqlite3_reset(insert)
                    let values: [String?] = [source.id, record.package, record.version, record.architecture,
                                             record.name, record.section, record.author, record.maintainer,
                                             record.summary, record.description, record.depiction,
                                             record.sileoDepiction, record.icon, record.filename]
                    for (index, value) in values.enumerated() {
                        bind(insert, Int32(index + 1), value)
                    }
                    if let size = record.size {
                        sqlite3_bind_int64(insert, 15, size)
                    } else {
                        sqlite3_bind_null(insert, 15)
                    }
                    bind(insert, 16, record.sha256)
                    bind(insert, 17, record.depends)
                    bind(insert, 18, record.tag)
                    guard sqlite3_step(insert) == SQLITE_DONE else { throw error() }
                }
                try markSeen(source: source.id)
                // Packages, not versions: an index can list several versions of one.
                stored.packageCount = Set(packages.map(\.package)).count
            }
            let upsert = try prepare("""
                INSERT OR REPLACE INTO sources (id, label, release_etag, release_modified, release_digest,
                    index_digests, signature, refreshed, package_count, warnings) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(upsert) }
            let values: [String?] = [stored.id, stored.label, stored.releaseETag, stored.releaseModified,
                                     stored.releaseDigest, stored.indexDigests, stored.signature]
            for (index, value) in values.enumerated() {
                bind(upsert, Int32(index + 1), value)
            }
            if let refreshed = stored.refreshed {
                sqlite3_bind_double(upsert, 8, refreshed.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(upsert, 8)
            }
            sqlite3_bind_int64(upsert, 9, Int64(stored.packageCount))
            bind(upsert, 10, stored.warnings)
            guard sqlite3_step(upsert) == SQLITE_DONE else { throw error() }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Forgets the sources that are no longer in apt's lists.
    func keepOnly(ids: Set<String>) throws {
        let statement = try prepare("SELECT id FROM sources")
        var gone: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id: String = column(statement, 0), !ids.contains(id) {
                gone.append(id)
            }
        }
        sqlite3_finalize(statement)
        for id in gone {
            for sql in ["DELETE FROM packages WHERE source = ?", "DELETE FROM sources WHERE id = ?",
                        "DELETE FROM seen WHERE source = ?"] {
                let delete = try prepare(sql)
                bind(delete, 1, id)
                let result = sqlite3_step(delete)
                sqlite3_finalize(delete)
                guard result == SQLITE_DONE else { throw error() }
            }
        }
    }

    /// Records when each version of a source's packages first appeared.
    /// The first time Codling reads a source, nothing in it is new: its
    /// versions are recorded at time 0, so that only what the source adds or
    /// updates later shows as new.
    private func markSeen(source: String) throws {
        let known = try prepare("SELECT EXISTS (SELECT 1 FROM seen WHERE source = ?)")
        bind(known, 1, source)
        let hasHistory = sqlite3_step(known) == SQLITE_ROW && sqlite3_column_int64(known, 0) != 0
        sqlite3_finalize(known)

        let insert = try prepare("""
            INSERT OR IGNORE INTO seen (source, package, version, first_seen, updated)
            SELECT p.source, p.package, p.version, ?,
                   EXISTS (SELECT 1 FROM seen o WHERE o.source = p.source AND o.package = p.package)
            FROM packages p WHERE p.source = ?
            """)
        sqlite3_bind_double(insert, 1, hasHistory ? Date().timeIntervalSince1970 : 0)
        bind(insert, 2, source)
        let inserted = sqlite3_step(insert)
        sqlite3_finalize(insert)
        guard inserted == SQLITE_DONE else { throw error() }

        // Forget versions the source no longer lists.
        let prune = try prepare("""
            DELETE FROM seen WHERE source = ? AND NOT EXISTS (
                SELECT 1 FROM packages p
                WHERE p.source = seen.source AND p.package = seen.package AND p.version = seen.version)
            """)
        bind(prune, 1, source)
        let pruned = sqlite3_step(prune)
        sqlite3_finalize(prune)
        guard pruned == SQLITE_DONE else { throw error() }
    }

    /// A package version that appeared after Codling first read its source.
    struct Arrival: Identifiable, Equatable {
        let package: PackageSummary
        let date: Date
        /// True when the source had an earlier version of the package.
        let updated: Bool

        var id: String { "\(package.source) \(package.package) \(package.version)" }
    }

    /// The packages that sources added or updated, newest first, one entry
    /// for each package in each source.
    func arrivals(limit: Int) throws -> [Arrival] {
        let columns = Self.summaryColumns.split(separator: ",")
            .map { "p." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
        let statement = try prepare("""
            SELECT \(columns), s.first_seen, s.updated FROM seen s
            JOIN packages p ON p.source = s.source AND p.package = s.package AND p.version = s.version
            WHERE s.first_seen > 0 ORDER BY s.first_seen DESC LIMIT \(limit * 3)
            """)
        defer { sqlite3_finalize(statement) }
        var found: [Arrival] = []
        var shown = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW, found.count < limit {
            let package = summary(statement)
            guard shown.insert("\(package.source) \(package.package)").inserted else { continue }
            found.append(Arrival(package: package,
                                 date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
                                 updated: sqlite3_column_int64(statement, 12) != 0))
        }
        return found
    }

    /// The newest version of each package, in each source, whose section
    /// holds any of the words, such as "tweak" for "Tweaks (iOS 15)".
    func packages(inSectionsWith words: [String]) throws -> [PackageSummary] {
        guard !words.isEmpty else { return [] }
        let condition = words.map { _ in "lower(section) LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
        let statement = try prepare("SELECT \(Self.summaryColumns) FROM packages WHERE \(condition)")
        defer { sqlite3_finalize(statement) }
        for (index, word) in words.enumerated() {
            bind(statement, Int32(index + 1), PackageCatalog.likePattern(word.lowercased()))
        }
        var rows: [PackageSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(summary(statement))
        }
        return PackageCatalog.newest(rows)
    }

    /// Every source's newest version of each of the packages.
    func offers(ofAny packages: [String]) throws -> [PackageSummary] {
        guard !packages.isEmpty else { return [] }
        try execute("CREATE TEMP TABLE IF NOT EXISTS wanted (package TEXT PRIMARY KEY)")
        try execute("DELETE FROM wanted")
        let insert = try prepare("INSERT OR IGNORE INTO wanted (package) VALUES (?)")
        for package in packages {
            sqlite3_reset(insert)
            bind(insert, 1, package)
            guard sqlite3_step(insert) == SQLITE_DONE else {
                sqlite3_finalize(insert)
                throw error()
            }
        }
        sqlite3_finalize(insert)
        let statement = try prepare("SELECT \(Self.summaryColumns) FROM packages WHERE package IN (SELECT package FROM wanted)")
        defer { sqlite3_finalize(statement) }
        var rows: [PackageSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(summary(statement))
        }
        return PackageCatalog.newest(rows)
    }

    /// The newest version of a package in one source, if the source has it.
    func newest(of package: String, source: String) throws -> PackageSummary? {
        let statement = try prepare("SELECT \(Self.summaryColumns) FROM packages WHERE source = ? AND package = ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, source)
        bind(statement, 2, package)
        var rows: [PackageSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(summary(statement))
        }
        return PackageCatalog.newest(rows).first
    }

    func packageCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM (SELECT DISTINCT source, package FROM packages)")
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    // MARK: Browsing

    private static let summaryColumns = "source, package, version, name, section, author, maintainer, summary, icon, tag, depends"

    private func summary(_ statement: OpaquePointer?) -> PackageSummary {
        PackageSummary(source: column(statement, 0) ?? "", package: column(statement, 1) ?? "",
                       version: column(statement, 2) ?? "", name: column(statement, 3), section: column(statement, 4),
                       author: column(statement, 5), maintainer: column(statement, 6), summary: column(statement, 7),
                       icon: column(statement, 8), tag: column(statement, 9), depends: column(statement, 10))
    }

    /// The newest version of each package of a source, sorted by name.
    func packages(source: String) throws -> [PackageSummary] {
        let statement = try prepare("SELECT \(Self.summaryColumns) FROM packages WHERE source = ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, source)
        var rows: [PackageSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(summary(statement))
        }
        return PackageCatalog.newest(rows)
    }

    /// Packages whose name, identifier, author or summary hold every word of
    /// the query, best matches first. truncated is true when there were more.
    func search(_ query: String, limit: Int) throws -> (results: [PackageSummary], truncated: Bool) {
        let words = PackageCatalog.searchWords(query)
        guard !words.isEmpty else { return ([], false) }
        let condition = words.map { _ in
            "(name LIKE ? ESCAPE '\\' OR package LIKE ? ESCAPE '\\' OR author LIKE ? ESCAPE '\\'"
                + " OR maintainer LIKE ? ESCAPE '\\' OR summary LIKE ? ESCAPE '\\')"
        }.joined(separator: " AND ")
        // Enough rows for every version of the best matches.
        let rowLimit = limit * 10
        let statement = try prepare("SELECT \(Self.summaryColumns) FROM packages WHERE \(condition) LIMIT \(rowLimit)")
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        for word in words {
            let pattern = PackageCatalog.likePattern(word)
            for _ in 0..<5 {
                bind(statement, index, pattern)
                index += 1
            }
        }
        var rows: [PackageSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(summary(statement))
        }
        let ranked = PackageCatalog.rank(PackageCatalog.newest(rows), query: query)
        return (Array(ranked.prefix(limit)), ranked.count > limit || rows.count == rowLimit)
    }

    /// The newest version of a package in each source that has it.
    /// The other sources' copies of a source's packages, for its security
    /// check.
    func otherOffers(sharingPackagesWith source: String) throws -> [PackageSummary] {
        let statement = try prepare("""
            SELECT \(Self.summaryColumns) FROM packages
            WHERE source != ? AND package IN (SELECT package FROM packages WHERE source = ?)
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, source)
        bind(statement, 2, source)
        var rows: [PackageSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(summary(statement))
        }
        return rows
    }

    func offers(of package: String) throws -> [PackageSummary] {
        let statement = try prepare("SELECT \(Self.summaryColumns) FROM packages WHERE package = ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, package)
        var rows: [PackageSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(summary(statement))
        }
        return PackageCatalog.newest(rows)
    }

    /// Every version of a package in one source, newest first.
    func versions(of package: String, source: String) throws -> [PackageRecord] {
        let statement = try prepare("""
            SELECT package, version, architecture, name, section, author, maintainer, description, depiction,
                   sileo_depiction, icon, filename, size, sha256, depends, tag
            FROM packages WHERE source = ? AND package = ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, source)
        bind(statement, 2, package)
        var records: [PackageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var record = PackageRecord()
            record.package = column(statement, 0) ?? ""
            record.version = column(statement, 1) ?? ""
            record.architecture = column(statement, 2) ?? ""
            record.name = column(statement, 3)
            record.section = column(statement, 4)
            record.author = column(statement, 5)
            record.maintainer = column(statement, 6)
            record.description = column(statement, 7)
            record.depiction = column(statement, 8)
            record.sileoDepiction = column(statement, 9)
            record.icon = column(statement, 10)
            record.filename = column(statement, 11)
            record.size = sqlite3_column_type(statement, 12) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 12)
            record.sha256 = column(statement, 13)
            record.depends = column(statement, 14)
            record.tag = column(statement, 15)
            records.append(record)
        }
        return records.sorted { DebianVersion($0.version) > DebianVersion($1.version) }
    }

    // MARK: SQLite

    private static func execute(_ database: OpaquePointer?, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(message)
            throw IndexStoreError.sqlite(text)
        }
    }

    private func execute(_ sql: String) throws {
        try Self.execute(database, sql)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw error()
        }
        return statement
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func column(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func error() -> IndexStoreError {
        .sqlite(String(cString: sqlite3_errmsg(database)))
    }
}
