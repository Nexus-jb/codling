// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What Burrow's `burrowctl json` reports: the tweak loader in use, the
/// loader settings, every tweak and Safe Mode's events. See Burrow's
/// docs/safe-mode.md and docs/loader.md.
public struct BurrowState: Decodable, Equatable {
    /// The only format this reader knows. A newer format may change what a
    /// key means, so Codling shows it but changes nothing.
    public static let knownFormat = 1

    public var format: Int
    /// "Burrow", "ElleKit", "none", or the path the system loader leads to.
    public var loader: String
    public var engine: String
    public var daemonRunning: Bool
    /// When Burrow's loader took over, which is when Safe Mode started; nil
    /// while another loader loads the tweaks.
    public var safeModeSince: Date?
    /// The end of the guard's close watch after a switch to Burrow's loader.
    public var trialUntil: Date?
    /// Why the guard went back to ElleKit's loader, when it did.
    public var wentBack: WentBack?
    /// "none", "valid" or "invalid". With invalid settings the loader loads
    /// no tweaks at all until they are fixed.
    public var settings: String
    public var disabledEverywhere: [String]
    public var disabledInProcesses: [String: [String]]
    public var tweaks: [Tweak]
    public var events: [Event]

    public struct WentBack: Decodable, Equatable {
        public var date: Date?
        public var reason: String
    }

    public struct Tweak: Decodable, Equatable, Identifiable {
        public var name: String
        public var bundles: [String]
        public var executables: [String]
        public var classes: [String]
        /// A tweak that decides about other tweaks, such as one that turns
        /// tweaks off per app.
        public var manager: Bool
        public var package: String?
        public var packageName: String?
        public var packageVersion: String?

        public var id: String { name }

        public init(name: String, bundles: [String] = [], executables: [String] = [], classes: [String] = [],
                    manager: Bool = false, package: String? = nil, packageName: String? = nil,
                    packageVersion: String? = nil) {
            self.name = name
            self.bundles = bundles
            self.executables = executables
            self.classes = classes
            self.manager = manager
            self.package = package
            self.packageName = packageName
            self.packageVersion = packageVersion
        }
    }

    public struct Event: Decodable, Equatable {
        public var date: Date?
        public var process: String
        public var tweak: String
        /// "safe-mode" when Safe Mode turned the tweak off, "off" or "on"
        /// when someone did.
        public var action: String
        /// One line for people, written by Burrow.
        public var text: String
    }

    /// Reads `burrowctl json`.
    public static func decode(_ data: Data) throws -> BurrowState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BurrowState.self, from: data)
    }

    public var usesBurrowLoader: Bool { loader == "Burrow" }

    /// Whether Codling may change the settings: Burrow's loader reads them,
    /// they are valid, and the format is one Codling knows.
    public var canChangeSettings: Bool {
        usesBurrowLoader && settings != "invalid" && format == Self.knownFormat
    }

    /// Whether a tweak is off in every process.
    public func isOffEverywhere(_ tweak: String) -> Bool {
        disabledEverywhere.contains(tweak) || disabledEverywhere.contains(Self.everyTweak)
    }

    /// A process where a tweak is off, and whether only because every tweak
    /// is off there.
    public struct OffPlace: Equatable, Identifiable {
        public var process: String
        public var everyTweak: Bool

        public var id: String { process }
    }

    /// The processes where a tweak is off, by name.
    public func placesOff(_ tweak: String) -> [OffPlace] {
        disabledInProcesses.keys.sorted().compactMap { process in
            let list = disabledInProcesses[process] ?? []
            if list.contains(tweak) {
                return OffPlace(process: process, everyTweak: false)
            }
            if list.contains(Self.everyTweak) {
                return OffPlace(process: process, everyTweak: true)
            }
            return nil
        }
    }

    /// The processes where Safe Mode or someone turned every tweak off.
    public var processesWithEveryTweakOff: [String] {
        disabledInProcesses.keys.sorted().filter { disabledInProcesses[$0]?.contains(Self.everyTweak) == true }
    }

    /// Safe Mode's own events, newest first.
    public var safeModeEvents: [Event] {
        events.filter { $0.action == "safe-mode" }.reversed()
    }

    /// Whether what an event turned off is still off.
    public func isStillOff(_ event: Event) -> Bool {
        if event.process == Self.everyTweak {
            return disabledEverywhere.contains(event.tweak)
        }
        return disabledInProcesses[event.process]?.contains(event.tweak) == true
    }

    /// The name burrowctl uses for every tweak, and for every process in
    /// events.
    public static let everyTweak = "*"
}

extension BurrowState.Tweak {
    /// Bundle identifiers of frameworks that every app, or every process,
    /// loads: a tweak filtered on them loads into each of those.
    static let everyAppBundles: Set<String> = ["com.apple.UIKit"]
    static let everyProcessBundles: Set<String> = ["com.apple.Foundation", "com.apple.CoreFoundation", "com.apple.security"]

    public enum Reach: Equatable {
        /// Every process: daemons too.
        case everyProcess
        /// Every app with a user interface.
        case everyApp
        /// The processes its filter names, and those that load a framework
        /// or class it names, which Codling cannot list.
        case named
        /// Its filter names nothing, so no loader loads it.
        case nothing
    }

    public var reach: Reach {
        if bundles.contains(where: Self.everyProcessBundles.contains) {
            return .everyProcess
        }
        if bundles.contains(where: Self.everyAppBundles.contains) {
            return .everyApp
        }
        if bundles.isEmpty && executables.isEmpty && classes.isEmpty {
            return .nothing
        }
        return .named
    }

    /// The bundle identifiers and executables its filter names, which may be
    /// apps, SpringBoard, daemons or frameworks.
    public var namedTargets: [String] {
        let frameworks = Self.everyAppBundles.union(Self.everyProcessBundles)
        var seen = Set<String>()
        return (bundles.filter { !frameworks.contains($0) } + executables).filter { seen.insert($0).inserted }
    }

    /// Whether the tweak may load into an app Codling cannot tell from its
    /// filter alone: the filter names a framework, such as WebKit, or a
    /// class, so any app might load it. installedApps holds the bundle
    /// identifiers of the installed apps.
    public func mayLoadIntoAnyApp(installedApps: Set<String>) -> Bool {
        switch reach {
        case .everyProcess, .everyApp:
            return true
        case .nothing:
            return false
        case .named:
            if !classes.isEmpty {
                return true
            }
            // An Apple bundle identifier that is no app, SpringBoard aside,
            // is a framework.
            return bundles.contains { bundle in
                bundle.hasPrefix("com.apple.") && bundle != "com.apple.springboard" && !installedApps.contains(bundle)
            }
        }
    }

    /// The name a person knows the tweak by: its package's, when it has one.
    public var displayName: String {
        if let packageName, !packageName.isEmpty {
            return packageName
        }
        return name
    }
}
