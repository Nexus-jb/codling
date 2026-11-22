// SPDX-License-Identifier: Apache-2.0

/// A package most tweaks or Codling itself rely on, which Codling offers to
/// install on its first launch on a device.
public struct Essential: Equatable {
    public let identifier: String
    public let name: String
    /// Why it is offered, in a few words.
    public let reason: String

    public init(identifier: String, name: String, reason: String) {
        self.identifier = identifier
        self.name = name
        self.reason = reason
    }
}

/// The essentials Codling queues on its first launch on a device, for the
/// user to review and confirm. Nothing is installed without that review,
/// and the user can take any of them off the queue first.
public enum Essentials {
    /// In the order the queue shows them. Each identifier is the one the
    /// package's own control file uses.
    public static let all: [Essential] = [
        Essential(identifier: "com.nexusjb.burrow", name: "Burrow",
                  reason: "Tweak injection, with Safe Mode for a tweak that crashes an app"),
        Essential(identifier: "preferenceloader", name: "PreferenceLoader",
                  reason: "Shows tweaks' settings in the Settings app"),
        Essential(identifier: "com.opa334.altlist", name: "AltList",
                  reason: "App lists in tweaks' settings"),
        Essential(identifier: "ws.hbang.common", name: "Cephei Tweak Support",
                  reason: "A library many tweaks need"),
        Essential(identifier: "com.opa334.libsandy", name: "libSandy",
                  reason: "A library many tweaks need"),
    ]

    /// The essentials to queue: those not installed that a source offers
    /// for this device. One that no source offers is left out, as there is
    /// nothing to install.
    public static func missing(installed: (String) -> Bool, offered: (String) -> Bool) -> [Essential] {
        all.filter { !installed($0.identifier) && offered($0.identifier) }
    }
}
