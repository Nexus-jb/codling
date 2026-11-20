// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// What Codling knows about the device and its jailbreak, for the Device
/// Info sheet. Nothing here leaves the device.
struct DeviceDetails {
    let name: String
    let model: String
    let systemVersion: String
    let codlingVersion: String
    /// The jailbreak by name when Codling recognizes it, otherwise its kind.
    let jailbreak: String
    let bootstrap: String?
    let udid: String?

    @MainActor
    static func read(environment: RuntimeEnvironment, installed: InstalledPackagesModel) -> DeviceDetails {
        DeviceDetails(name: DeviceModel.name(for: environment.deviceModel),
                      model: environment.deviceModel,
                      systemVersion: environment.systemVersion,
                      codlingVersion: environment.version,
                      jailbreak: jailbreakName(environment: environment),
                      bootstrap: installed.version(of: "procursus-keyring") != nil ? "Procursus" : nil,
                      udid: uniqueDeviceID())
    }

    /// Dopamine keeps its own programs in basebin under the jailbreak root,
    /// and palera1n mounts its tools at /cores/binpack.
    private static func jailbreakName(environment: RuntimeEnvironment) -> String {
        let files = FileManager.default
        if let root = environment.jailbreakRoot, files.fileExists(atPath: root + "/basebin") {
            return "Dopamine"
        }
        if files.fileExists(atPath: "/cores/binpack") {
            return "palera1n"
        }
        return environment.scheme.title
    }

    /// The device's UDID, from MobileGestalt, which payment providers also
    /// ask for when you sign in.
    private static func uniqueDeviceID() -> String? {
        guard let library = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY),
              let symbol = dlsym(library, "MGCopyAnswer") else {
            return nil
        }
        typealias CopyAnswer = @convention(c) (CFString) -> Unmanaged<CFTypeRef>?
        let copyAnswer = unsafeBitCast(symbol, to: CopyAnswer.self)
        guard let answer = copyAnswer("UniqueDeviceID" as CFString)?.takeRetainedValue() as? String,
              !answer.isEmpty else {
            return nil
        }
        return answer
    }
}

/// Whether the Device Info panel is up, and what it shows. The panel is
/// drawn over the whole app, the tab bar included.
@MainActor
final class DeviceInfoPanel: ObservableObject {
    @Published private(set) var details: DeviceDetails?

    func show(_ details: DeviceDetails) {
        self.details = details
    }

    func close() {
        details = nil
    }
}

/// The Device Info panel: a card that rises from the bottom over a dimmed
/// app, and goes away with its close button, a tap outside it, or a swipe
/// down.
struct DeviceInfoOverlay: View {
    @ObservedObject var panel: DeviceInfoPanel
    @State private var drag: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            if let details = panel.details {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { panel.close() }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                DeviceInfoCard(details: details, close: { panel.close() })
                    .offset(y: max(drag, 0))
                    .gesture(DragGesture()
                        .onChanged { drag = $0.translation.height }
                        .onEnded { value in
                            if value.translation.height > 90 {
                                panel.close()
                            }
                            drag = 0
                        })
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: panel.details == nil)
    }
}

/// The device, iOS, Codling, the jailbreak, and the UDID, hidden until
/// tapped.
private struct DeviceInfoCard: View {
    let details: DeviceDetails
    let close: () -> Void
    @State private var showsUDID = false

    var body: some View {
        VStack(spacing: 14) {
            Capsule()
                .fill(Color(.tertiaryLabel))
                .frame(width: 40, height: 5)
                .padding(.top, 8)
                .accessibilityHidden(true)
            ZStack {
                Text("Device Info")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                HStack {
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(.secondary)
                            .frame(width: 32, height: 32)
                            .background(Color(.tertiarySystemFill), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }
            VStack(spacing: 0) {
                line("Device", details.name)
                Divider().padding(.leading, 16)
                line("Model", details.model)
                Divider().padding(.leading, 16)
                line("iOS", details.systemVersion)
                Divider().padding(.leading, 16)
                line("Codling", details.codlingVersion)
                Divider().padding(.leading, 16)
                line("Jailbreak", details.jailbreak)
                if let bootstrap = details.bootstrap {
                    Divider().padding(.leading, 16)
                    line("Bootstrap", bootstrap)
                }
                Divider().padding(.leading, 16)
                udidLine
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            if details.udid != nil {
                Text("Tap the UDID to show it, and hold it to copy it. It stays on this device.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: 500)
        .background(
            CornerRoundedRectangle(radius: 32, corners: [.topLeft, .topRight])
                .fill(Color(.systemGroupedBackground))
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: .black.opacity(0.15), radius: 20, y: -4)
        )
        .accessibilityAddTraits(.isModal)
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var udidLine: some View {
        if let udid = details.udid {
            Button {
                showsUDID.toggle()
            } label: {
                HStack {
                    Text("UDID")
                        .foregroundColor(.secondary)
                    Spacer(minLength: 12)
                    Text(showsUDID ? udid : String(repeating: "•", count: 12))
                        .font(showsUDID ? .footnote.monospaced() : .body)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
            .buttonStyle(CardRowButtonStyle())
            .contextMenu {
                Button {
                    UIPasteboard.general.string = udid
                } label: {
                    Label("Copy UDID", systemImage: "doc.on.doc")
                }
            }
            .accessibilityLabel("UDID")
            .accessibilityValue(showsUDID ? udid : "Hidden")
            .accessibilityHint(showsUDID ? "Hides the UDID." : "Shows the UDID.")
        } else {
            line("UDID", "Not available")
        }
    }
}
