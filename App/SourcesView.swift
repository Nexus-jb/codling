// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The sources apt reads, refreshed in parallel; each one shows its result as
/// soon as it finishes.
struct SourcesView: View {
    @ObservedObject var model: SourcesModel

    var body: some View {
        NavigationView {
            Group {
                if let error = model.setupError {
                    Text(error)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    List {
                        Section {
                            ForEach(model.rows) { row in
                                NavigationLink(destination: SourceDetailView(sourceID: row.id)) {
                                    SourceRow(row: row)
                                }
                            }
                        } footer: {
                            Text(footer)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await model.refresh(force: false) }
                }
            }
            .navigationTitle("Sources")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if model.isRefreshing {
                        ProgressView()
                    } else {
                        Button {
                            Task { await model.refresh(force: false) }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task { await model.start() }
    }

    private var footer: String {
        let count = model.rows.count
        let sources = count == 1 ? "1 source" : "\(count) sources"
        if model.isRefreshing {
            return "\(sources). Refreshing: \(model.finished) of \(count) done."
        }
        guard let last = model.lastRefresh else {
            return sources
        }
        let packages = last.packages.formatted()
        return "\(sources), \(packages) packages. Refreshed in \(String(format: "%.1f", last.seconds)) seconds."
    }
}

/// A source: its icon, name and address, how its last refresh went, and
/// what the user should know about it.
struct SourceRow: View {
    let row: SourcesModel.Row
    var iconSize: CGFloat = 40

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconView(urls: row.source.repositoryFileURLs("CydiaIcon.png"), symbol: "tray.full.fill", size: iconSize)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(.headline)
                Text(row.source.uri + (row.source.isFlat ? "" : " \(row.source.suite) \(row.source.components.joined(separator: " "))"))
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                status
                ForEach(row.warnings, id: \.self) { warning in
                    IconLine(symbol: "exclamationmark.triangle", text: warning)
                        .font(.footnote)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        switch row.activity {
        case .waiting:
            Text("Waiting")
                .font(.subheadline)
                .foregroundColor(.secondary)
        case .refreshing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Refreshing")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        case .idle:
            if case .failed(let message)? = row.outcome?.state {
                IconLine(symbol: "xmark.octagon.fill", text: message)
                    .font(.subheadline)
                    .foregroundColor(.red)
            } else if let count = row.packageCount {
                IconLine(symbol: signatureSymbol, text: summary(count: count))
                    .font(.subheadline)
                    .foregroundColor(signatureColor)
            } else {
                Text("Not refreshed yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func summary(count: Int) -> String {
        var parts = [count == 1 ? "1 package" : "\(count.formatted()) packages"]
        switch row.signature {
        case .signed(let name)?: parts.append("signed by \(Self.signer(name))")
        case .trustedWithoutSignature?: parts.append("trusted without a signature")
        case .untrustedKey?, .unsigned?: parts.append("not verified")
        case nil: break
        }
        if case .unchanged? = row.outcome?.state {
            parts.append("up to date")
        }
        return parts.joined(separator: ", ")
    }

    /// The name on a key, without its comment and email address:
    /// "Chariz <chariz@hbang.ws>" becomes "Chariz".
    static func signer(_ userID: String) -> String {
        var name = userID
        if let email = name.firstIndex(of: "<") {
            name = String(name[..<email])
        }
        if let comment = name.firstIndex(of: "(") {
            name = String(name[..<comment])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? userID : name
    }

    private var signatureSymbol: String {
        switch row.signature {
        case .signed?: return "checkmark.seal.fill"
        case .trustedWithoutSignature?: return "checkmark.circle"
        default: return "exclamationmark.shield"
        }
    }

    private var signatureColor: Color {
        switch row.signature {
        case .signed?: return .green
        case .trustedWithoutSignature?: return .secondary
        default: return .orange
        }
    }
}

/// A symbol and text that wraps to as many lines as it needs. A List keeps a
/// row's first height when its text grows, so the text asks for its full
/// height rather than being cut short.
private struct IconLine: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
