// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The installed packages that a source offers in a newer version.
public enum AvailableUpdates {
    /// For each installed package, the newest offer newer than what is
    /// installed, sorted by name. When sources offer the same newest
    /// version, the first by source address is taken, so that no source is
    /// preferred for any other reason.
    public static func find(installed: [String: String], offers: [PackageSummary]) -> [PackageSummary] {
        var best: [String: PackageSummary] = [:]
        for offer in offers {
            guard let current = installed[offer.package],
                  DebianVersion(offer.version) > DebianVersion(current) else {
                continue
            }
            if let chosen = best[offer.package] {
                let order = DebianVersion.compare(DebianVersion(offer.version), DebianVersion(chosen.version))
                if order < 0 || (order == 0 && offer.source >= chosen.source) {
                    continue
                }
            }
            best[offer.package] = offer
        }
        return best.values.sorted(by: PackageCatalog.byName)
    }
}
