// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The names people know devices by, and the shape of their front, for the
/// devices Codling runs on: A12 and later with iOS 15 or later.
public enum DeviceModel {
    public enum Front: Equatable {
        case dynamicIsland
        case notch
        case homeButton
        case tablet
    }

    private static let names: [String: String] = [
        "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max",
        "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13", "iPhone14,6": "iPhone SE (3rd generation)", "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max", "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
    ]

    private static let dynamicIsland: Set<String> = [
        "iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5", "iPhone16,1", "iPhone16,2",
        "iPhone17,1", "iPhone17,2", "iPhone17,3", "iPhone17,4",
    ]

    private static let homeButton: Set<String> = ["iPhone12,8", "iPhone14,6"]

    /// "iPhone 14 Pro Max" for "iPhone15,3"; the identifier itself for a
    /// model this list does not know.
    public static func name(for identifier: String) -> String {
        names[identifier] ?? identifier
    }

    /// What the front of the device looks like. A model this list does not
    /// know is drawn by its family: newer iPhones have the Dynamic Island.
    public static func front(for identifier: String) -> Front {
        if identifier.hasPrefix("iPad") {
            return .tablet
        }
        if dynamicIsland.contains(identifier) {
            return .dynamicIsland
        }
        if homeButton.contains(identifier) {
            return .homeButton
        }
        if names[identifier] == nil, let major = majorVersion(identifier), major >= 18 {
            return .dynamicIsland
        }
        return .notch
    }

    static func majorVersion(_ identifier: String) -> Int? {
        guard identifier.hasPrefix("iPhone"), let comma = identifier.firstIndex(of: ",") else {
            return nil
        }
        return Int(identifier[identifier.index(identifier.startIndex, offsetBy: 6)..<comma])
    }
}
