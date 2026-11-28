// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A tweak's page in the Settings app. PreferenceLoader adds one for each
/// plist a package installs in /Library/PreferenceLoader/Preferences, from
/// the plist's entry.
public struct SettingsPane: Equatable {
    /// The row's title in Settings.
    public let title: String
    /// What Settings knows the row by: the entry's id, or else its label.
    public let identifier: String

    public init(title: String, identifier: String) {
        self.title = title
        self.identifier = identifier
    }

    /// Where PreferenceLoader puts the plists of tweaks' pages.
    public static let folder = "/Library/PreferenceLoader/Preferences/"

    /// Whether a file a package installed is one of PreferenceLoader's plists.
    public static func isEntryFile(_ path: String) -> Bool {
        path.contains(folder) && path.hasSuffix(".plist")
    }

    /// The page a PreferenceLoader plist adds, or nil when it adds none on
    /// this device: it has no entry with a label, or its filter names
    /// CoreFoundation versions other than this one.
    public static func pane(in plist: Any, coreFoundationVersion: Double) -> SettingsPane? {
        guard let plist = plist as? [String: Any], let entry = plist["entry"] as? [String: Any],
              let label = entry["label"] as? String, !label.isEmpty else { return nil }
        // Only a row that opens a page can be opened.
        if let cell = entry["cell"] as? String, !["PSLinkCell", "PSLinkListCell"].contains(cell) {
            return nil
        }
        let filter = (plist["filter"] ?? plist["pl_filter"]) as? [String: Any]
        guard passes(filter, coreFoundationVersion: coreFoundationVersion) else { return nil }
        let identifier = (entry["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? label
        return SettingsPane(title: label, identifier: identifier)
    }

    /// PreferenceLoader's filter: CoreFoundationVersion holds the lowest
    /// version the entry shows on and, when there is a second, the version
    /// from which it no longer does.
    static func passes(_ filter: [String: Any]?, coreFoundationVersion: Double) -> Bool {
        guard let versions = filter?["CoreFoundationVersion"] as? [Any] else { return true }
        let bounds = versions.compactMap(number)
        guard bounds.count == versions.count, let lowest = bounds.first else { return false }
        if coreFoundationVersion < lowest {
            return false
        }
        if bounds.count > 1, coreFoundationVersion >= bounds[1] {
            return false
        }
        return true
    }

    private static func number(_ value: Any) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    /// Whether PreferenceLoader adds tweaks' pages at the end of General.
    /// From iOS 18 the main page of Settings is no longer one it can add to.
    public static func inGeneral(systemVersion: String) -> Bool {
        (Int(systemVersion.split(separator: ".").first ?? "") ?? 0) >= 18
    }

    /// The address that opens the page in Settings.
    public static func address(of pane: SettingsPane, systemVersion: String) -> String? {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        guard let identifier = pane.identifier.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            return nil
        }
        return inGeneral(systemVersion: systemVersion) ? "prefs:root=General&path=\(identifier)"
            : "prefs:root=\(identifier)"
    }
}
