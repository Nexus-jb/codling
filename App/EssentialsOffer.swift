// SPDX-License-Identifier: Apache-2.0

import Foundation

/// On Codling's first launch on a device, the essentials it lacks
/// (Essentials in CodlingCore) go into the queue, which opens to review
/// them. Nothing is installed until the user confirms, and they can take
/// any of them off first. Codling offers them once.
@MainActor
enum EssentialsOffer {
    private static let offeredKey = "OfferedEssentials"

    static let notice = "Codling offers these essentials once, on its first launch: Burrow, for Safe Mode, and packages many tweaks need. Take off any you do not want. Nothing is installed until you confirm."

    /// Queues the essentials that are not installed and that a source
    /// offers for this device, once per device. Returns whether any were
    /// queued. Without an index or the installed packages yet, it does
    /// nothing, and the next launch tries again.
    static func queueOnce(store: IndexStore?, installed: InstalledPackagesModel, queue: QueueModel) async -> Bool {
        #if targetEnvironment(simulator)
        // Nothing installs in the simulator, which only takes screenshots.
        return false
        #else
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: offeredKey), let store, !queue.isBusy, queue.undoing == nil,
              case .loaded = installed.state else {
            return false
        }
        guard let count = try? await store.packageCount(), count > 0,
              let offers = try? await store.offers(ofAny: Essentials.all.map(\.identifier)) else {
            return false
        }
        let offered = Set(offers.map(\.package))
        let missing = Essentials.missing(installed: { installed.version(of: $0) != nil }, offered: offered.contains)
        defaults.set(true, forKey: offeredKey)
        guard !missing.isEmpty else { return false }
        for essential in missing {
            let name = offers.first { $0.package == essential.identifier }?.name ?? essential.name
            queue.addForReview(.install(essential.identifier), name: name)
        }
        queue.notice = notice
        return true
        #endif
    }
}
