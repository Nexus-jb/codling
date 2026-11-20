// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The sources apt reads, refreshed in parallel; each one shows its result as
/// soon as it finishes.
struct SourcesView: View {
    @ObservedObject var model: SourcesModel
    @State private var adding = false
    @State private var removing: Source?
    @State private var problem: String?

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
                                .swipeActions {
                                    if model.isCodlingSource(row.source) {
                                        Button("Remove", role: .destructive) {
                                            removing = row.source
                                        }
                                    }
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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        adding = true
                    } label: {
                        Label("Add Source", systemImage: "plus")
                    }
                    .disabled(model.setupError != nil)
                }
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
        .sheet(isPresented: $adding) {
            AddSourceView(model: model)
        }
        .confirmationDialog("Remove this source?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible,
            presenting: removing) { source in
            Button("Remove \(source.host)", role: .destructive) {
                Task { problem = await model.remove(source) }
            }
        } message: { _ in
            Text("Its packages stay installed. Codling stops showing its packages and their updates.")
        }
        .alert("The source was not removed", isPresented: Binding(
            get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
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
                if PiracySources.entry(for: row.source.uri) != nil {
                    IconLine(symbol: "exclamationmark.shield.fill", text: "Known for piracy")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.red)
                }
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

/// Adds a repository by its address. A source known for piracy gets a clear
/// warning first, and is added only if the person chooses to.
struct AddSourceView: View {
    @ObservedObject var model: SourcesModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var problem: String?
    @State private var working = false
    @State private var warning: PiracyWarning?

    struct PiracyWarning: Identifiable {
        let id = UUID()
        let entry: PiracySources.Entry
        let uri: String
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("https://repo.example.com/", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .submitLabel(.done)
                        .onSubmit(start)
                } footer: {
                    Text("The address of an APT repository, as its developer gives it.")
                }
                if let problem {
                    Section {
                        Label(problem, systemImage: "xmark.octagon.fill")
                            .foregroundColor(.red)
                    }
                }
                Section {
                    Button(action: start) {
                        HStack {
                            Text(working ? "Checking the Repository" : "Add Source")
                            if working {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(working || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Add Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(working)
                }
            }
            .alert(item: $warning) { warning in
                Alert(title: Text("Known for Piracy"),
                      message: Text("\(warning.entry.name) is known for handing out paid tweaks and apps without their developers' permission. Cracked packages are often outdated or unstable and can carry malware, and they take income from the people who make tweaks.\n\nCodling does not block any source. Add this one only if you trust it."),
                      primaryButton: .cancel(Text("Don't Add")),
                      secondaryButton: .destructive(Text("Add Anyway")) {
                          Task { await add(warning.uri) }
                      })
            }
        }
        .interactiveDismissDisabled(working)
    }

    private func start() {
        guard !working else {
            return
        }
        problem = nil
        guard let uri = SourceList.repositoryURI(from: address) else {
            problem = "This is not the address of a repository. It looks like https://repo.example.com/."
            return
        }
        if let existing = model.existing(uri: uri) {
            problem = "\(existing.uri) is already in apt's lists."
            return
        }
        if let entry = PiracySources.entry(for: uri) {
            warning = PiracyWarning(entry: entry, uri: uri)
            return
        }
        Task { await add(uri) }
    }

    private func add(_ uri: String) async {
        working = true
        defer { working = false }
        if let reason = await model.probe(uri: uri) {
            problem = reason
            return
        }
        if let reason = await model.add(uri: uri) {
            problem = reason
            return
        }
        dismiss()
    }
}
