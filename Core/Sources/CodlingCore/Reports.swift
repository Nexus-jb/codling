// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Crash reports and install results that Codling sends, only with the
/// user's consent, to the repository a package came from, when the
/// repository names where in a `reports_endpoint` file. docs/reports.md
/// describes the format for repository owners.
public enum Reports {
    /// The format these reports have.
    public static let format = 1

    /// The address from a repository's `reports_endpoint` file: one HTTPS
    /// address without a query, as for `payment_endpoint`.
    public static func endpoint(fromFile text: String) -> URL? {
        PaymentProvider.endpoint(fromFile: text)
    }

    /// Where a crash report or an install result goes, under the address.
    public static func url(_ endpoint: URL, _ kind: Kind) -> URL {
        endpoint.appendingPathComponent(kind.rawValue)
    }

    public enum Kind: String {
        case crash
        case install
    }

    /// What every report says about the device. Nothing in it identifies
    /// the device or the user.
    public struct Device: Equatable {
        /// The model identifier, such as iPhone15,3.
        public var model: String
        public var system: String
        public var build: String?
        /// "rootless" or "roothide".
        public var jailbreak: String
        /// "burrow" or "ellekit", or nil when no tweak loader is known.
        public var loader: String?
        /// Such as "Codling 0.1.0".
        public var client: String

        public init(model: String, system: String, build: String?, jailbreak: String, loader: String?, client: String) {
            self.model = model
            self.system = system
            self.build = build
            self.jailbreak = jailbreak
            self.loader = loader
            self.client = client
        }
    }

    /// The version and build in a crash report's system line, such as
    /// "iPhone OS 16.3.1 (20D67)".
    public static func systemVersion(_ line: String?) -> (version: String, build: String?)? {
        guard let line, let version = line.split(separator: " ").first(where: { $0.first?.isNumber == true }) else {
            return nil
        }
        var build: String?
        if let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close {
            build = String(line[line.index(after: open)..<close])
        }
        return (String(version), build)
    }

    /// The tweak loader to report, from BurrowState.loader.
    public static func loaderName(_ loader: String?) -> String? {
        switch loader?.lowercased() {
        case "burrow": return "burrow"
        case "ellekit": return "ellekit"
        default: return nil
        }
    }

    /// A crash report, as docs/reports.md describes it.
    public struct CrashReport: Encodable, Equatable {
        public struct OtherTweak: Encodable, Equatable {
            public var tweak: String
            public var package: String?
            public var version: String?
        }

        public var id: String
        public var date: Date?
        public var package: String
        public var version: String
        public var architecture: String
        public var tweak: String
        public var process: String
        public var reason: String?
        public var exception: BurrowState.Crash.Exception?
        public var frames: [BurrowState.Crash.Frame]
        public var otherTweaks: [OtherTweak]
        public var device: Device

        /// The report for a crash from Burrow's crash log. id is the SHA-256
        /// of the incident identifier, in hex, which the app computes. Nil
        /// unless the crash has a tweak to blame from a known package and
        /// version.
        public init?(crash: BurrowState.Crash, id: String, architecture: String, device: Device) {
            guard let tweak = crash.tweak, let package = crash.package, let identifier = package.package,
                  let version = package.version, let process = crash.bundleIdentifier ?? crash.process else {
                return nil
            }
            self.id = id
            date = crash.date
            self.package = identifier
            self.version = version
            self.architecture = architecture
            self.tweak = tweak
            self.process = process
            reason = crash.reason
            exception = crash.exception
            frames = Array(crash.frames.prefix(40))
            otherTweaks = crash.tweaks.filter { $0 != tweak }.sorted().map {
                OtherTweak(tweak: $0, package: crash.packages[$0]?.package, version: crash.packages[$0]?.version)
            }
            var device = device
            if let system = Reports.systemVersion(crash.system) {
                device.system = system.version
                device.build = system.build
            }
            if let model = crash.device, !model.isEmpty {
                device.model = model
            }
            self.device = device
        }

        private enum Keys: String, CodingKey {
            case format, id, date, package, version, architecture, tweak, process, reason, exception, frames
            case otherTweaks, device, system, build, jailbreak, loader, client
            case type, signal, subtype, name, message, image, offset, symbol, symbolOffset
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(Reports.format, forKey: .format)
            try container.encode(id, forKey: .id)
            try container.encode(date.map(Reports.dateText), forKey: .date)
            try container.encode(package, forKey: .package)
            try container.encode(version, forKey: .version)
            try container.encode(architecture, forKey: .architecture)
            try container.encode(tweak, forKey: .tweak)
            try container.encode(process, forKey: .process)
            try container.encode(reason, forKey: .reason)
            if let exception {
                var nested = container.nestedContainer(keyedBy: Keys.self, forKey: .exception)
                try nested.encode(exception.type, forKey: .type)
                try nested.encode(exception.signal, forKey: .signal)
                try nested.encode(exception.subtype, forKey: .subtype)
                try nested.encode(exception.name, forKey: .name)
                try nested.encode(exception.message, forKey: .message)
            } else {
                try container.encodeNil(forKey: .exception)
            }
            var list = container.nestedUnkeyedContainer(forKey: .frames)
            for frame in frames {
                var nested = list.nestedContainer(keyedBy: Keys.self)
                try nested.encode(frame.image, forKey: .image)
                try nested.encode(frame.offset, forKey: .offset)
                try nested.encode(frame.symbol, forKey: .symbol)
                try nested.encode(frame.symbolOffset, forKey: .symbolOffset)
            }
            var others = container.nestedUnkeyedContainer(forKey: .otherTweaks)
            for other in otherTweaks {
                var nested = others.nestedContainer(keyedBy: Keys.self)
                try nested.encode(other.tweak, forKey: .tweak)
                try nested.encode(other.package, forKey: .package)
                try nested.encode(other.version, forKey: .version)
            }
            try Reports.encode(device, into: &container)
        }
    }

    /// An install result, as docs/reports.md describes it.
    public struct InstallResult: Encodable, Equatable {
        public var package: String
        public var version: String
        public var architecture: String
        /// "install" or "upgrade".
        public var action: String
        public var installed: Bool
        /// The names of the problems Codling found in apt's output, such as
        /// "unmet-dependencies"; never the output itself.
        public var problems: [String]
        public var device: Device

        public init(package: String, version: String, architecture: String, upgrade: Bool, installed: Bool,
                    problems: [String], device: Device) {
            self.package = package
            self.version = version
            self.architecture = architecture
            action = upgrade ? "upgrade" : "install"
            self.installed = installed
            self.problems = installed ? [] : problems
            self.device = device
        }

        private enum Keys: String, CodingKey {
            case format, package, version, architecture, action, result, problems
            case device, system, build, jailbreak, loader, client
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(Reports.format, forKey: .format)
            try container.encode(package, forKey: .package)
            try container.encode(version, forKey: .version)
            try container.encode(architecture, forKey: .architecture)
            try container.encode(action, forKey: .action)
            try container.encode(installed ? "installed" : "failed", forKey: .result)
            try container.encode(problems, forKey: .problems)
            try container.encode(device.model, forKey: .device)
            try container.encode(device.system, forKey: .system)
            try container.encode(device.build, forKey: .build)
            try container.encode(device.jailbreak, forKey: .jailbreak)
            try container.encode(device.loader, forKey: .loader)
            try container.encode(device.client, forKey: .client)
        }
    }

    /// The JSON body of a report, with its keys sorted.
    public static func body<Report: Encodable>(_ report: Report, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return try encoder.encode(report)
    }

    static func dateText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func encode<Key: CodingKey>(_ device: Device, into container: inout KeyedEncodingContainer<Key>) throws {
        guard let deviceKey = Key(stringValue: "device"), let system = Key(stringValue: "system"),
              let build = Key(stringValue: "build"), let jailbreak = Key(stringValue: "jailbreak"),
              let loader = Key(stringValue: "loader"), let client = Key(stringValue: "client") else { return }
        try container.encode(device.model, forKey: deviceKey)
        try container.encode(device.system, forKey: system)
        try container.encode(device.build, forKey: build)
        try container.encode(device.jailbreak, forKey: jailbreak)
        try container.encode(device.loader, forKey: loader)
        try container.encode(device.client, forKey: client)
    }
}
