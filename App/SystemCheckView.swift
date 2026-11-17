// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The first screen of the early builds: it shows what Codling sees on the
/// device, so a tester can confirm the package installed correctly.
struct SystemCheckView: View {
    private let environment = RuntimeEnvironment.current()

    var body: some View {
        NavigationView {
            List {
                Section {
                    row("Version", "\(environment.appVersion) (\(environment.buildNumber))")
                    row("iOS", environment.systemVersion)
                    row("Device", environment.deviceModel)
                } header: {
                    Text("Codling")
                }

                Section {
                    row("Jailbreak", environment.scheme.title)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Installed at")
                        Text(environment.bundlePath)
                            .font(.footnote.monospaced())
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    Text("Installation")
                } footer: {
                    Text("This is an early development build. Package management is not available yet.")
                }
            }
            .navigationTitle("System Check")
        }
        .navigationViewStyle(.stack)
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
