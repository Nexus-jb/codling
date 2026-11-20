// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// What Codling sees on the device, and whether its root helper works, so a
/// tester can confirm the package installed correctly.
struct SystemCheckView: View {
    let environment: RuntimeEnvironment
    @ObservedObject var health: PackageHealthModel
    let sources: SourcesModel
    @State private var helper: HelperState = .checking

    enum HelperState {
        case checking
        case checked(Result<RootHelper.Identity, RootHelper.Failure>)
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    row("Version", environment.version)
                    row("iOS", environment.systemVersion)
                    row("Device", environment.deviceModel)
                } header: {
                    Text("Codling")
                }

                Section {
                    row("Jailbreak", environment.scheme.title)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Installed at")
                        Text(environment.displayPath)
                            .font(.footnote.monospaced())
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    Text("Installation")
                }

                Section {
                    helperStatus
                    Button("Check Again") {
                        Task { await checkHelper() }
                    }
                    .disabled(isChecking)
                } header: {
                    Text("Root Helper")
                } footer: {
                    Text("Codling runs its helper as root to install and remove packages. The helper accepts only the commands Codling sends, and this check changes nothing.")
                }

                PackageHealthSection(model: health)
            }
            .navigationTitle("System")
        }
        .navigationViewStyle(.stack)
        .task {
            health.refreshSources = { [weak sources] in await sources?.refresh(force: false) }
            await checkHelper()
            await health.check()
        }
    }

    private var isChecking: Bool {
        if case .checking = helper { return true }
        return false
    }

    @ViewBuilder
    private var helperStatus: some View {
        switch helper {
        case .checking:
            HStack {
                ProgressView()
                Text("Checking")
                    .padding(.leading, 6)
            }
        case .checked(.success(let identity)) where identity.isRoot:
            status(symbol: "checkmark.seal.fill", color: .green, title: "Runs as root",
                   detail: identity.dpkgWritable
                       ? "uid 0. It can write the package database."
                       : "uid 0, but it cannot write the package database.")
        case .checked(.success(let identity)):
            status(symbol: "xmark.octagon.fill", color: .red, title: "Did not get root",
                   detail: "It ran as uid \(identity.uid), so Codling cannot install packages.")
        case .checked(.failure(let failure)):
            status(symbol: "xmark.octagon.fill", color: .red, title: "Did not run", detail: failure.message)
        }
    }

    private func checkHelper() async {
        helper = .checking
        let result = await Task.detached(priority: .userInitiated) { RootHelper.check() }.value
        helper = .checked(result)
    }

    private func status(symbol: String, color: Color, title: String, detail: String) -> some View {
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
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
