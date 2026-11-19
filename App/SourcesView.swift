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
                                SourceRow(row: row)
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

private struct SourceRow: View {
    let row: SourcesModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
                .font(.headline)
            Text(row.source.uri + (row.source.isFlat ? "" : " \(row.source.suite) \(row.source.components.joined(separator: " "))"))
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .lineLimit(2)
            status
            if let warnings = row.outcome?.warnings, !warnings.isEmpty {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
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
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.subheadline)
                    .foregroundColor(.red)
            } else if let count = row.packageCount {
                Label(summary(count: count), systemImage: signatureSymbol)
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
        case .signed(let name)?: parts.append("signed by \(name)")
        case .trustedWithoutSignature?: parts.append("trusted without a signature")
        case .untrustedKey?, .unsigned?: parts.append("not verified")
        case nil: break
        }
        if case .unchanged? = row.outcome?.state {
            parts.append("up to date")
        }
        return parts.joined(separator: ", ")
    }

    private var signatureSymbol: String {
        if case .signed? = row.signature { return "checkmark.seal.fill" }
        return "checkmark.circle"
    }

    private var signatureColor: Color {
        if case .signed? = row.signature { return .green }
        return .secondary
    }
}
