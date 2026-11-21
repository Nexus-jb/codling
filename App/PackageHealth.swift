// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Whether dpkg and apt are in a good state, from dpkg --audit and
/// apt-get check, and the repairs Codling can make.
@MainActor
final class PackageHealthModel: ObservableObject {
    enum State {
        case checking
        case healthy
        /// The problems found, and everything the tools printed.
        case problems([AptDiagnosis], output: String)
        case failed(String)
        case fixing(AptDiagnosis.Fix)
    }

    @Published private(set) var state: State = .checking
    /// What the last repair printed, when it did not succeed.
    @Published private(set) var lastFix: (title: String, diagnoses: [AptDiagnosis], output: String)?

    /// Refreshes the sources, for the problems that need it.
    var refreshSources: () async -> Void = {}

    func check() async {
        state = .checking
        let result = await Task.detached(priority: .userInitiated) { RootHelper.audit() }.value
        switch result {
        case .failure(let failure):
            state = .failed(failure.message)
        case .success(let audit):
            // apt-get check prints its progress lines even when all is well.
            let auditProblems = AptDiagnostics.significantAudit(audit.dpkgAudit.output)
            let aptProblems = audit.aptCheck.status == 0 ? "" : audit.aptCheck.output
            let output = [auditProblems, aptProblems]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            let diagnoses = AptDiagnostics.diagnose(output)
            if output.isEmpty {
                state = .healthy
            } else {
                state = .problems(diagnoses, output: output)
            }
        }
    }

    func perform(_ fix: AptDiagnosis.Fix) async {
        switch fix {
        case .retry:
            await check()
        case .refreshSources:
            await refreshSources()
            await check()
        case .configurePending:
            state = .fixing(fix)
            let result = await Task.detached(priority: .userInitiated) { RootHelper.configurePending() }.value
            switch result {
            case .failure(let failure):
                lastFix = (Self.title(for: fix), [], failure.message)
            case .success(let command) where command.status != 0:
                lastFix = (Self.title(for: fix), AptDiagnostics.diagnose(command.output), command.output)
            case .success:
                lastFix = nil
            }
            await check()
        }
    }

    static func title(for fix: AptDiagnosis.Fix) -> String {
        switch fix {
        case .configurePending: return "Finish Setting Up"
        case .refreshSources: return "Refresh Sources"
        case .retry: return "Try Again"
        }
    }
}

/// The Packages card of the System screen: what dpkg and apt report, a fix
/// where there is one, and a button to check again.
struct PackageHealthCard: View {
    @ObservedObject var model: PackageHealthModel
    @State private var confirming: AptDiagnosis.Fix?

    var body: some View {
        Card(padding: 14) {
            ToolHeader(symbol: "shippingbox", color: .blue, title: "Packages") {
                status
                ToolNote(text: "A check with dpkg and apt for packages left half installed or missing a dependency. It changes nothing.")
                    .padding(.top, 2)
            }
            problems
            Button("Check the Packages") {
                Task { await model.check() }
            }
            .buttonStyle(TintedButtonStyle())
            .disabled(isBusy)
            .padding(.top, 12)
        }
        .confirmationDialog("Finish setting up the packages?", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            Button("Finish Setting Up") {
                if let fix = confirming {
                    Task { await model.perform(fix) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Codling runs dpkg --configure -a as root. It runs the setup scripts of the packages that did not finish, and keeps any configuration file you changed.")
        }
    }

    private var isBusy: Bool {
        switch model.state {
        case .checking, .fixing: return true
        default: return false
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        case .fixing(let fix):
            HStack(spacing: 8) {
                ProgressView()
                Text(fix == .configurePending ? "Finishing setup" : "Working")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        case .healthy:
            StatusLine(symbol: "checkmark.circle.fill", text: "No problems", color: .green)
            Text("Every package is fully installed, and every dependency is met.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            StatusLine(symbol: "xmark.octagon.fill", text: "Could not check", color: .red)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .problems(let diagnoses, _):
            StatusLine(symbol: "exclamationmark.triangle.fill",
                       text: diagnoses.count > 1 ? "\(diagnoses.count) problems" : "A problem",
                       color: .orange)
        }
    }

    /// The problems and the last repair that failed, under the heading.
    @ViewBuilder
    private var problems: some View {
        if case .problems(let diagnoses, let output) = model.state {
            VStack(alignment: .leading, spacing: 12) {
                if diagnoses.isEmpty {
                    Text("apt reported a problem that Codling does not recognize yet. The details below show what apt said.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(diagnoses, id: \.id) { diagnosis in
                    DiagnosisView(diagnosis: diagnosis, showsFix: true) { fix in
                        if fix == .configurePending {
                            confirming = fix
                        } else {
                            Task { await model.perform(fix) }
                        }
                    }
                }
                OutputDisclosure(output: output)
            }
            .padding(.top, 14)
        }
        if let lastFix = model.lastFix {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(lastFix.title) did not finish")
                    .font(.headline)
                    .foregroundColor(.red)
                ForEach(lastFix.diagnoses, id: \.id) { diagnosis in
                    DiagnosisView(diagnosis: diagnosis, showsFix: false, onFix: { _ in })
                }
                OutputDisclosure(output: lastFix.output)
            }
            .padding(.top, 14)
        }
    }
}

/// One problem: what happened, what to do, and the fix when there is one.
struct DiagnosisView: View {
    let diagnosis: AptDiagnosis
    let showsFix: Bool
    let onFix: (AptDiagnosis.Fix) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .accessibilityHidden(true)
                Text(diagnosis.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(diagnosis.explanation)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Text(diagnosis.advice)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if showsFix, let fix = diagnosis.fix {
                Button(PackageHealthModel.title(for: fix)) {
                    onFix(fix)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

/// What the tools printed, folded away.
private struct OutputDisclosure: View {
    let output: String

    var body: some View {
        if !output.isEmpty {
            DisclosureGroup("What apt and dpkg said") {
                Text(output)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline)
        }
    }
}

