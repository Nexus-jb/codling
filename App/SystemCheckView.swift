// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The device and Codling's install, drawn as the device itself, and the
/// tools that check and manage the system, each a card that says what it
/// does.
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
            ScrollView {
                VStack(spacing: 14) {
                    DeviceCard(environment: environment)
                        .padding(.top, 8)
                        .padding(.bottom, 18)

                    Text("Tools")
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 6)
                        .accessibilityAddTraits(.isHeader)

                    burrowCard
                    helperCard
                    PackageHealthCard(model: health)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
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

    private var burrowCard: some View {
        NavigationLink(destination: BurrowView(model: burrow)) {
            Card {
                HStack(spacing: 14) {
                    IconTile(symbol: "puzzlepiece.extension", color: .blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Burrow")
                            .font(.title3.bold())
                            .foregroundColor(.primary)
                        Text("Manage the tweaks it loads, see what Safe Mode turned off, and turn a tweak off in one app.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Chevron()
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var helperCard: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                IconTile(symbol: "lock.shield", color: .indigo)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Root Helper")
                        .font(.title3.bold())
                    helperStatus
                    Text("The helper installs and removes packages, and takes only Codling's commands. This check changes nothing.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Check the Root Helper") {
                Task { await checkHelper() }
            }
            .buttonStyle(TintedButtonStyle())
            .disabled(isChecking)
            .padding(.top, 16)
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
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking")
                    .foregroundColor(.secondary)
            }
        case .checked(.success(let identity)) where identity.isRoot:
            StatusLine(symbol: "checkmark.circle.fill", text: "Running as root", color: .green)
            Text(identity.dpkgWritable ? "UID 0 · Can write the package database."
                                       : "UID 0 · Cannot write the package database.")
                .foregroundColor(.secondary)
        case .checked(.success(let identity)):
            StatusLine(symbol: "xmark.octagon.fill", text: "Did not get root", color: .red)
            Text("It ran as UID \(identity.uid), so Codling cannot install packages.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .checked(.failure(let failure)):
            StatusLine(symbol: "xmark.octagon.fill", text: "Did not run", color: .red)
            Text(failure.message)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
/// the device's name and model, iOS, the jailbreak, and Codling's version
/// and place.
struct DeviceCard: View {
    let environment: RuntimeEnvironment

    private var front: DeviceModel.Front { DeviceModel.front(for: environment.deviceModel) }

    var body: some View {
        let width = min(UIScreen.main.bounds.width - 48, 340)
        let tablet = front == .tablet
        let bezel: CGFloat = tablet ? 16 : 11
        let outer: CGFloat = tablet ? 30 : (front == .homeButton ? 44 : 58)
        let inner: CGFloat = front == .homeButton ? 4 : outer - bezel
        // A home button phone has a band above and below its screen.
        let band: CGFloat = front == .homeButton ? 56 : 0

        screen
            .padding(.top, topSpace)
            .padding(.bottom, 28)
            .padding(.horizontal, 16)
            .frame(width: width - 2 * bezel)
            .frame(minHeight: (width - 2 * bezel) * (tablet ? 1.3 : 1.7) - 2 * band, alignment: .top)
            .background(Color(.systemGroupedBackground))
            .overlay(alignment: .top) { frontFeature }
            .clipShape(RoundedRectangle(cornerRadius: inner, style: .continuous))
            .padding(.horizontal, bezel)
            .padding(.vertical, bezel + band)
            .background(
                RoundedRectangle(cornerRadius: outer, style: .continuous)
                    .fill(Color(white: 0.13))
            )
            .overlay {
                RoundedRectangle(cornerRadius: outer, style: .continuous)
                    .strokeBorder(Color(white: 0.32), lineWidth: 1.5)
            }
            .overlay { if front == .homeButton { homeButtonBands(band: band) } }
            .overlay(alignment: .topLeading) { if !tablet { sideButtons(left: true) } }
            .overlay(alignment: .topTrailing) { if !tablet { sideButtons(left: false) } }
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    private var topSpace: CGFloat {
        switch front {
        case .dynamicIsland: return 72
        case .notch: return 60
        case .homeButton, .tablet: return 28
        }
    }

    @ViewBuilder
    private var frontFeature: some View {
        switch front {
        case .dynamicIsland:
            Capsule()
                .fill(Color.black)
                .frame(width: 96, height: 30)
                .padding(.top, 14)
        case .notch:
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black)
                .frame(width: 150, height: 52)
                .offset(y: -22)
        case .homeButton, .tablet:
            EmptyView()
        }
    }

    private func homeButtonBands(band: CGFloat) -> some View {
        VStack {
            Capsule()
                .fill(Color(white: 0.3))
                .frame(width: 46, height: 6)
                .padding(.top, band / 2 + 2)
            Spacer()
            Circle()
                .strokeBorder(Color(white: 0.4), lineWidth: 2)
                .frame(width: 40, height: 40)
                .padding(.bottom, band / 2 - 10)
        }
    }

    private var screen: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                IconTile(symbol: front == .tablet ? "ipad" : "iphone", size: 56)
                Text(DeviceModel.name(for: environment.deviceModel))
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text("Model · \(environment.deviceModel)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            group("System") {
                line("iOS", environment.systemVersion)
                Divider()
                line("Jailbreak", environment.scheme.title)
            }
            group("Codling") {
                line("Version", environment.version)
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Installed at")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text(environment.displayPath)
                        .font(.footnote.monospaced())
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 12)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .font(.callout)
        .padding(.vertical, 11)
    }

    /// Volume and action buttons on the left, the side button on the right.
    private func sideButtons(left: Bool) -> some View {
        VStack(spacing: 12) {
            if left {
                button(height: 26)
                button(height: 46)
                button(height: 46)
            } else {
                button(height: 72)
            }
        }
        .padding(.top, left ? 110 : 150)
        .offset(x: left ? -3 : 3)
    }

    private func button(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color(white: 0.3))
            .frame(width: 4, height: height)
    }

    private var accessibilityText: String {
        "\(DeviceModel.name(for: environment.deviceModel)), model \(environment.deviceModel), iOS \(environment.systemVersion), \(environment.scheme.title) jailbreak, Codling \(environment.version), installed at \(environment.displayPath)"
    }
}
