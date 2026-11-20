// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UIKit

/// The sources apt reads, refreshed in parallel; each one shows its result as
/// soon as it finishes. Edit selects sources to copy their addresses; + adds
/// a source, from the clipboard when an address is on it.
struct SourcesView: View {
    @ObservedObject var model: SourcesModel
    @StateObject private var adder = AddSourceFlow()
    @State private var removing: Source?
    @State private var problem: String?
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var copied: String?

    private var isEditing: Bool { editMode.isEditing }

    var body: some View {
        NavigationView {
            Group {
                if let error = model.setupError {
                    Text(error)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    List(selection: $selection) {
                        Section {
                            ForEach(model.rows) { row in
                                NavigationLink(destination: SourceDetailView(sourceID: row.id)) {
                                    SourceRow(row: row)
                                }
                                .swipeActions {
                                    if model.isCodlingSource(row.source) && !isEditing {
                                        Button("Remove", role: .destructive) {
                                            removing = row.source
                                        }
                                    }
                                }
                            }
                        } footer: {
                            Text(isEditing ? "Select sources to copy their addresses." : footer)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await model.refresh(force: false) }
                    .environment(\.editMode, $editMode)
                }
            }
            .navigationTitle("Sources")
            .toolbar { toolbar }
            .overlay(alignment: .bottom) { banner }
        }
        .navigationViewStyle(.stack)
        .task { await model.start() }
        .onAppear { adder.model = model }
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarLeading) {
            Button(isEditing ? "Done" : "Edit") {
                withAnimation {
                    editMode = isEditing ? .inactive : .active
                    selection = []
                }
            }
            .disabled(model.rows.isEmpty)
            if isEditing {
                Button(selection.count == model.rows.count ? "Deselect All" : "Select All") {
                    selection = selection.count == model.rows.count ? [] : Set(model.rows.map(\.id))
                }
            }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if isEditing {
                Button(selection.isEmpty ? "Copy" : "Copy (\(selection.count))", action: copySelection)
                    .disabled(selection.isEmpty)
            } else {
                if model.isRefreshing {
                    ProgressView()
                } else {
                    Button {
                        Task { await model.refresh(force: false) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                Button {
                    adder.start()
                } label: {
                    Label("Add Source", systemImage: "plus")
                }
                .disabled(model.setupError != nil || adder.working != nil)
            }
        }
    }

    /// Copies the selected sources' addresses, one per line, in the list's
    /// order.
    private func copySelection() {
        let addresses = model.rows.filter { selection.contains($0.id) }.map(\.source.uri)
        UIPasteboard.general.string = addresses.joined(separator: "\n")
        copied = addresses.count == 1 ? "Copied 1 source" : "Copied \(addresses.count) sources"
        withAnimation {
            editMode = .inactive
            selection = []
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = nil
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let text = adder.working ?? copied {
            HStack(spacing: 8) {
                if adder.working != nil {
                    ProgressView()
                } else {
                    Image(systemName: "doc.on.doc.fill")
                        .accessibilityHidden(true)
                }
                Text(text)
                    .font(.footnote)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 12)
            .accessibilityElement(children: .combine)
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

/// Adds sources from small prompts in the middle of the screen. With an
/// address on the clipboard, + offers to add it, by name; otherwise it asks
/// for an address, starting with "https://". A source known for piracy gets
/// a clear warning before anything is fetched from it, and is added only if
/// the person chooses to.
@MainActor
final class AddSourceFlow: ObservableObject {
    weak var model: SourcesModel?
    /// What is happening, for the banner.
    @Published private(set) var working: String?

    func start() {
        guard working == nil else {
            return
        }
        // Looking for a web address does not read the clipboard, so iOS asks
        // to paste only when there is one.
        UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { result in
            let hasAddress = (try? result.get())?.contains(.probableWebURL) == true
            Task { @MainActor in
                let copied = hasAddress ? SourceList.repositoryURIs(in: UIPasteboard.general.string ?? "") : []
                let fresh = copied.filter { self.model?.existing(uri: $0) == nil }
                if fresh.isEmpty {
                    self.askForAddress("https://")
                } else {
                    await self.offer(fresh)
                }
            }
        }
    }

    /// Asks for an address, with text already in the field.
    private func askForAddress(_ text: String, problem: String? = nil) {
        let alert = UIAlertController(title: "Add Source",
                                      message: problem ?? "The address of an APT repository, as its developer gives it.",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.text = text
            field.placeholder = "https://repo.example.com/"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.clearButtonMode = .whileEditing
            field.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak alert] _ in
            Task { @MainActor in
                await self.addTyped(alert?.textFields?.first?.text ?? "")
            }
        })
        present(alert)
    }

    private func addTyped(_ text: String) async {
        guard let uri = SourceList.repositoryURI(from: text) else {
            askForAddress(text, problem: "This is not the address of a repository. It looks like https://repo.example.com/.")
            return
        }
        if let existing = model?.existing(uri: uri) {
            askForAddress(text, problem: "\(existing.uri) is already in apt's lists.")
            return
        }
        await add([uri], confirmed: true)
    }

    /// Offers the addresses copied to the clipboard.
    private func offer(_ uris: [String]) async {
        guard uris.count == 1, let uri = uris.first else {
            confirm(title: "Add \(uris.count) Sources?",
                    message: "From the clipboard:\n" + uris.joined(separator: "\n")) {
                await self.add(uris, confirmed: true)
            }
            return
        }
        // The warning comes before anything is fetched from such a source.
        if PiracySources.entry(for: uri) != nil {
            await add([uri], confirmed: false)
            return
        }
        working = "Checking \(Source(uri: uri, suite: "./", components: []).host)"
        let inspected = await model?.inspect(uri: uri)
        working = nil
        switch inspected {
        case .failure(let error)?:
            askForAddress(uri, problem: error.message)
        case .success(let name)?:
            confirm(title: "Add This Source?", message: [name, uri].compactMap { $0 }.joined(separator: "\n")) {
                await self.add([uri], confirmed: true, checked: true)
            }
        case nil:
            break
        }
    }

    /// Adds the sources one by one: the piracy warning first where it
    /// applies, then a check that a repository answers, then the helper.
    private func add(_ uris: [String], confirmed: Bool, checked: Bool = false) async {
        var failures: [String] = []
        for uri in uris {
            if let entry = PiracySources.entry(for: uri), !(await warn(entry)) {
                continue
            }
            let host = Source(uri: uri, suite: "./", components: []).host
            if !checked {
                working = "Checking \(host)"
                if case .failure(let error)? = await model?.inspect(uri: uri) {
                    failures.append("\(uri): \(error.message)")
                    continue
                }
            }
            working = "Adding \(host)"
            if let reason = await model?.add(uri: uri) {
                failures.append("\(uri): \(reason)")
            }
        }
        working = nil
        if !failures.isEmpty {
            let alert = UIAlertController(title: failures.count == 1 ? "A Source Was Not Added" : "Some Sources Were Not Added",
                                          message: failures.joined(separator: "\n\n"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            present(alert)
        }
    }

    /// The piracy warning; whether the person chose to add the source anyway.
    private func warn(_ entry: PiracySources.Entry) async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: "Known for Piracy",
                message: "\(entry.name) is known for handing out paid tweaks and apps without their developers' permission. Cracked packages are often outdated or unstable and can carry malware, and they take income from the people who make tweaks.\n\nCodling does not block any source. Add this one only if you trust it.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Don't Add", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "Add Anyway", style: .destructive) { _ in continuation.resume(returning: true) })
            present(alert)
        }
    }

    /// A question with Add and Don't Add; Don't Add asks for an address
    /// instead.
    private func confirm(title: String, message: String, add: @escaping () async -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Don't Add", style: .cancel) { _ in
            Task { @MainActor in self.askForAddress("https://") }
        })
        let action = UIAlertAction(title: "Add", style: .default) { _ in
            Task { @MainActor in await add() }
        }
        alert.addAction(action)
        alert.preferredAction = action
        present(alert)
    }

    private func present(_ alert: UIViewController) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var top = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else {
            return
        }
        while let presented = top.presentedViewController {
            top = presented
        }
        top.present(alert, animated: true)
    }
}
