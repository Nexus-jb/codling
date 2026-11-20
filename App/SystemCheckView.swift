// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The device and Codling's install, drawn as the phone itself, and the
/// tools that check and manage the system, each with what it does.
struct SystemCheckView: View {
    let environment: RuntimeEnvironment
    @ObservedObject var health: PackageHealthModel
    let sources: SourcesModel
    let burrow: BurrowModel
    @State private var helper: HelperState = .checking
    @Environment(\.dismiss) private var dismiss

    enum HelperState {
        case checking
        case checked(Result<RootHelper.Identity, RootHelper.Failure>)
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    DeviceCard(environment: environment)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }

                Section {
                    NavigationLink(destination: BurrowView(model: burrow)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Burrow", systemImage: "puzzlepiece.extension")
                            Text("The loader that loads your tweaks, what Safe Mode turned off, and turning a tweak off in one app.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    helperStatus
                    ExplainedButton(title: "Check the Root Helper",
                                    explanation: "Codling's helper runs as root to install and remove packages, and takes only Codling's commands. This checks that it still does, and changes nothing.") {
                        Task { await checkHelper() }
                    }
                    .disabled(isChecking)

                    PackageHealthRows(model: health)
                } header: {
                    Text("Tools")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("System")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
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
                Text("Checking the root helper")
                    .padding(.leading, 6)
            }
        case .checked(.success(let identity)) where identity.isRoot:
            HealthLine(symbol: "checkmark.seal.fill", color: .green, title: "The root helper runs as root",
                       detail: identity.dpkgWritable
                           ? "uid 0. It can write the package database."
                           : "uid 0, but it cannot write the package database.")
        case .checked(.success(let identity)):
            HealthLine(symbol: "xmark.octagon.fill", color: .red, title: "The root helper did not get root",
                       detail: "It ran as uid \(identity.uid), so Codling cannot install packages.")
        case .checked(.failure(let failure)):
            HealthLine(symbol: "xmark.octagon.fill", color: .red, title: "The root helper did not run",
                       detail: failure.message)
        }
    }

    private func checkHelper() async {
        helper = .checking
        let result = await Task.detached(priority: .userInitiated) { RootHelper.check() }.value
        helper = .checked(result)
    }
}

/// The device, drawn with plain shapes after the front of the model it is:
/// the Dynamic Island, a notch, a home button, or a tablet. Its screen shows
/// the device, iOS, Codling and the jailbreak.
struct DeviceCard: View {
    let environment: RuntimeEnvironment

    private var front: DeviceModel.Front { DeviceModel.front(for: environment.deviceModel) }

    var body: some View {
        let tablet = front == .tablet
        let size = tablet ? CGSize(width: 250, height: 330) : CGSize(width: 200, height: 410)
        let corner: CGFloat = tablet ? 26 : (front == .homeButton ? 30 : 42)
        let bezel: CGFloat = tablet ? 14 : 9
        let chin: CGFloat = front == .homeButton ? 46 : 0

        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color(white: 0.12))
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: max(corner - bezel, 4) - (chin > 0 ? 22 : 0), style: .continuous)
                    .fill(Color(.systemBackground))
                frontFeature
                screen
                    .padding(.top, front == .dynamicIsland ? 44 : 34)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
            }
            .clipShape(RoundedRectangle(cornerRadius: max(corner - bezel, 4) - (chin > 0 ? 22 : 0), style: .continuous))
            .padding(.horizontal, bezel)
            .padding(.vertical, bezel + chin)
            if front == .homeButton {
                VStack {
                    Capsule().fill(Color(white: 0.3)).frame(width: 40, height: 5).padding(.top, 20)
                    Spacer()
                    Circle().strokeBorder(Color(white: 0.4), lineWidth: 2).frame(width: 30, height: 30).padding(.bottom, 8)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .leading) { if !tablet { sideButtons(count: 2, offset: -3) } }
        .overlay(alignment: .trailing) { if !tablet { sideButtons(count: 1, offset: 3) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var frontFeature: some View {
        switch front {
        case .dynamicIsland:
            Capsule()
                .fill(Color.black)
                .frame(width: 64, height: 20)
                .padding(.top, 10)
        case .notch:
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black)
                .frame(width: 96, height: 34)
                .offset(y: -12)
        case .homeButton, .tablet:
            EmptyView()
        }
    }

    private var screen: some View {
        VStack(spacing: 10) {
            Image(systemName: front == .tablet ? "ipad" : "iphone")
                .font(.title2)
                .foregroundColor(.accentColor)
            VStack(spacing: 6) {
                line("Device", DeviceModel.name(for: environment.deviceModel))
                line("Model", environment.deviceModel)
            }
            Divider()
            VStack(spacing: 6) {
                line("iOS", environment.systemVersion)
                line("Codling", environment.version)
                line("Jailbreak", environment.scheme.title)
            }
            Divider()
            VStack(spacing: 2) {
                Text("Installed at")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(environment.displayPath)
                    .font(.caption2.monospaced())
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer(minLength: 6)
            Text(value)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .font(.footnote)
    }

    private func sideButtons(count: Int, offset: CGFloat) -> some View {
        VStack(spacing: 10) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.35))
                    .frame(width: 4, height: count == 1 ? 60 : 40)
            }
        }
        .offset(x: offset, y: -70)
    }

    private var accessibilityText: String {
        "\(DeviceModel.name(for: environment.deviceModel)), model \(environment.deviceModel), iOS \(environment.systemVersion), Codling \(environment.version), \(environment.scheme.title) jailbreak, installed at \(environment.displayPath)"
    }
}
