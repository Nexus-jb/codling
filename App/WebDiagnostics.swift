// SPDX-License-Identifier: Apache-2.0

import Foundation
import OSLog

/// What WebKit and the system said in Codling's own log about the web
/// view's page process, to find out why it stops before it draws.
enum WebDiagnostics {
    /// Where the details are saved, for Filza.
    static let fileURL = URL(fileURLWithPath: "/var/mobile/Documents/Codling-WebKit-Log.txt")

    /// The log lines of the last few minutes about WebKit's processes,
    /// RunningBoard and XPC, oldest first.
    static func recentLog(minutes: Double = 5) -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-minutes * 60))
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            var lines: [String] = []
            for entry in try store.getEntries(at: position) {
                guard let log = entry as? OSLogEntryLog else { continue }
                let subsystem = log.subsystem
                let message = log.composedMessage
                let relevant = ["WebKit", "runningboard", "xpc", "sandbox", "containermanager"]
                    .contains { subsystem.localizedCaseInsensitiveContains($0) }
                    || ["WebContent", "WebProcess", "GPUProcess", "NetworkProcess", "assertion", "sandbox", "terminat"]
                    .contains { message.localizedCaseInsensitiveContains($0) }
                if relevant {
                    lines.append("\(formatter.string(from: log.date)) [\(subsystem):\(log.category)] \(message)")
                }
            }
            if lines.isEmpty {
                return "Codling's log has no WebKit lines from the last \(Int(minutes)) minutes."
            }
            return lines.suffix(400).joined(separator: "\n")
        } catch {
            return "Codling could not read its log: \(error.localizedDescription)"
        }
    }

    /// Saves the log lines to Documents and returns them.
    @discardableResult
    static func save(context: String) -> String {
        let text = """
            Codling web view details
            \(context)
            \(Date())

            \(recentLog())
            """
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        return text
    }
}
