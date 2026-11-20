// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UIKit

/// The changes the user has asked for, and their review and application:
/// apt works out the full change, the user confirms it, and the root helper
/// makes it.
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
        case review(AptPlan, warnings: [AptDiagnosis])
        /// apt could not work out the change.
        case blocked([AptDiagnosis], output: String)
        case applying
        case finished(succeeded: Bool, plan: AptPlan, diagnoses: [AptDiagnosis], output: String)
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var phase: Phase = .editing
    @Published private(set) var restarting = false

    func contains(_ package: String) -> Bool {
        items.contains { $0.id == package }
    }

    func operation(for package: String) -> PackageOperation? {
        items.first { $0.id == package }?.operation
    }

    /// Queues an operation; a package is queued once, so a new operation
    /// replaces an earlier one for the same package.
    func add(_ operation: PackageOperation, name: String) {
        guard PackageOperation.isValidName(operation.package) else { return }
        items.removeAll { $0.id == operation.package }
        items.append(Item(operation: operation, name: name))
        if case .finished = phase {
            phase = .editing
        }
    }

    func remove(_ package: String) {
        items.removeAll { $0.id == package }
    }

    func remove(atOffsets offsets: IndexSet) {
        items.remove(atOffsets: offsets)
    }

    func backToEditing() {
        phase = .editing
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
            phase = .review(AptPlan.parse(result.output), warnings: warnings)
        }
    }

    /// Makes the reviewed change.
    func apply(_ plan: AptPlan, installed: InstalledPackagesModel, statusPath: String?) async {
        let operations = items.map(\.operation)
        phase = .applying
        UIApplication.shared.isIdleTimerDisabled = true
        // Asks iOS for time to finish if the user leaves Codling meanwhile.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Apply package changes")
        let result = await Task.detached(priority: .userInitiated) {
            RootHelper.apply(operations, trustUnsigned: !plan.unauthenticated.isEmpty, allowRemovals: plan.removesPackages)
        }.value
        UIApplication.shared.endBackgroundTask(background)
        UIApplication.shared.isIdleTimerDisabled = false
        switch result {
        case .failure(let failure):
            phase = .finished(succeeded: false, plan: plan, diagnoses: [], output: failure.message)
        case .success(let command):
            let succeeded = command.status == 0
            phase = .finished(succeeded: succeeded, plan: plan,
                              diagnoses: succeeded ? [] : AptDiagnostics.diagnose(command.output), output: command.output)
            if succeeded {
                items = []
            }
        }
        await installed.load(statusPath: statusPath)
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
        case .review(let plan, let warnings):
            ReviewView(plan: plan, warnings: warnings, names: names, onCancel: { queue.backToEditing() }) {
                Task { await queue.apply(plan, installed: installed, statusPath: environment.dpkgStatusPath) }
            }
        case .blocked(let diagnoses, let output):
            List {
                Section {
                    Label("apt cannot make this change", systemImage: "xmark.octagon.fill")
                        .foregroundColor(.red)
                        .font(.headline)
                    ForEach(diagnoses, id: \.line) { diagnosis in
                        DiagnosisView(diagnosis: diagnosis, showsFix: false) { _ in }
                    }
                    OutputText(title: "What apt said", output: output)
                }
                Section {
                    Button("Back to the Queue") { queue.backToEditing() }
                }
            }
            .listStyle(.insetGrouped)
        case .applying:
            progress("Applying the changes. This can take a few minutes; keep Codling open.")
        case .finished(let succeeded, let plan, let diagnoses, let output):
            finished(succeeded: succeeded, plan: plan, diagnoses: diagnoses, output: output)
        }
    }

    private var editing: some View {
        Group {
            if queue.items.isEmpty {
                Text("Nothing is queued. Install, upgrade or remove packages from their pages.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                List {
                    Section {
                        ForEach(queue.items) { item in
                            HStack {
                                Label(item.name, systemImage: symbol(item.operation))
                                Spacer()
                                Text(verb(item.operation))
                                    .foregroundColor(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .onDelete { queue.remove(atOffsets: $0) }
                    } footer: {
                        Text("Swipe to take a package off the queue. The review shows everything apt would change, including the packages these need, before anything happens.")
                    }
                    Section {
                        Button {
                            Task { await queue.review() }
                        } label: {
                            Text("Review Changes")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private func finished(succeeded: Bool, plan: AptPlan, diagnoses: [AptDiagnosis], output: String) -> some View {
        List {
            Section {
                if succeeded {
                    Label("The changes were applied", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.headline)
                    PlanSummary(plan: plan, names: names)
                } else {
                    Label("The changes could not be applied", systemImage: "xmark.octagon.fill")
                        .foregroundColor(.red)
                        .font(.headline)
                    ForEach(diagnoses, id: \.line) { diagnosis in
                        DiagnosisView(diagnosis: diagnosis, showsFix: false) { _ in }
                    }
                    Text("The System tab checks the package system and offers the fixes it needs.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                OutputText(title: "What apt said", output: output)
            }
            if succeeded {
                Section {
                    Button {
                        confirmingRestart = true
                    } label: {
                        Label(queue.restarting ? "Restarting SpringBoard" : "Restart SpringBoard", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(queue.restarting)
                } footer: {
                    Text("Tweaks that were installed, upgraded or removed take effect after SpringBoard restarts.")
                }
            }
            Section {
                Button("Done") { queue.backToEditing() }
            }
        }
        .listStyle(.insetGrouped)
        .confirmationDialog("Restart SpringBoard?", isPresented: $confirmingRestart, titleVisibility: .visible) {
            Button("Restart SpringBoard") {
                Task { await queue.restartSpringBoard() }
            }
        } message: {
            Text("The Home Screen closes for a moment and every open app restarts.")
        }
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
        }
    }

    private func verb(_ operation: PackageOperation) -> String {
        switch operation {
        case .install(let package): return installed.version(of: package) == nil ? "Install" : "Upgrade"
        case .remove: return "Remove"
        }
    }
}

/// What apt would do, for the user to confirm.
private struct ReviewView: View {
    let plan: AptPlan
    let warnings: [AptDiagnosis]
    let names: [String: String]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        List {
            if plan.isEmpty {
                Section {
                    Text("Nothing needs to change: everything queued is already as asked.")
                        .foregroundColor(.secondary)
                }
            } else {
                PlanSummary(plan: plan, names: names)
            }
            if !plan.unauthenticated.isEmpty {
                Section {
                    Label("Not verified", systemImage: "exclamationmark.shield.fill")
                        .foregroundColor(.orange)
                        .font(.headline)
                    Text("These packages come from sources that are not signed, so Codling cannot tell whether they were changed on the way: \(plan.unauthenticated.map { names[$0] ?? $0 }.joined(separator: ", ")). Confirm only if you trust their sources.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if plan.changes.contains(where: { $0.kind == .remove && $0.package == "com.nexusjb.codling" }) {
                Section {
                    Label("This removes Codling itself.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                }
            }
            if !warnings.isEmpty {
                Section("While updating the lists") {
                    ForEach(warnings, id: \.line) { warning in
                        DiagnosisView(diagnosis: warning, showsFix: false) { _ in }
                    }
                    Text("Sources that could not be refreshed keep the lists apt had before.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            Section {
                if !plan.isEmpty {
                    Button {
                        onConfirm()
                    } label: {
                        Text(plan.removesPackages ? "Confirm, Including Removals" : "Confirm")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .foregroundColor(plan.removesPackages ? .red : .accentColor)
                }
                Button("Cancel", action: onCancel)
                    .frame(maxWidth: .infinity)
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// A plan's changes, by kind.
private struct PlanSummary: View {
    let plan: AptPlan
    let names: [String: String]

    var body: some View {
        group("Install", .install, symbol: "arrow.down.circle.fill", color: .accentColor)
        group("Upgrade", .upgrade, symbol: "arrow.up.circle.fill", color: .green)
        group("Reinstall", .reinstall, symbol: "arrow.clockwise.circle.fill", color: .secondary)
        group("Downgrade", .downgrade, symbol: "arrow.down.right.circle.fill", color: .orange)
        group("Remove", .remove, symbol: "trash.circle.fill", color: .red)
    }

    @ViewBuilder
    private func group(_ title: String, _ kind: AptPlan.Kind, symbol: String, color: Color) -> some View {
        let changes = plan.changes(kind)
        if !changes.isEmpty {
            Section("\(title) (\(changes.count))") {
                ForEach(changes, id: \.package) { change in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: symbol)
                            .foregroundColor(color)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(names[change.package] ?? change.package)
                            Text(detail(change))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
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
            parts.append(origin)
        }
        if names[change.package] != nil {
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
