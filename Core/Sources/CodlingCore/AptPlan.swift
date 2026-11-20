// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A change the user asked for: install (or upgrade) a package, remove it,
/// or put back a version Codling backed up before an earlier change.
public enum PackageOperation: Hashable {
    case install(String)
    case remove(String)
    case restore(String, version: String)

    public var package: String {
        switch self {
        case .install(let name), .remove(let name), .restore(let name, _): return name
        }
    }

    /// The form the root helper takes: +name, -name or @name=version.
    public var helperArgument: String {
        switch self {
        case .install(let name): return "+" + name
        case .remove(let name): return "-" + name
        case .restore(let name, let version): return "@" + name + "=" + version
        }
    }

    /// Whether the helper accepts it: a valid name, and for a restore a
    /// valid version.
    public var isValid: Bool {
        if case .restore(_, let version) = self, !Self.isValidVersion(version) {
            return false
        }
        return Self.isValidName(package)
    }

    /// A Debian version as the helper accepts it: a digit first, then
    /// letters, digits and ".+~:-", at most 128 characters.
    public static func isValidVersion(_ version: String) -> Bool {
        let scalars = Array(version.unicodeScalars)
        guard let first = scalars.first, scalars.count <= 128, ("0"..."9").contains(first) else { return false }
        return scalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || ".+~:-".unicodeScalars.contains(scalar)
        }
    }

    /// The names the root helper accepts: letters, digits, "+", "-" and ".",
    /// starting with a letter or digit and ending with a letter, a digit or
    /// "+", at most 128 characters. The helper checks the same.
    public static func isValidName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count >= 2, scalars.count <= 128 else { return false }
        func alphanumeric(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
        }
        for (index, scalar) in scalars.enumerated() {
            let allowed = alphanumeric(scalar) || scalar == "+" || scalar == "-" || scalar == "."
            guard allowed else { return false }
            if index == 0 && !alphanumeric(scalar) { return false }
            if index == scalars.count - 1 && !alphanumeric(scalar) && scalar != "+" { return false }
        }
        return true
    }
}

/// What apt would do, read from `apt-get install -s`.
public struct AptPlan: Equatable {
    public enum Kind: Equatable {
        case install
        case upgrade
        case reinstall
        case downgrade
        case remove
    }

    public struct Change: Equatable {
        public var kind: Kind
        public var package: String
        /// The version installed after the change, or the version removed.
        public var version: String
        /// The version installed before an upgrade, reinstall or downgrade.
        public var previousVersion: String?
        /// Where apt takes the package from, as apt names it ("Procursus:1900").
        public var origin: String?

        public init(kind: Kind, package: String, version: String, previousVersion: String? = nil, origin: String? = nil) {
            self.kind = kind
            self.package = package
            self.version = version
            self.previousVersion = previousVersion
            self.origin = origin
        }
    }

    public var changes: [Change]
    /// Packages from sources that are not signed, or signed with a key the
    /// device does not trust.
    public var unauthenticated: [String]

    public init(changes: [Change] = [], unauthenticated: [String] = []) {
        self.changes = changes
        self.unauthenticated = unauthenticated
    }

    public func changes(_ kind: Kind) -> [Change] {
        changes.filter { $0.kind == kind }
    }

    public var removesPackages: Bool {
        changes.contains { $0.kind == .remove }
    }

    public var isEmpty: Bool {
        changes.isEmpty
    }

    /// Reads the Inst and Remv lines of a simulation, and the list of
    /// packages that cannot be authenticated.
    public static func parse(_ output: String) -> AptPlan {
        var plan = AptPlan()
        var readingUnauthenticated = false
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if readingUnauthenticated {
                if line.hasPrefix(" ") {
                    plan.unauthenticated += line.split(separator: " ").map(String.init)
                    continue
                }
                readingUnauthenticated = false
            }
            if line.hasPrefix("WARNING: The following packages cannot be authenticated") {
                readingUnauthenticated = true
                continue
            }
            if line.hasPrefix("Inst ") {
                if let change = installation(String(line.dropFirst(5))) {
                    plan.changes.append(change)
                }
            } else if line.hasPrefix("Remv ") || line.hasPrefix("Purg ") {
                if let change = removal(String(line.dropFirst(5))) {
                    plan.changes.append(change)
                }
            }
        }
        return plan
    }

    /// "jq (1.7.1 Procursus:1900 [iphoneos-arm64])", or with "[old]" after
    /// the name for a package already installed.
    private static func installation(_ text: String) -> Change? {
        var rest = Substring(text)
        guard let package = rest.split(separator: " ", maxSplits: 1).first else { return nil }
        rest = rest.dropFirst(package.count).drop { $0 == " " }
        var previous: String?
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            previous = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = rest[rest.index(after: close)...].drop { $0 == " " }
        }
        guard rest.hasPrefix("("), let close = rest.firstIndex(of: ")") else { return nil }
        let inside = rest[rest.index(after: rest.startIndex)..<close]
        guard let version = inside.split(separator: " ", maxSplits: 1).first.map(String.init) else { return nil }
        var origin = inside.dropFirst(version.count).trimmingCharacters(in: .whitespaces)
        if let architecture = origin.range(of: " [", options: .backwards) ?? (origin.hasPrefix("[") ? origin.range(of: "[") : nil) {
            origin = String(origin[..<architecture.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        var kind = Kind.install
        if let previous {
            let order = DebianVersion.compare(DebianVersion(version), DebianVersion(previous))
            kind = order > 0 ? .upgrade : order == 0 ? .reinstall : .downgrade
        }
        return Change(kind: kind, package: String(package), version: version, previousVersion: previous,
                      origin: origin.isEmpty ? nil : origin)
    }

    /// "jq [1.7.1]", possibly followed by more.
    private static func removal(_ text: String) -> Change? {
        let parts = text.split(separator: " ", maxSplits: 1)
        guard let package = parts.first else { return nil }
        var version = ""
        if parts.count > 1, parts[1].hasPrefix("["), let close = parts[1].firstIndex(of: "]") {
            version = String(parts[1][parts[1].index(after: parts[1].startIndex)..<close])
        }
        return Change(kind: .remove, package: String(package), version: version)
    }
}

/// How to take the device back from the packages after a change to the
/// packages before it.
public enum UndoPlanner {
    public struct Plan: Equatable {
        public var operations: [PackageOperation]
        /// Packages the change removed or replaced that have no backup, so
        /// they cannot be put back as they were.
        public var missing: [String]
    }

    /// Packages the change added are removed; packages it removed or whose
    /// version it changed come back from their backups. before, after and
    /// backups map package names to versions.
    public static func plan(before: [String: String], after: [String: String], backups: [String: String]) -> Plan {
        var removals: [PackageOperation] = []
        var restores: [PackageOperation] = []
        var missing: [String] = []
        for name in after.keys.sorted() where before[name] == nil {
            removals.append(.remove(name))
        }
        for (name, version) in before.sorted(by: { $0.key < $1.key }) where after[name] != version {
            if backups[name] == version {
                restores.append(.restore(name, version: version))
            } else {
                missing.append(name)
            }
        }
        return Plan(operations: removals + restores, missing: missing)
    }
}
