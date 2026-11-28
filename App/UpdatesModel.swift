// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UserNotifications

/// The newer versions the sources offer of installed packages, for the
/// Installed tab, its badge and the number on Codling's icon.
@MainActor
final class UpdatesModel: ObservableObject {
    @Published private(set) var updates: [PackageSummary] = []

    /// Works the updates out again, as after a refresh or a change to the
    /// installed packages, and shows their number on Codling's icon.
    /// architecture is the device's: on RootHide, a rootless build counts
    /// as an update only as RootlessConversion.offersForUpdates says.
    func refresh(store: IndexStore?, installed: [String: String], architecture: String) async {
        if let store, !installed.isEmpty {
            let offers = (try? await store.offers(ofAny: Array(installed.keys))) ?? []
            updates = AvailableUpdates.find(installed: installed,
                                            offers: RootlessConversion.offersForUpdates(offers, installed: installed,
                                                                                         on: architecture))
        } else {
            updates = []
        }
        await showOnIcon(updates.count)
    }

    private static let askedKey = "AskedToBadgeIcon"

    /// iOS shows a number on an app's icon only with the user's permission,
    /// which Codling asks for once, the first time there are updates.
    private func showOnIcon(_ count: Int) async {
        let center = UNUserNotificationCenter.current()
        let defaults = UserDefaults.standard
        if count > 0, !defaults.bool(forKey: Self.askedKey),
           await center.notificationSettings().authorizationStatus == .notDetermined {
            defaults.set(true, forKey: Self.askedKey)
            _ = try? await center.requestAuthorization(options: [.badge])
        }
        if #available(iOS 16, *) {
            try? await center.setBadgeCount(count)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = count
        }
    }
}
