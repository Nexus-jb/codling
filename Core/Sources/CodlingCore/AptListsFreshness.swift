// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Whether apt's lists are recent enough for a review to use them as they
/// are, so that installing does not wait for apt-get update; and which
/// answers from apt say that they are out of date after all.
///
/// Codling brings apt's lists up to date in the background whenever it
/// refreshes, adds or removes sources. A review uses them while they are
/// younger than `window` and the sources are the same; otherwise, or when
/// apt cannot find a package or download a file, it updates them first.
public struct AptListsFreshness: Equatable {
    public static let window: TimeInterval = 30 * 60

    /// When apt-get update last finished, and the sources it read.
    public private(set) var updatedAt: Date?
    public private(set) var sources: [String] = []

    public init() {}

    /// sources: the addresses apt read, in any order.
    public mutating func recordUpdate(at date: Date, sources: [String]) {
        updatedAt = date
        self.sources = sources.sorted()
    }

    public mutating func invalidate() {
        updatedAt = nil
    }

    public func isFresh(now: Date, sources: [String]) -> Bool {
        guard let updatedAt else { return false }
        let age = now.timeIntervalSince(updatedAt)
        return age >= 0 && age < Self.window && self.sources == sources.sorted()
    }

    /// apt does not know a package or version the queue names, as when a
    /// source published it after apt's lists were read.
    public static func mentionsMissingPackage(_ output: String) -> Bool {
        let signs = ["Unable to locate package", "has no installation candidate", "' was not found",
                     "Couldn't find any package"]
        return signs.contains { output.contains($0) }
    }

    /// apt could not download a package, as when a source replaced the file
    /// that apt's lists name. apt downloads before it changes anything.
    public static func mentionsFailedDownload(_ output: String) -> Bool {
        let signs = ["Failed to fetch", "Unable to fetch some archives"]
        return signs.contains { output.contains($0) }
    }
}
