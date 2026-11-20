// SPDX-License-Identifier: Apache-2.0

import Metal
import SwiftUI
import UIKit

/// The sources apt reads, refreshed in parallel; each one shows its result as
/// soon as it finishes. Edit selects sources to copy their addresses; + adds
/// a source, from the clipboard when an address is on it.
struct SourcesView: View {
    @ObservedObject var model: SourcesModel
    @EnvironmentObject private var installed: InstalledPackagesModel
    @StateObject private var adder = AddSourceFlow()
    @State private var removing: Source?
    @State private var problem: String?
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var copied: String?
    @State private var exporting = false

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
                                .contextMenu {
                                    Button {
                                        Presenter.share(address: row.source.uri)
                                    } label: {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                    Button {
                                        UIPasteboard.general.string = row.source.uri
                                        flash("Copied \(row.source.host)")
                                    } label: {
                                        Label("Copy Address", systemImage: "doc.on.doc")
                                    }
                                    Button {
                                        Task { await model.refresh(id: row.id) }
                                    } label: {
                                        Label("Refresh", systemImage: "arrow.clockwise")
                                    }
                                    .disabled(model.isRefreshing || row.activity != .idle)
                                    Button(role: .destructive) {
                                        removing = row.source
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if !isEditing {
                                        Button(role: .destructive) {
                                            removing = row.source
                                        } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                        Button {
                                            Task { await model.refresh(id: row.id) }
                                        } label: {
                                            Label("Refresh", systemImage: "arrow.clockwise")
                                        }
                                        .tint(.blue)
                                        .disabled(model.isRefreshing || row.activity != .idle)
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
        .onAppear {
            adder.model = model
            adder.installed = installed
        }
        .confirmationDialog("Remove this source?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible,
            presenting: removing) { source in
            Button("Remove \(source.host)", role: .destructive) {
                Task { problem = await model.remove(source) }
            }
        } message: { source in
            Text(SourcesModel.removalNote(for: source, jailbreak: model.isJailbreakSource(source)))
        }
        .alert("Export All Sources?", isPresented: $exporting) {
            Button("Copy") { export(share: false) }
            Button("Share") { export(share: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The addresses of all \(model.rows.count) sources, one per line, to paste into another device or package manager.")
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
                Button("Export") { exporting = true }
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
        flash(addresses.count == 1 ? "Copied 1 source" : "Copied \(addresses.count) sources")
        leaveEditing()
    }

    /// Every source's address, copied or shared.
    private func export(share: Bool) {
        let text = model.rows.map(\.source.uri).joined(separator: "\n")
        if share {
            Presenter.share([text])
        } else {
            UIPasteboard.general.string = text
            flash(model.rows.count == 1 ? "Copied 1 source" : "Copied \(model.rows.count) sources")
        }
        leaveEditing()
    }

    private func leaveEditing() {
        withAnimation {
            editMode = .inactive
            selection = []
        }
    }

    /// A short note at the bottom of the screen.
    private func flash(_ text: String) {
        copied = text
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if copied == text {
                copied = nil
            }
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
    weak var installed: InstalledPackagesModel?
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
                if let first = copied.first, fresh.isEmpty {
                    self.askForAddress("https://", problem: copied.count == 1
                        ? "\(first), on the clipboard, is already in apt's lists. Type another address."
                        : "The \(copied.count) addresses on the clipboard are already in apt's lists. Type another address.")
                } else if fresh.isEmpty {
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
        Task { await present(alert) }
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
        await add([uri])
    }

    /// Offers the addresses copied to the clipboard.
    private func offer(_ uris: [String]) async {
        guard uris.count == 1, let uri = uris.first else {
            confirm(title: "Add \(uris.count) Sources?",
                    message: "From the clipboard:\n" + uris.joined(separator: "\n")) {
                await self.add(uris)
            }
            return
        }
        // The warning comes before anything is fetched from such a source.
        if PiracySources.entry(for: uri) != nil {
            await add([uri])
            return
        }
        let host = Source(uri: uri, suite: "./", components: []).host
        let inspected = await step("Checking \(host)") { await self.model?.inspect(uri: uri) }
        await hideProgress()
        switch inspected {
        case .failure(let error)?:
            askForAddress(uri, problem: error.message)
        case .success(let name)?:
            confirm(title: "Add This Source?", message: [name, uri].compactMap { $0 }.joined(separator: "\n")) {
                await self.add([uri], checked: true)
            }
        case nil:
            break
        }
    }

    /// Adds the sources one by one: the piracy warning first where it
    /// applies, then a check that a repository answers, then the helper and
    /// a first refresh. A prompt in the middle of the screen says what is
    /// happening, and the result says what came of each source, so that a
    /// source that was not added, or not read, does not go unnoticed.
    private func add(_ uris: [String], checked: Bool = false) async {
        var lines: [String] = []
        var single: (uri: String, result: Result<SourcesModel.Row, RefreshError>, findings: [SourceScan.Finding]?)?
        for (index, uri) in uris.enumerated() {
            if let entry = PiracySources.entry(for: uri) {
                await hideProgress()
                if !(await warn(entry)) {
                    if uris.count == 1 {
                        return
                    }
                    lines.append("Not added: \(uri), on the piracy list.")
                    continue
                }
            }
            let host = Source(uri: uri, suite: "./", components: []).host
            let counter = uris.count > 1 ? " (\(index + 1) of \(uris.count))" : ""
            var result: Result<SourcesModel.Row, RefreshError>
            if !checked, case .failure(let error)? = await step("Checking \(host)\(counter)", { await self.model?.inspect(uri: uri) }) {
                result = .failure(error)
            } else {
                result = await step("Adding \(host) and reading its packages\(counter)", { await self.model?.add(uri: uri) })
                    ?? .failure(.message("Codling is not ready to add sources."))
            }
            var findings: [SourceScan.Finding]?
            if case .success(let row) = result {
                findings = await step("Checking \(row.title)'s packages\(counter)") {
                    await self.model?.scan(sourceID: row.id, installed: self.installed?.versions ?? [:],
                                           essential: self.installed?.essential ?? [])
                }
            }
            single = (uri, result, findings)
            lines.append(Self.describe(uri: uri, result, findings))
        }
        await hideProgress()
        if uris.count == 1, let single {
            showResult(uri: single.uri, single.result, findings: single.findings)
        } else if !lines.isEmpty {
            let alert = UIAlertController(title: "Sources", message: lines.joined(separator: "\n\n"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            await present(alert)
        }
    }

    /// Runs one step with the progress prompt saying what it is.
    private func step<T>(_ text: String, _ work: () async -> T) async -> T {
        working = text
        await showProgress(text)
        let value = await work()
        working = nil
        return value
    }

    private static func describe(uri: String, _ result: Result<SourcesModel.Row, RefreshError>,
                                 _ findings: [SourceScan.Finding]?) -> String {
        switch result {
        case .failure(let error):
            return "Not added: \(uri). \(error.message)"
        case .success(let row):
            if case .failed(let message)? = row.outcome?.state {
                return "Added, but not read: \(row.title). \(message)"
            }
            let count = row.packageCount ?? 0
            let check = findings.map { $0.isEmpty ? " The security check found nothing." : " The security check found \($0.count) things to look at; see its page." } ?? ""
            return "Added: \(row.title), \(count == 1 ? "1 package" : "\(count.formatted()) packages").\(check)"
        }
    }

    /// The security check's findings for a prompt: a few lines, and how many
    /// more the source's page lists.
    static func summarize(_ findings: [SourceScan.Finding]) -> String {
        let shown = 5
        var lines = findings.prefix(shown).map { "• " + SourceScan.describe($0) }
        if findings.count > shown {
            lines.append("…and \(findings.count - shown) more on the source's page.")
        }
        return lines.joined(separator: "\n")
    }

    /// What came of one source: added and read, added but not read, or not
    /// added, with what to do next.
    private func showResult(uri: String, _ result: Result<SourcesModel.Row, RefreshError>, findings: [SourceScan.Finding]?) {
        let alert: UIAlertController
        switch result {
        case .failure(let error):
            alert = UIAlertController(title: "The Source Was Not Added", message: "\(uri)\n\n\(error.message)",
                                      preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            alert.addAction(UIAlertAction(title: "Edit Address", style: .default) { _ in
                Task { @MainActor in self.askForAddress(uri) }
            })
        case .success(let row):
            if case .failed(let message)? = row.outcome?.state {
                alert = UIAlertController(title: "Added, but Not Read",
                                          message: "\(row.title)\n\n\(message)\n\nYou can keep it and refresh later, or remove it.",
                                          preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Keep", style: .cancel))
                alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { _ in
                    Task { @MainActor in _ = await self.model?.remove(row.source) }
                })
            } else {
                let count = row.packageCount ?? 0
                var message = "\(row.title)\n\(count == 1 ? "1 package" : "\(count.formatted()) packages")"
                if !row.warnings.isEmpty {
                    message += "\n\n" + row.warnings.joined(separator: "\n")
                }
                if let findings, !findings.isEmpty {
                    message += "\n\nThe security check found:\n" + Self.summarize(findings)
                    alert = UIAlertController(title: "Source Added: Check Its Packages", message: message, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Keep", style: .cancel))
                    alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { _ in
                        Task { @MainActor in _ = await self.model?.remove(row.source) }
                    })
                } else {
                    if findings != nil {
                        message += "\n\nThe security check found nothing: no packages sold on your other sources, no cracks, and no newer copies of the jailbreak's own packages."
                    }
                    alert = UIAlertController(title: "Source Added", message: message, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .cancel))
                }
            }
        }
        Task { await present(alert) }
    }

    // MARK: Progress

    private var progress: UIAlertController?

    /// A prompt with a spinner that says what is happening; it has no
    /// buttons and goes away when the work is done.
    private func showProgress(_ text: String) async {
        if let progress {
            progress.message = text + "\n\n\n"
            return
        }
        let alert = UIAlertController(title: "Adding Source", message: text + "\n\n\n", preferredStyle: .alert)
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        alert.view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: alert.view.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: alert.view.bottomAnchor, constant: -22),
        ])
        progress = alert
        await present(alert)
    }

    private func hideProgress() async {
        guard let progress else {
            return
        }
        self.progress = nil
        await Self.once { finish in
            progress.dismiss(animated: true, completion: finish)
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
            Task { await self.present(alert) }
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
        Task { await present(alert) }
    }

    private func present(_ alert: UIViewController) async {
        await Presenter.present(alert)
    }

    private static func once(_ start: (@escaping () -> Void) -> Void) async {
        await Presenter.once(start)
    }
}

/// Presents UIKit screens, such as prompts and the share sheet, over
/// whatever SwiftUI shows.
@MainActor
enum Presenter {
    /// Presents a view controller over whatever is on screen, and returns
    /// once it is up.
    static func present(_ controller: UIViewController) async {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var top = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else {
            return
        }
        // A prompt on its way out cannot present another.
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        await once { finish in
            top.present(controller, animated: true, completion: finish)
        }
    }

    /// The share sheet, to send source addresses by Messages, Telegram or
    /// any other app. The system's sheet draws app icons with Core Image,
    /// which crashes without a Metal device; then Codling offers the apps it
    /// can open itself.
    static func share(_ items: [Any]) {
        if MTLCreateSystemDefaultDevice() != nil {
            Task { await present(UIActivityViewController(activityItems: items, applicationActivities: nil)) }
        } else {
            shareWithoutSheet(items.map { ($0 as? URL)?.absoluteString ?? "\($0)" }.joined(separator: "\n"))
        }
    }

    /// Messages, Telegram, WhatsApp and Mail by their addresses, and Copy.
    private static func shareWithoutSheet(_ text: String) {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        let query = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let sheet = UIAlertController(title: "Share", message: nil, preferredStyle: .actionSheet)
        let apps: [(String, String)] = [
            ("Messages", "sms:&body=" + query),
            ("Telegram", "tg://msg?text=" + query),
            ("WhatsApp", "whatsapp://send?text=" + query),
            ("Mail", "mailto:?body=" + query),
        ]
        for (name, address) in apps {
            guard let url = URL(string: address) else { continue }
            sheet.addAction(UIAlertAction(title: name, style: .default) { _ in
                Task { @MainActor in
                    if !(await UIApplication.shared.open(url)) {
                        let alert = UIAlertController(title: "\(name) Did Not Open",
                                                      message: "It may not be installed. The address is copied instead.",
                                                      preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
                        UIPasteboard.general.string = text
                        await present(alert)
                    }
                }
            })
        }
        sheet.addAction(UIAlertAction(title: "Copy", style: .default) { _ in
            UIPasteboard.general.string = text
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        Task { await present(sheet) }
    }

    /// Shares one source's address as a link, which Messages and the other
    /// apps show as one.
    static func share(address: String) {
        if let url = URL(string: address) {
            share([url])
        } else {
            share([address])
        }
    }

    /// Waits for a UIKit completion, but no more than two seconds: one that
    /// is not called, as when a presentation is refused, must not stop the
    /// flow.
    static func once(_ start: (@escaping () -> Void) -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            let finish = {
                if !finished {
                    finished = true
                    continuation.resume()
                }
            }
            start(finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: finish)
        }
    }
}
