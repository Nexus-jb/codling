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
    @Published private(set) var phase: Phase = .editing
    @Published private(set) var restarting = false
    @Published private(set) var history: [ChangeRecord] = ChangeHistory.load()
    /// The title of the change the queue undoes, while it does.
    @Published private(set) var undoing: String?
    private var undoNotes: [String] = []

    var lastChange: ChangeRecord? { history.last }

    func contains(_ package: String) -> Bool {
        items.contains { $0.id == package }
    }

    func operation(for package: String) -> PackageOperation? {
        items.first { $0.id == package }?.operation
    }

    /// Queues an operation; a package is queued once, so a new operation
    /// replaces an earlier one for the same package.
    func add(_ operation: PackageOperation, name: String) {
        guard operation.isValid else { return }
        if undoing != nil {
            items = []
            undoing = nil
        }
        items.removeAll { $0.id == operation.package }
        items.append(Item(operation: operation, name: name))
        if case .finished = phase {
            phase = .editing
        }
    }

    func remove(_ package: String) {
        items.removeAll { $0.id == package }
        if items.isEmpty {
            undoing = nil
        }
    }

    func remove(atOffsets offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        if items.isEmpty {
            undoing = nil
        }
    }

    func backToEditing() {
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

    /// Brings apt's lists up to date, then asks apt what the queue would do.
    func review() async {
        let operations = items.map(\.operation)
        guard !operations.isEmpty else { return }
        phase = .preparing("Updating apt's package lists")
        let update = await Task.detached(priority: .userInitiated) { RootHelper.updateLists() }.value
        var warnings: [AptDiagnosis] = []
        switch update {
        case .failure(let failure):
            phase = .blocked([], output: failure.message)
            return
        case .success(let result) where result.status != 0:
            // Sources that could not be refreshed keep their last lists:
            // the change may still work, so it goes on with a warning.
            warnings = AptDiagnostics.diagnose(result.output)
        default:
            break
        }
        phase = .preparing("Working out the changes")
        let simulation = await Task.detached(priority: .userInitiated) { RootHelper.simulate(operations) }.value
        switch simulation {
        case .failure(let failure):
            phase = .blocked([], output: failure.message)
        case .success(let result) where result.status != 0:
            phase = .blocked(AptDiagnostics.diagnose(result.output), output: result.output)
        case .success(let result):
            phase = .review(AptPlan.parse(result.output), warnings: warnings, notes: undoing == nil ? [] : undoNotes)
        }
    }

    /// Backs up what the change removes or replaces, makes the reviewed
    /// change, and records it.
    func apply(_ plan: AptPlan, installed: InstalledPackagesModel, statusPath: String?, names: [String: String]) async {
        let operations = items.map(\.operation)
        UIApplication.shared.isIdleTimerDisabled = true
        // Asks iOS for time to finish if the user leaves Codling meanwhile.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Apply package changes")
        defer {
            UIApplication.shared.endBackgroundTask(background)
            UIApplication.shared.isIdleTimerDisabled = false
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

        switch result {
        case .failure(let failure):
            phase = .finished(succeeded: false, plan: plan, diagnoses: [], output: failure.message, notes: notes)
        case .success(let command):
            let succeeded = command.status == 0
            phase = .finished(succeeded: succeeded, plan: plan,
                              diagnoses: succeeded ? [] : AptDiagnostics.diagnose(command.output),
                              output: command.output, notes: notes)
            if succeeded {
                items = []
                undoing = nil
            }
        }
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
        _ = await Task.detached(priority: .userInitiated) { RootHelper.respring() }.value
        restarting = false
    }
}

/// The Queue tab: what is queued, then the review, then the result.
struct QueueView: View {
    let environment: RuntimeEnvironment
    @ObservedObject var queue: QueueModel
    @EnvironmentObject private var installed: InstalledPackagesModel
    @State private var confirmingRestart = false

    var body: some View {
        NavigationView {
            content
                .navigationTitle("Queue")
                .systemButton()
        }
        .navigationViewStyle(.stack)
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
                       onCancel: { queue.backToEditing() }) {
                Task { await queue.apply(plan, installed: installed, statusPath: environment.dpkgStatusPath, names: names) }
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
                                .lineLimit(1)
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
                .background(Palette.inset)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    Button("Done") { queue.backToEditing() }
                        .buttonStyle(TintedButtonStyle())
                        .padding(.top, 12)
                }
                if succeeded {
                    Card(padding: 14) {
                        ToolHeader(symbol: "arrow.triangle.2.circlepath", color: .orange, title: "Restart SpringBoard") {
                            ToolNote(text: "Tweaks that were installed, upgraded or removed take effect after SpringBoard restarts.")
                        }
                        Button(queue.restarting ? "Restarting SpringBoard" : "Restart SpringBoard") {
                            confirmingRestart = true
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
        .confirmationDialog("Restart SpringBoard?", isPresented: $confirmingRestart, titleVisibility: .visible) {
            Button("Restart SpringBoard") {
                Task { await queue.restartSpringBoard() }
            }
        } message: {
            Text("The Home Screen closes for a moment and every open app restarts.")
        }
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
        var names: [String: String] = [:]
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
        }
    }

    private func verb(_ operation: PackageOperation) -> String {
        switch operation {
        case .install(let package): return installed.version(of: package) == nil ? "Install" : "Upgrade"
        case .remove: return "Remove"
        case .restore(_, let version): return "Restore \(version)"
        }
    }
}

/// What apt would do, for the user to confirm.
private struct ReviewView: View {
    let plan: AptPlan
    let warnings: [AptDiagnosis]
    let notes: [String]
    /// The title of the change being undone, when this reviews an undo.
    let undoing: String?
    let names: [String: String]
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
                            Button(plan.removesPackages ? "Confirm, Including Removals" : "Confirm", action: onConfirm)
                                .buttonStyle(TintedButtonStyle(color: plan.removesPackages ? .red : .accentColor))
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
