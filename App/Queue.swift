// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UIKit

/// A change Codling made, kept so that it can be undone: the packages
/// before and after it, and the versions it backed up.
struct ChangeRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let title: String
    let before: [String: String]
    let after: [String: String]
    /// Package name to the version the helper backed up before the change.
    let backups: [String: String]
}

/// The changes Codling made, newest last, in Application Support.
enum ChangeHistory {
    static let limit = 20

    private static var url: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.nexusjb.codling/history.json")
    }

    static func load() -> [ChangeRecord] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ChangeRecord].self, from: data)) ?? []
    }

    static func save(_ records: [ChangeRecord]) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(Array(records.suffix(limit))).write(to: url, options: .atomic)
    }
}

/// The changes the user has asked for, and their review and application:
/// apt works out the full change, the user confirms it, the helper backs up
/// what the change removes or replaces, and then makes it. Every change is
/// recorded so that the last one can be undone.
@MainActor
final class QueueModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let operation: PackageOperation
        /// The package's name as lists show it.
        let name: String
        /// For a package the user bought: where to download it, which the
        /// review does before asking apt.
        var purchase: PurchaseRequest?

        var id: String { operation.package }
    }

    enum Phase: Equatable {
        case editing
        case preparing(String)
        /// notes: what the user should know before confirming.
        case review(AptPlan, warnings: [AptDiagnosis], notes: [String])
        /// apt could not work out the change.
        case blocked([AptDiagnosis], output: String)
        case applying(String)
        case finished(succeeded: Bool, plan: AptPlan, diagnoses: [AptDiagnosis], output: String, notes: [String])
    }

    @Published private(set) var items: [Item] = []
    /// The settings each package the review removes would leave behind.
    @Published private(set) var leftovers: [String: SettingsLeftovers] = [:]
    /// The packages whose settings the user chose to remove too.
    @Published var clearsSettings: Set<String> = []
    /// The names of the last change's packages, which a removed package
    /// no longer has among the installed ones.
    @Published private(set) var appliedNames: [String: String] = [:]
    /// Where install results go, when the user shares them.
    weak var reports: ReportsModel?
    @Published private(set) var phase: Phase = .editing
    @Published private(set) var restarting = false
    @Published private(set) var history: [ChangeRecord] = ChangeHistory.load()
    /// The title of the change the queue undoes, while it does.
    @Published private(set) var undoing: String?
    private var undoNotes: [String] = []
    /// The operations the last review asked apt about, with bought packages
    /// as their checked downloads; what apply makes.
    private var reviewed: [PackageOperation] = []
    /// Downloads bought packages; set when the app starts.
    weak var accounts: PaymentAccounts?

    // apt's lists, brought up to date in the background (AptListsFreshness).
    private var lists = AptListsFreshness()
    /// The sources apt reads, as Codling last saw them.
    private var sourceAddresses: [String] = []
    /// apt-get update under way in the background; a review waits for it.
    private var listsUpdate: Task<Void, Never>?
    /// Another update is due once the current one, or the change apt is
    /// making, is over.
    private var listsUpdateDue = false
    /// What the last apt-get update said about sources it could not read.
    private var listsWarnings: [AptDiagnosis] = []
    private static let listsUpdatedKey = "AptListsUpdatedAt"
    private static let listsSourcesKey = "AptListsSources"

    init() {
        // apt's lists outlive Codling: a review soon after it opens again
        // can use them as they are.
        let defaults = UserDefaults.standard
        if let date = defaults.object(forKey: Self.listsUpdatedKey) as? Date,
           let sources = defaults.stringArray(forKey: Self.listsSourcesKey) {
            lists.recordUpdate(at: date, sources: sources)
        }
    }

    var lastChange: ChangeRecord? { history.last }

    func contains(_ package: String) -> Bool {
        items.contains { $0.id == package }
    }

    func operation(for package: String) -> PackageOperation? {
        items.first { $0.id == package }?.operation
    }

    /// Queues an operation; a package is queued once, so a new operation
    /// replaces an earlier one for the same package.
    func add(_ operation: PackageOperation, name: String, purchase: PurchaseRequest? = nil) {
        guard operation.isValid else { return }
        if undoing != nil {
            items = []
            undoing = nil
        }
        reviewed = []
        items.removeAll { $0.id == operation.package }
        items.append(Item(operation: operation, name: name, purchase: purchase))
        if case .finished = phase {
            phase = .editing
        }
    }

    /// Queues an operation from a screen outside the queue, which then opens
    /// to review it. A review on screen is of the queue before it, so the
    /// queue goes back to editing first.
    func addForReview(_ operation: PackageOperation, name: String) {
        switch phase {
        case .review, .blocked: backToEditing()
        default: break
        }
        add(operation, name: name)
    }

    /// apt is at work, so nothing more can be queued for now.
    var isBusy: Bool {
        switch phase {
        case .preparing, .applying: return true
        default: return restarting
        }
    }

    func remove(_ package: String) {
        reviewed = []
        items.removeAll { $0.id == package }
        if items.isEmpty {
            undoing = nil
        }
    }

    func remove(atOffsets offsets: IndexSet) {
        reviewed = []
        items.remove(atOffsets: offsets)
        if items.isEmpty {
            undoing = nil
        }
    }

    func backToEditing() {
        reviewed = []
        defer { updateListsInBackground() }
        if undoing != nil, case .review = phase {
            items = []
            undoing = nil
        }
        if case .blocked = phase, undoing != nil {
            items = []
            undoing = nil
        }
        phase = .editing
    }

    /// Queues what takes the device back to before the last change, and
    /// reviews it.
    func undoLastChange(names: [String: String]) async {
        guard let record = lastChange else { return }
        let plan = UndoPlanner.plan(before: record.before, after: record.after, backups: record.backups)
        undoNotes = plan.missing.isEmpty ? [] : [
            "These packages cannot be put back as they were, because no backup of them was made: "
                + plan.missing.map { names[$0] ?? $0 }.joined(separator: ", ") + ".",
        ]
        items = plan.operations.filter(\.isValid).map { Item(operation: $0, name: names[$0.package] ?? $0.package) }
        undoing = record.title
        if items.isEmpty {
            phase = .review(AptPlan(), warnings: [], notes: undoNotes)
            return
        }
        await review()
    }

    // MARK: apt's lists

    /// The sources apt reads, as Codling found them at launch.
    func sourcesKnown(_ addresses: [String]) {
        sourceAddresses = addresses.sorted()
    }

    /// Codling refreshed, added or removed sources: apt's lists are brought
    /// up to date in the background, so that a review need not wait.
    func sourcesChanged(_ addresses: [String]) {
        sourceAddresses = addresses.sorted()
        listsUpdateDue = true
        updateListsInBackground()
    }

    /// Starts the update that is due, unless one is under way or the queue is
    /// being reviewed or applied: apt's lists stay as the review read them,
    /// and apt-get holds apt's lock. It starts after them.
    private func updateListsInBackground() {
        guard listsUpdateDue, listsUpdate == nil else { return }
        switch phase {
        case .preparing, .review, .applying:
            return
        case .editing, .blocked, .finished:
            break
        }
        listsUpdate = Task {
            while listsUpdateDue {
                listsUpdateDue = false
                _ = await updateListsNow()
            }
            listsUpdate = nil
        }
    }

    /// Runs apt-get update. Sources that could not be read keep their last
    /// lists, and their warnings show in the review. Returns the helper's
    /// failure when apt could not run at all.
    private func updateListsNow() async -> RootHelper.Failure? {
        let sources = sourceAddresses
        switch await Task.detached(priority: .userInitiated, operation: { RootHelper.updateLists() }).value {
        case .failure(let failure):
            return failure
        case .success(let result):
            listsWarnings = result.status == 0 ? [] : AptDiagnostics.diagnose(result.output)
            let date = Date()
            lists.recordUpdate(at: date, sources: sources)
            UserDefaults.standard.set(date, forKey: Self.listsUpdatedKey)
            UserDefaults.standard.set(lists.sources, forKey: Self.listsSourcesKey)
            return nil
        }
    }

    // MARK: Review and apply

    /// Downloads the packages the user bought, then asks apt what the queue
    /// would do. apt's lists are updated first only when they are not fresh,
    /// or when apt does not know a package the queue names.
    func review() async {
        let queued = items
        guard !queued.isEmpty else { return }
        reviewed = []
        defer { updateListsInBackground() }
        if let running = listsUpdate {
            phase = .preparing("Updating apt's package lists")
            await running.value
        }
        var updated = false
        if !lists.isFresh(now: Date(), sources: sourceAddresses) {
            phase = .preparing("Updating apt's package lists")
            if let failure = await updateListsNow() {
                phase = .blocked([], output: failure.message)
                return
            }
            updated = true
        }
        // Bought packages come from their provider's single-use address,
        // after apt's lists are fresh, as the helper checks each download
        // against the hash they list.
        var operations: [PackageOperation] = []
        for item in queued {
            guard let purchase = item.purchase, case .install(let package) = item.operation else {
                operations.append(item.operation)
                continue
            }
            phase = .preparing("Downloading \(item.name) from \(purchase.providerName)")
            do {
                guard let accounts else {
                    throw PaymentProvider.Failure(message: "Codling cannot download bought packages right now.")
                }
                do {
                    try await accounts.fetch(package: package, name: item.name, request: purchase)
                } catch where !updated {
                    // The helper checks the download against apt's lists,
                    // which may not have this version yet.
                    phase = .preparing("Updating apt's package lists")
                    if let failure = await updateListsNow() {
                        throw PaymentProvider.Failure(message: failure.message)
                    }
                    updated = true
                    phase = .preparing("Downloading \(item.name) from \(purchase.providerName)")
                    try await accounts.fetch(package: package, name: item.name, request: purchase)
                }
                operations.append(.purchased(package, version: purchase.version))
            } catch {
                let message = (error as? PaymentProvider.Failure)?.message ?? "\(error)"
                phase = .blocked([], output: "\(item.name) could not be downloaded: \(message)")
                return
            }
        }

        phase = .preparing("Working out the changes")
        let planned = operations
        var simulation = await Task.detached(priority: .userInitiated) { RootHelper.simulate(planned) }.value
        if !updated, case .success(let result) = simulation, result.status != 0,
           AptListsFreshness.mentionsMissingPackage(result.output) {
            // A source published it after apt's lists were read.
            phase = .preparing("Updating apt's package lists")
            if let failure = await updateListsNow() {
                phase = .blocked([], output: failure.message)
                return
            }
            phase = .preparing("Working out the changes")
            simulation = await Task.detached(priority: .userInitiated) { RootHelper.simulate(planned) }.value
        }
        show(simulation, operations: planned, notes: undoing == nil ? [] : undoNotes)
    }

    /// The review, or why apt cannot make the change.
    private func show(_ simulation: Result<RootHelper.CommandResult, RootHelper.Failure>, operations: [PackageOperation],
                      notes: [String]) {
        switch simulation {
        case .failure(let failure):
            phase = .blocked([], output: failure.message)
        case .success(let result) where result.status != 0:
            phase = .blocked(AptDiagnostics.diagnose(result.output), output: result.output)
        case .success(let result):
            reviewed = operations
            phase = .review(AptPlan.parse(result.output), warnings: listsWarnings, notes: notes)
        }
    }

    /// Reads, before anything is removed, the settings the plan's removals
    /// would leave behind. A choice for a package the plan no longer
    /// removes is dropped.
    func findSettings(for plan: AptPlan, statusPath: String?, installed: Set<String>) async {
        let removed = plan.changes(.remove).map(\.package)
        let found = await Task.detached(priority: .userInitiated) {
            SettingsCleanup.find(packages: removed, statusPath: statusPath, installed: installed)
        }.value
        leftovers = found
        clearsSettings = clearsSettings.filter { found[$0]?.removable.isEmpty == false }
    }

    /// Removes the settings the user chose, for packages the change did
    /// remove, and says what happened.
    private func removeChosenSettings(stillInstalled: Set<String>, names: [String: String]) -> [String] {
        var notes: [String] = []
        for package in clearsSettings.sorted() where !stillInstalled.contains(package) {
            guard let settings = leftovers[package] else { continue }
            let name = names[package] ?? package
            let failures = settings.removable.compactMap { domain in
                SettingsCleanup.remove(domain).map { "\(domain.name): \($0)" }
            }
            if failures.isEmpty {
                notes.append("Removed the settings of \(name).")
            } else {
                notes.append("Some settings of \(name) could not be removed: \(failures.joined(separator: "; ")).")
            }
        }
        clearsSettings = []
        leftovers = [:]
        return notes
    }

    /// Backs up what the change removes or replaces, makes the reviewed
    /// change, and records it.
    func apply(_ plan: AptPlan, installed: InstalledPackagesModel, statusPath: String?, names: [String: String]) async {
        let operations = reviewed.isEmpty ? items.map(\.operation) : reviewed
        appliedNames = names
        UIApplication.shared.isIdleTimerDisabled = true
        // Asks iOS for time to finish if the user leaves Codling meanwhile.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Apply package changes")
        defer {
            UIApplication.shared.endBackgroundTask(background)
            UIApplication.shared.isIdleTimerDisabled = false
        }

        if let running = listsUpdate {
            phase = .applying("Waiting for apt's package lists")
            await running.value
        }

        // apt checks signatures only when it really installs, not in the
        // review's simulation. Downloading first runs that check before
        // anything changes, and leaves the archives in apt's cache for the
        // change itself.
        phase = .applying("Downloading the packages")
        // The user saw these packages flagged and confirmed them anyway.
        let consented = !plan.unauthenticated.isEmpty
        let download = await Task.detached(priority: .userInitiated) {
            RootHelper.download(operations, trustUnsigned: consented, allowRemovals: plan.removesPackages)
        }.value
        switch download {
        case .failure(let failure):
            phase = .finished(succeeded: false, plan: plan, diagnoses: [], output: failure.message, notes: [])
            updateListsInBackground()
            return
        case .success(let result) where result.status != 0:
            let unsigned = AptPlan.parse(result.output).unauthenticated
            if !unsigned.isEmpty && !consented {
                // Nothing was downloaded or changed: the user decides.
                var flagged = plan
                flagged.unauthenticated = unsigned
                phase = .review(flagged, warnings: listsWarnings,
                                notes: ["apt cannot verify some of these packages, because their sources are not signed. Confirm again to install them anyway."])
                return
            }
            if AptListsFreshness.mentionsFailedDownload(result.output) {
                lists.invalidate()
                UserDefaults.standard.removeObject(forKey: Self.listsUpdatedKey)
                phase = .preparing("A source changed its files. Updating apt's package lists")
                if let failure = await updateListsNow() {
                    phase = .blocked([], output: failure.message)
                } else {
                    phase = .preparing("Working out the changes")
                    let simulation = await Task.detached(priority: .userInitiated) { RootHelper.simulate(operations) }.value
                    show(simulation, operations: operations,
                         notes: ["A source changed its files while you reviewed, so Codling read them again. Nothing was installed yet; confirm again."])
                }
                updateListsInBackground()
                return
            }
            phase = .finished(succeeded: false, plan: plan, diagnoses: AptDiagnostics.diagnose(result.output),
                              output: result.output, notes: [])
            updateListsInBackground()
            return
        default:
            break
        }

        phase = .applying("Reading the installed packages")
        await installed.load(statusPath: statusPath)
        let before = installed.versions

        var notes: [String] = []
        var backups: [String: String] = [:]
        let replaced = plan.changes.filter { $0.kind != .install }.map(\.package).filter { before[$0] != nil }
        if !replaced.isEmpty {
            phase = .applying("Backing up what the change removes or replaces, for undo")
            let report = await Task.detached(priority: .userInitiated) { RootHelper.backup(replaced) }.value
            switch report {
            case .failure(let failure):
                notes.append("No backups could be made, so undo cannot put back what this change removed or replaced: \(failure.message)")
            case .success(let report):
                for entry in report.backups {
                    if entry.file != nil {
                        backups[entry.package] = entry.version
                    } else {
                        notes.append("Undo cannot put back \(names[entry.package] ?? entry.package): \(entry.error ?? "its backup failed").")
                    }
                }
            }
        }

        phase = .applying("Applying the changes. This can take a few minutes; keep Codling open.")
        let result = await Task.detached(priority: .userInitiated) {
            RootHelper.apply(operations, trustUnsigned: !plan.unauthenticated.isEmpty, allowRemovals: plan.removesPackages)
        }.value
        await installed.load(statusPath: statusPath)
        let after = installed.versions

        // Even a change that failed half way is recorded, so that undo can
        // take back what it did.
        if after != before {
            let title = undoing.map(Self.undoTitle) ?? Self.title(plan, names: names)
            history.append(ChangeRecord(id: UUID(), date: Date(), title: title, before: before, after: after, backups: backups))
            history = Array(history.suffix(ChangeHistory.limit))
            ChangeHistory.save(history)
        }

        if case .success(let command) = result, command.status != 0, after == before,
           AptListsFreshness.mentionsFailedDownload(command.output) {
            // A source replaced a file after apt's lists were read. apt
            // downloads before it changes anything, so nothing changed: read
            // the lists again and review the change again.
            lists.invalidate()
            UserDefaults.standard.removeObject(forKey: Self.listsUpdatedKey)
            phase = .preparing("A source changed its files. Updating apt's package lists")
            if let failure = await updateListsNow() {
                phase = .blocked([], output: failure.message)
            } else {
                phase = .preparing("Working out the changes")
                let simulation = await Task.detached(priority: .userInitiated) { RootHelper.simulate(operations) }.value
                show(simulation, operations: operations,
                     notes: ["A source changed its files while you reviewed, so Codling read them again. Nothing was installed yet; confirm again."])
            }
            updateListsInBackground()
            return
        }

        switch result {
        case .failure(let failure):
            phase = .finished(succeeded: false, plan: plan, diagnoses: [], output: failure.message, notes: notes)
        case .success(let command):
            let succeeded = command.status == 0
            let diagnoses = succeeded ? [] : AptDiagnostics.diagnose(command.output)
            if succeeded {
                notes += removeChosenSettings(stillInstalled: Set(after.keys), names: names)
            }
            phase = .finished(succeeded: succeeded, plan: plan, diagnoses: diagnoses, output: command.output, notes: notes)
            reports?.sendInstallResults(plan: plan, succeeded: succeeded, diagnoses: diagnoses)
            if succeeded {
                items = []
                undoing = nil
                reviewed = []
            }
        }
        updateListsInBackground()
    }

    /// Undoing a change titles the undo after it; undoing an undo makes
    /// the first change again, so it takes that change's title back.
    static func undoTitle(_ undone: String) -> String {
        let prefix = "Undo of: "
        return undone.hasPrefix(prefix) ? String(undone.dropFirst(prefix.count)) : prefix + undone
    }

    /// "Installed jq and 2 more", from what the plan changed.
    static func title(_ plan: AptPlan, names: [String: String]) -> String {
        guard let first = plan.changes.first else { return "No change" }
        let verb: String
        switch first.kind {
        case .install: verb = "Installed"
        case .upgrade: verb = "Upgraded"
        case .reinstall: verb = "Reinstalled"
        case .downgrade: verb = "Downgraded"
        case .remove: verb = "Removed"
        }
        let name = names[first.package] ?? first.package
        let others = plan.changes.count - 1
        return others == 0 ? "\(verb) \(name)" : "\(verb) \(name) and \(others) more"
    }

    func restartSpringBoard() async {
        restarting = true
        await Respring.now()
        restarting = false
    }
}

/// The Queue tab: what is queued, then the review, then the result. The
/// queue bar opens the same in a sheet, with close, and starts the review.
struct QueueView: View {
    let environment: RuntimeEnvironment
    @ObservedObject var queue: QueueModel
    /// Closes the sheet; nil in the Queue tab.
    var close: (() -> Void)?
    @EnvironmentObject private var installed: InstalledPackagesModel

    var body: some View {
        NavigationView {
            if let close {
                content
                    .navigationTitle("Queue")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Close", action: close)
                                .disabled(busy)
                        }
                    }
            } else {
                content
                    .navigationTitle("Queue")
                    .systemButton()
            }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled(busy)
        .task {
            if close != nil, queue.phase == .editing, !queue.items.isEmpty {
                await queue.review()
            }
        }
    }

    /// apt is at work: the sheet stays until it is done.
    private var busy: Bool {
        switch queue.phase {
        case .preparing, .applying: return true
        default: return queue.restarting
        }
    }

    @ViewBuilder
    private var content: some View {
        switch queue.phase {
        case .editing:
            editing
        case .preparing(let message):
            progress(message)
        case .review(let plan, let warnings, let notes):
            ReviewView(plan: plan, warnings: warnings, notes: notes, undoing: queue.undoing, names: names,
                       leftovers: queue.leftovers, clearsSettings: $queue.clearsSettings,
                       onCancel: { queue.backToEditing() }) {
                Task { await queue.apply(plan, installed: installed, statusPath: environment.dpkgStatusPath, names: names) }
            }
            .task(id: plan) {
                await queue.findSettings(for: plan, statusPath: environment.dpkgStatusPath,
                                         installed: Set(installed.versions.keys))
            }
        case .blocked(let diagnoses, let output):
            ScrollView {
                VStack(spacing: 12) {
                    Card(padding: 14) {
                        ToolHeader(symbol: "xmark.octagon", color: .red, title: "apt cannot make this change") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(diagnoses, id: \.line) { diagnosis in
                                    DiagnosisView(diagnosis: diagnosis, showsFix: false) { _ in }
                                }
                                OutputText(title: "What apt said", output: output)
                            }
                        }
                        Button("Back to the Queue") { queue.backToEditing() }
                            .buttonStyle(TintedButtonStyle())
                            .padding(.top, 12)
                    }
                }
                .toolColumn()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(WallBackground())
        case .applying(let message):
            progress(message)
        case .finished(let succeeded, let plan, let diagnoses, let output, let notes):
            finished(succeeded: succeeded, plan: plan, diagnoses: diagnoses, output: output, notes: notes)
        }
    }

    private var editing: some View {
        ScrollView {
            VStack(spacing: 12) {
                queueCard
                if let last = queue.lastChange {
                    lastChangeCard(last)
                }
            }
            .toolColumn()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(WallBackground())
    }

    /// What is queued, a button to take each off, and the review.
    private var queueCard: some View {
        Card(padding: 14) {
            ToolHeader(symbol: "tray.and.arrow.down", color: .blue, title: "Queue") {
                if queue.items.isEmpty {
                    Text("Nothing is queued")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.secondary)
                    ToolNote(text: "Install, upgrade or remove packages from their pages, and they wait here until you review them.")
                        .padding(.top, 2)
                } else {
                    StatusLine(symbol: "clock.fill",
                               text: queue.items.count == 1 ? "1 change waiting" : "\(queue.items.count) changes waiting",
                               color: .blue)
                    ToolNote(text: "The review shows everything apt would change, including the packages these need, before anything happens.")
                        .padding(.top, 2)
                }
            }
            if !queue.items.isEmpty {
                VStack(spacing: 0) {
                    ForEach(queue.items) { item in
                        if item.id != queue.items.first?.id {
                            Divider()
                        }
                        HStack(spacing: 10) {
                            Image(systemName: symbol(item.operation))
                                .foregroundColor(.accentColor)
                                .frame(width: 22)
                                .accessibilityHidden(true)
                            Text(item.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(growing: 1)
                            Spacer(minLength: 6)
                            Text(verb(item.operation))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Button {
                                withAnimation { queue.remove(item.id) }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(Color(.tertiaryLabel))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Take \(item.name) off the queue")
                        }
                        .padding(.vertical, 9)
                        .accessibilityElement(children: .contain)
                    }
                }
                .padding(.horizontal, 12)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .glassSurface(cornerRadius: 12, inset: true)
                .padding(.top, 12)

                Button("Review Changes") {
                    Task { await queue.review() }
                }
                .buttonStyle(TintedButtonStyle())
                .padding(.top, 12)
            }
        }
    }

    private func lastChangeCard(_ last: ChangeRecord) -> some View {
        Card(padding: 14) {
            ToolHeader(symbol: "arrow.uturn.backward", color: .orange, title: "Last Change") {
                Text(last.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(last.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                ToolNote(text: "Undo removes what the change added and puts back what it removed or replaced, from the backups made before it. You review it first.")
                    .padding(.top, 2)
            }
            Button("Undo Last Change") {
                Task { await queue.undoLastChange(names: names) }
            }
            .buttonStyle(TintedButtonStyle(color: .orange))
            .padding(.top, 12)
        }
    }

    private func finished(succeeded: Bool, plan: AptPlan, diagnoses: [AptDiagnosis], output: String, notes: [String]) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                Card(padding: 14) {
                    if succeeded {
                        ToolHeader(symbol: "checkmark.circle", color: .green, title: "The changes were applied") {
                            notesAndOutput(notes: notes, output: output)
                        }
                    } else {
                        ToolHeader(symbol: "xmark.octagon", color: .red, title: "The changes could not be applied") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(diagnoses, id: \.line) { diagnosis in
                                    DiagnosisView(diagnosis: diagnosis, showsFix: false) { _ in }
                                }
                                ToolNote(text: "The System screen checks the package system and offers the fixes it needs.")
                                notesAndOutput(notes: notes, output: output)
                            }
                        }
                    }
                    Button("Done") {
                        queue.backToEditing()
                        close?()
                    }
                    .buttonStyle(TintedButtonStyle())
                    .padding(.top, 12)
                }
                if succeeded {
                    Card(padding: 14) {
                        ToolHeader(symbol: "arrow.triangle.2.circlepath", color: .orange, title: "Restart SpringBoard") {
                            ToolNote(text: "Tweaks that were installed, upgraded or removed take effect after SpringBoard restarts.")
                        }
                        Button(queue.restarting ? "Restarting SpringBoard" : "Restart SpringBoard") {
                            Task { await queue.restartSpringBoard() }
                        }
                        .buttonStyle(TintedButtonStyle(color: .orange))
                        .disabled(queue.restarting)
                        .padding(.top, 12)
                    }
                    PlanSummary(plan: plan, names: names)
                }
            }
            .toolColumn()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(WallBackground())
    }

    @ViewBuilder
    private func notesAndOutput(notes: [String], output: String) -> some View {
        ForEach(notes, id: \.self) { note in
            Label(note, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        OutputText(title: "What apt said", output: output)
    }

    private func progress(_ message: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    /// Names for the packages a plan touches: what the queue and the
    /// installed list know.
    private var names: [String: String] {
        var names = queue.appliedNames
        if case .loaded(let packages) = installed.state {
            for package in packages {
                names[package.identifier] = package.name
            }
        }
        for item in queue.items {
            names[item.id] = item.name
        }
        return names
    }

    private func symbol(_ operation: PackageOperation) -> String {
        switch operation {
        case .install: return "arrow.down.circle"
        case .remove: return "trash"
        case .restore: return "arrow.uturn.backward.circle"
        case .purchased: return "arrow.down.circle"
        case .file: return "arrow.down.doc"
        }
    }

    private func verb(_ operation: PackageOperation) -> String {
        switch operation {
        case .install(let package): return installed.version(of: package) == nil ? "Install" : "Upgrade"
        case .remove: return "Remove"
        case .restore(_, let version): return "Restore \(version)"
        case .purchased(let package, _): return installed.version(of: package) == nil ? "Install" : "Upgrade"
        case .file(let package, _): return installed.version(of: package) == nil ? "Install from file" : "Replace from file"
        }
    }
}

/// What apt would do, for the user to confirm.
private struct ReviewView: View {
    let plan: AptPlan

    private var confirmTitle: String {
        if plan.removesPackages { return "Confirm, Including Removals" }
        return plan.unauthenticated.isEmpty ? "Confirm" : "Install Without Verification"
    }

    let warnings: [AptDiagnosis]
    let notes: [String]
    /// The title of the change being undone, when this reviews an undo.
    let undoing: String?
    let names: [String: String]
    /// The settings the removals would leave behind, by package.
    let leftovers: [String: SettingsLeftovers]
    @Binding var clearsSettings: Set<String>
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Card(padding: 14) {
                    ToolHeader(symbol: undoing == nil ? "checklist" : "arrow.uturn.backward",
                               color: undoing == nil ? .blue : .orange,
                               title: undoing.map { "Undo: \($0)" } ?? "Review Changes") {
                        if plan.isEmpty {
                            ToolNote(text: undoing == nil ? "Nothing needs to change: everything queued is already as asked."
                                     : "Nothing can be undone automatically.")
                        } else {
                            ToolNote(text: "Everything apt would change, including the packages these need. Nothing happens until you confirm.")
                        }
                        ForEach(notes, id: \.self) { note in
                            Label(note, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundColor(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                    }
                    if plan.changes.contains(where: { $0.kind == .remove && $0.package == "com.nexusjb.codling" }) {
                        StatusLine(symbol: "exclamationmark.triangle.fill", text: "This removes Codling itself.", color: .red)
                            .padding(.top, 10)
                    }
                    VStack(spacing: 8) {
                        if !plan.isEmpty {
                            Button(confirmTitle, action: onConfirm)
                                .buttonStyle(TintedButtonStyle(color: plan.removesPackages ? .red
                                                               : plan.unauthenticated.isEmpty ? .accentColor : .orange))
                        }
                        Button("Cancel", action: onCancel)
                            .buttonStyle(TintedButtonStyle(color: .secondary))
                    }
                    .padding(.top, 12)
                }

                if !plan.unauthenticated.isEmpty {
                    Card(padding: 14) {
                        ToolHeader(symbol: "exclamationmark.shield", color: .orange, title: "Not verified") {
                            ToolNote(text: "These packages come from sources that are not signed, so Codling cannot tell whether they were changed on the way: \(plan.unauthenticated.map { names[$0] ?? $0 }.joined(separator: ", ")). Confirm only if you trust their sources.")
                        }
                    }
                }

                if !warnings.isEmpty {
                    Card(padding: 14) {
                        ToolHeader(symbol: "arrow.clockwise", color: .orange, title: "While updating the lists") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(warnings, id: \.line) { warning in
                                    DiagnosisView(diagnosis: warning, showsFix: false) { _ in }
                                }
                                ToolNote(text: "Sources that could not be refreshed keep the lists apt had before.")
                            }
                        }
                    }
                }

                if !leftovers.isEmpty {
                    settingsCard
                }

                if !plan.isEmpty {
                    PlanSummary(plan: plan, names: names)
                }
            }
            .toolColumn()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(WallBackground())
    }
}

extension ReviewView {
    /// A switch for each removed package that leaves settings behind; off
    /// unless the user turns it on.
    fileprivate var settingsCard: some View {
        Card(padding: 14) {
            ToolHeader(symbol: "slider.horizontal.3", color: .orange, title: "Settings") {
                ToolNote(text: "Removing a package keeps its settings, so they are there if you install it again. Codling can remove them too. Undo does not bring them back, and settings that may hold an activation stay.")
            }
            ForEach(leftovers.keys.sorted(by: { (names[$0] ?? $0) < (names[$1] ?? $1) }), id: \.self) { package in
                if let settings = leftovers[package] {
                    settingsRow(package, settings)
                        .padding(.top, 12)
                }
            }
        }
    }

    @ViewBuilder
    private func settingsRow(_ package: String, _ settings: SettingsLeftovers) -> some View {
        let name = names[package] ?? package
        VStack(alignment: .leading, spacing: 6) {
            if !settings.removable.isEmpty {
                Toggle(isOn: Binding(get: { clearsSettings.contains(package) },
                                     set: { on in
                                         if on { clearsSettings.insert(package) } else { clearsSettings.remove(package) }
                                     })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remove the settings of \(name)")
                            .font(.subheadline.weight(.semibold))
                        Text(settings.removable.map(\.name).joined(separator: ", "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(.red)
            }
            ForEach(settings.kept, id: \.name) { domain in
                Label("\(name) keeps \(domain.name): it may hold an activation.", systemImage: "key.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A plan's changes, by kind.
private struct PlanSummary: View {
    let plan: AptPlan
    let names: [String: String]

    var body: some View {
        group("Install", .install, symbol: "arrow.down", color: .accentColor)
        group("Upgrade", .upgrade, symbol: "arrow.up", color: .green)
        group("Reinstall", .reinstall, symbol: "arrow.clockwise", color: .gray)
        group("Downgrade", .downgrade, symbol: "arrow.down.right", color: .orange)
        group("Remove", .remove, symbol: "trash", color: .red)
    }

    private struct Row: Identifiable {
        let change: AptPlan.Change

        var id: String { change.package }
    }

    @ViewBuilder
    private func group(_ title: String, _ kind: AptPlan.Kind, symbol: String, color: Color) -> some View {
        let changes = plan.changes(kind)
        if !changes.isEmpty {
            CardHeading(title: "\(title) · \(changes.count)", symbol: symbol)
                .padding(.top, 8)
            CardRows(items: changes.map(Row.init), dividerInset: 62) { row in
                HStack(spacing: 12) {
                    IconTile(symbol: symbol, color: color, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(names[row.change.package] ?? row.change.package)
                            .font(.body.weight(.semibold))
                        Text(detail(row.change))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func detail(_ change: AptPlan.Change) -> String {
        var parts: [String] = []
        if let previous = change.previousVersion, previous != change.version {
            parts.append("\(previous) to \(change.version)")
        } else if !change.version.isEmpty {
            parts.append(change.version)
        }
        if let origin = change.origin {
            // apt's name for a .deb file: here, always a backup of Codling's.
            parts.append(origin == "local-deb" ? "from backup" : origin)
        }
        // The identifier, when the name shown is a different one.
        if let name = names[change.package], name != change.package {
            parts.append(change.package)
        }
        return parts.joined(separator: " · ")
    }
}

/// Program output, folded away.
struct OutputText: View {
    let title: String
    let output: String

    var body: some View {
        if !output.isEmpty {
            DisclosureGroup(title) {
                Text(output)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline)
        }
    }
}
