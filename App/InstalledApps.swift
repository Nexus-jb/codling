// SPDX-License-Identifier: Apache-2.0

import Foundation

/// An app on the device, as the system's app registry knows it.
struct InstalledApp: Identifiable, Hashable {
    /// The bundle identifier, which is how Burrow's settings name an app.
    let id: String
    let name: String
    let isSystem: Bool
}

/// The apps installed on the device, from LaunchServices. Codling runs
/// outside the sandbox, so the registry lists every app; the classes are
/// private, so each is looked up at run time and nothing is assumed.
enum InstalledApps {
    static func load() -> [InstalledApp] {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return []
        }
        let defaultWorkspace = NSSelectorFromString("defaultWorkspace")
        let allApplications = NSSelectorFromString("allInstalledApplications")
        guard workspaceClass.responds(to: defaultWorkspace),
              let workspace = workspaceClass.perform(defaultWorkspace)?.takeUnretainedValue() as? NSObject,
              workspace.responds(to: allApplications),
              let proxies = workspace.perform(allApplications)?.takeUnretainedValue() as? [NSObject] else {
            return []
        }
        var apps: [InstalledApp] = []
        var seen = Set<String>()
        for proxy in proxies {
            guard let identifier = value(proxy, "applicationIdentifier") as? String, seen.insert(identifier).inserted else {
                continue
            }
            // Apps the home screen hides, such as system services with a bundle.
            if let tags = value(proxy, "appTags") as? [String], tags.contains("hidden") {
                continue
            }
            let name = (value(proxy, "localizedName") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? identifier
            let type = value(proxy, "applicationType") as? String
            apps.append(InstalledApp(id: identifier, name: name, isSystem: type == "System"))
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A property of a private object, or nil when it has none; asking for a
    /// key an object does not have would raise an exception.
    private static func value(_ object: NSObject, _ key: String) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }
}
