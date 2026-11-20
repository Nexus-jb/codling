// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Featured tab shows every source's banners with equal standing: one
/// from each source in turn, so that no source fills the top of the list.
public enum FeaturedMix {
    /// The first item of each list, then the second of each, and so on.
    /// Callers shuffle the lists first, so no source is always first either.
    public static func interleave<Item>(_ lists: [[Item]]) -> [Item] {
        var mixed: [Item] = []
        mixed.reserveCapacity(lists.reduce(0) { $0 + $1.count })
        let longest = lists.map(\.count).max() ?? 0
        for index in 0..<longest {
            for list in lists where index < list.count {
                mixed.append(list[index])
            }
        }
        return mixed
    }
}
