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

/// The Device Info sheet: the device, iOS, Codling, the jailbreak, and the
/// UDID, hidden until tapped.
struct DeviceInfoView: View {
    let details: DeviceDetails
    @State private var showsUDID = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    Card(padding: 0) {
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
                    }
                    if details.udid != nil {
                        CardFooter(text: "Tap the UDID to show it, and hold it to copy it. It stays on this device.")
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Device Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
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
        .padding(.vertical, 12)
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
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
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
