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
            let output = [audit.dpkgAudit.output, audit.aptCheck.output]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let diagnoses = AptDiagnostics.diagnose(output)
            let auditClean = audit.dpkgAudit.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if auditClean && audit.aptCheck.status == 0 && diagnoses.isEmpty {
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

/// The Package System section of the System tab.
struct PackageHealthSection: View {
    @ObservedObject var model: PackageHealthModel
    @State private var confirming: AptDiagnosis.Fix?

    var body: some View {
        Section {
            content
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
            }
            Button("Check Again") {
                Task { await model.check() }
            }
            .disabled(isBusy)
        } header: {
            Text("Package System")
        } footer: {
            Text("Codling asks dpkg and apt whether any package is left half installed or has missing dependencies. The check changes nothing.")
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
    private var content: some View {
        switch model.state {
        case .checking:
            HStack {
                ProgressView()
                Text("Checking")
                    .padding(.leading, 6)
            }
        case .fixing(let fix):
            HStack {
                ProgressView()
                Text(fix == .configurePending ? "Finishing setup" : "Working")
                    .padding(.leading, 6)
            }
        case .healthy:
            HealthLine(symbol: "checkmark.seal.fill", color: .green, title: "No problems",
                       detail: "Every package is fully installed, and every dependency is met.")
        case .failed(let message):
            HealthLine(symbol: "xmark.octagon.fill", color: .red, title: "Could not check", detail: message)
        case .problems(let diagnoses, let output):
            if diagnoses.isEmpty {
                HealthLine(symbol: "exclamationmark.triangle.fill", color: .orange, title: "apt reported a problem",
                           detail: "Codling does not recognize it yet. The details below show what apt said.")
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

private struct HealthLine: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundColor(color)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
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
