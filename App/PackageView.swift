// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A package's page: its header with the actions, its depiction and its
/// details. A paid package shows its price from its source's payment
/// provider, and GET once the user bought it.
struct PackageView: View {
    let source: SourceInfo
    let identifier: String
    /// What the list showed, for the header while the page loads.
    var summary: PackageSummary?

    @EnvironmentObject private var sources: SourcesModel
    @EnvironmentObject private var installed: InstalledPackagesModel
    @Environment(\.device) private var device
    @StateObject private var model = PackageModel()
    @StateObject private var router = DepictionRouter()

    /// The tab of the content card: a native depiction's tabs in order,
    /// or Details, and then Full Description.
    @State private var tab = 0
    /// The web page in the Full Description tab.
    @State private var webHeight: CGFloat = 1
    @State private var webLoad: WebLoadState = .loading
    @State private var webReload = 0
    @State private var savedDiagnostics = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if case .native(let depiction, _) = model.depiction, let headerImage = depiction.headerImage {
                    FramedPackageBanner(url: headerImage)
                }
                identityCard
                contentCard
                if model.loaded && tab == 0 {
                    details
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .pageColumn(maxWidth: PageLayout.packageWidth)
        }
        .foregroundColor(Palette.text)
        .background(WallBackground())
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.load(store: sources.store, source: source, package: identifier)
        }
        .depictionRouting(router, base: depictionBase)
    }

    private var record: PackageRecord? { model.newest }

    private var name: String {
        if let name = record?.name, !name.isEmpty {
            return name
        }
        return summary?.displayName ?? identifier
    }

    /// The package's web page, which the native depiction's tabs offer too.
    private var webPage: URL? {
        source.url(record?.depiction)
    }

    private var depictionBase: URL? {
        switch model.depiction {
        case .native(_, let base): return base
        case .web(let url): return url
        default: return source.base
        }
    }

    // MARK: Header

    private var isPaid: Bool {
        PackageCatalog.tags(record?.tag ?? summary?.tag).contains("cydia::commercial")
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PackageIcon(urls: source.url(record?.icon ?? summary?.icon).map { [$0] } ?? [],
                            section: record?.section ?? summary?.section, size: 62)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    if let author = author {
                        Text(author)
                            .foregroundColor(Palette.muted)
                    }
                    HStack(spacing: 8) {
                        Text(record?.version ?? summary?.version ?? "")
                            .foregroundColor(Palette.muted)
                        if isPaid {
                            Text("Paid")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Palette.text)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .glassSurface(cornerRadius: 99, inset: true)
                        }
                    }
                    .font(.subheadline)
                }
                .accessibilityElement(children: .combine)
            }
            if let installedVersion = installed.version(of: identifier) {
                Label(installedText(installedVersion), systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(Palette.green)
            }
            if let record {
                CompatibilityCard(report: Compatibility.check(depends: record.depends, tag: record.tag, name: record.name,
                                                              summary: record.summary, systemVersion: device.systemVersion),
                                  architecture: record.architecture)
            }
            if model.loaded {
                PackageActions(source: source, identifier: identifier, name: name, available: record?.version,
                               architecture: record?.architecture, isPaid: isPaid)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassSurface(cornerRadius: 22)
    }

    private var author: String? {
        guard let person = record?.author ?? record?.maintainer ?? summary?.author ?? summary?.maintainer else { return nil }
        let name = Person.name(person)
        return name.isEmpty ? nil : name
    }

    private func installedText(_ version: String) -> String {
        guard let available = record?.version, DebianVersion(available) > DebianVersion(version) else {
            return "Installed: \(version)"
        }
        return "Installed: \(version). Version \(available) is available."
    }

    // MARK: Depiction

    /// The names of the content card's tabs.
    private var tabNames: [String] {
        var names: [String]
        if case .native(let depiction, _) = model.depiction {
            names = depiction.tabs.map(\.name)
        } else {
            names = ["Details"]
        }
        if hasFullDescription {
            names.append("Full Description")
        }
        return names
    }

    private var hasFullDescription: Bool {
        webPage != nil || !(record?.details ?? "").isEmpty || !(summaryText ?? "").isEmpty
    }

    private var summaryText: String? {
        record?.summary ?? summary?.summary
    }

    @ViewBuilder
    private var contentCard: some View {
        switch model.depiction {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(24)
                .glassSurface(cornerRadius: 22)
        default:
            // A depiction that cannot be loaded, such as one its server no
            // longer has, leaves the package's own description in the tabs.
            tabbedContent
        }
    }

    private var tabbedContent: some View {
        let names = tabNames
        let selected = min(tab, names.count - 1)
        return VStack(alignment: .leading, spacing: 10) {
            if names.count > 1 {
                Picker("Package information", selection: $tab) {
                    ForEach(names.indices, id: \.self) { index in
                        Text(names[index]).tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.top, 14)
            }
            if hasFullDescription && selected == names.count - 1 && names.count > 1 {
                fullDescription
                    .padding(.horizontal, webPage != nil && !webFailed ? 0 : 14)
                    .padding(.bottom, 14)
            } else if case .native(let depiction, _) = model.depiction, selected < depiction.tabs.count {
                DepictionViews(views: depiction.tabs[selected].views)
                    .environment(\.depictionTint, depiction.tintColor.map(\.color))
                    .tint(depiction.tintColor.map(\.color))
                    .padding(.bottom, 8)
            } else if let summaryText, !summaryText.isEmpty {
                Text(summaryText)
                    .font(.subheadline)
                    .foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .padding(.top, names.count > 1 ? 0 : 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .glassSurface(cornerRadius: 22)
    }

    /// The package's web page, shown in the tab itself; without one, or
    /// when it cannot load, the summary and description, with a button that
    /// opens the page in the browser sheet.
    @ViewBuilder
    private var fullDescription: some View {
        if let webPage, !webFailed {
            ZStack(alignment: .top) {
                WebDepictionView(url: webPage, height: $webHeight, state: $webLoad, reload: webReload) { url in
                    router.perform(.web(url))
                }
                .frame(height: max(webHeight, 1))
                .opacity(webLoad == .loaded ? 1 : 0)
                if webLoad == .loading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(24)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if case .failed(let message) = webLoad {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let summaryText, !summaryText.isEmpty {
                    Text(summaryText)
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let details = record?.details, !details.isEmpty {
                    Text(details)
                        .font(.subheadline)
                        .foregroundColor(Palette.muted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let webPage {
                    HStack(spacing: 8) {
                        Button("Try Again") {
                            webLoad = .loading
                            webReload += 1
                        }
                        .buttonStyle(TintedButtonStyle())
                        Button {
                            router.browser(webPage)
                        } label: {
                            Label("Open in Browser", systemImage: "safari")
                        }
                        .buttonStyle(TintedButtonStyle())
                    }
                    .padding(.top, 4)
                    if webFailed {
                        Button {
                            let text = WebDiagnostics.save(context: "\(identifier) \(webPage.absoluteString)")
                            UIPasteboard.general.string = text
                            savedDiagnostics = true
                        } label: {
                            Label("Save Technical Details", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(TintedButtonStyle(color: .gray))
                        if savedDiagnostics {
                            Text("Copied, and saved to Documents as Codling-WebKit-Log.txt.")
                                .font(.footnote)
                                .foregroundColor(Palette.muted)
                        }
                    }
                }
            }
        }
    }

    /// Whether the web page failed, for the tab to show the text instead.
    private var webFailed: Bool {
        if case .failed = webLoad { return true }
        return false
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Package Details", systemImage: "info.circle")
                    .font(.headline)
                    .foregroundColor(Palette.heading)
                    .padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    detailRows
                }
                .padding(.vertical, 4)
                .glassSurface(cornerRadius: 21)
            }
            if model.versions.count > 1 {
                let others = model.versions.dropFirst().map(\.version)
                VStack(alignment: .leading, spacing: 8) {
                    Label("Other Versions", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                        .foregroundColor(Palette.heading)
                        .padding(.leading, 4)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 6)], spacing: 6) {
                        ForEach(others, id: \.self) { version in
                            Text(version)
                                .font(.footnote.weight(.medium).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .glassSurface(cornerRadius: 8, inset: true)
                        }
                    }
                    .padding(12)
                    .glassSurface(cornerRadius: 21)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Other versions: \(others.joined(separator: ", "))")
                }
            }
        }
    }

    @ViewBuilder
    private var detailRows: some View {
        if let record {
            InfoRow(name: "Version", value: record.version, first: true)
            if let version = installed.version(of: identifier) {
                InfoRow(name: "Installed", value: version)
            }
            InfoRow(name: "Section", value: PackageCatalog.displaySection(record.section))
            if let author = record.author {
                InfoRow(name: "Author", value: Person.name(author))
            }
            if let maintainer = record.maintainer {
                InfoRow(name: "Maintainer", value: Person.name(maintainer))
            }
            if let size = record.size {
                InfoRow(name: "Download Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            InfoRow(name: "Identifier", value: record.package, monospaced: true)
            InfoRow(name: "Source", value: source.title)
            if let depends = record.depends, !depends.isEmpty {
                InfoRow(name: "Depends", value: depends)
            }
        } else {
            Text("This source no longer lists this package. Refresh your sources to update the list.")
                .font(.subheadline)
                .foregroundColor(Palette.muted)
                .padding(13)
        }
    }
}

/// Install, Upgrade and Remove. Each queues the change; the Queue tab
/// reviews it with apt before anything happens.
private struct PackageActions: View {
    let source: SourceInfo
    let identifier: String
    let name: String
    /// The newest version this source offers; nil when it no longer lists
    /// the package.
    let available: String?
    /// The Architecture field of that version's record.
    let architecture: String?
    let isPaid: Bool
    @EnvironmentObject private var installed: InstalledPackagesModel
    @EnvironmentObject private var queue: QueueModel
    @EnvironmentObject private var accounts: PaymentAccounts
    @EnvironmentObject private var sources: SourcesModel
    @State private var offer: PaidOffer = .loading
    @State private var buying = false
    @State private var problem: String?

    /// What Codling knows about buying a paid package.
    enum PaidOffer: Equatable {
        case loading
        /// The source sells it on its own website, not to package managers.
        case noProvider
        /// The request did not get through; it can be tried again.
        case failed(String)
        /// The provider answered that it does not sell it, with its reason.
        case refused(String)
        /// Signed out, the provider did not tell the price; signed in, it
        /// will.
        case signInFirst(endpoint: URL)
        case ready(endpoint: URL, price: PaymentProvider.Price)
    }

    var body: some View {
        let installedVersion = installed.version(of: identifier)
        let upgradable = installedVersion.flatMap { current in
            available.map { DebianVersion($0) > DebianVersion(current) }
        } ?? false
        VStack(alignment: .leading, spacing: 8) {
            if let queued = queue.operation(for: identifier) {
                HStack {
                    Label(queuedText(queued, installed: installedVersion != nil), systemImage: "clock.fill")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Take Off Queue") {
                        queue.remove(identifier)
                    }
                    .buttonStyle(TintedButtonStyle())
                    .frame(maxWidth: 160)
                }
                Text("Review it in the Queue tab.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 10) {
                    if installedVersion == nil {
                        if available != nil {
                            if isPaid {
                                paidButton(update: false)
                            } else {
                                action("GET", .install(identifier))
                            }
                        }
                    } else {
                        if upgradable {
                            if isPaid {
                                paidButton(update: true)
                            } else {
                                action("UPDATE", .install(identifier))
                            }
                        }
                        action("REMOVE", .remove(identifier), destructive: true)
                    }
                }
                if isPaid, let note = paidNote(needed: available != nil && (installedVersion == nil || upgradable)) {
                    Text(note)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: accounts.revision) {
            if isPaid {
                await loadOffer()
            }
        }
        .alert("Purchase", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    /// An action as a glass capsule, its label in the text color, or red
    /// for removing.
    private func action(_ title: String, _ operation: PackageOperation, destructive: Bool = false,
                        purchase: PurchaseRequest? = nil) -> some View {
        Button(title) {
            queue.add(operation, name: name, purchase: purchase)
        }
        .buttonStyle(CapsuleButtonStyle(color: destructive ? .red : Palette.text))
        // VoiceOver spells a word in capitals letter by letter.
        .accessibilityLabel(title.capitalized)
    }

    // MARK: Paid packages

    private var provider: PaymentAccounts.Provider? {
        switch offer {
        case .ready(let endpoint, _), .signInFirst(let endpoint):
            return accounts.provider(at: endpoint)
        default:
            return nil
        }
    }

    private var price: PaymentProvider.Price? {
        if case .ready(_, let price) = offer {
            return price
        }
        return nil
    }

    /// The paid package's button: GET or UPDATE once bought, its price
    /// before, which signs in first when needed.
    @ViewBuilder
    private func paidButton(update: Bool) -> some View {
        if buying || offer == .loading {
            Button {} label: {
                ProgressView()
            }
            .buttonStyle(CapsuleButtonStyle())
            .disabled(true)
            .accessibilityLabel("Loading the price")
        } else if case .failed = offer {
            Button("TRY AGAIN") {
                Task { await loadOffer() }
            }
            .buttonStyle(CapsuleButtonStyle())
            .accessibilityLabel("Try Again")
        } else if case .signInFirst = offer, let provider {
            Button("SIGN IN") {
                Task { await signIn(provider) }
            }
            .buttonStyle(CapsuleButtonStyle())
            .accessibilityLabel("Sign In")
        } else if let provider, let price, let available {
            if price.purchased {
                action(update ? "UPDATE" : "GET", .install(identifier),
                       purchase: PurchaseRequest(endpoint: provider.endpoint, providerName: provider.name,
                                                 repo: source.source.uri, version: available,
                                                 architecture: architecture))
            } else if price.available {
                Button(price.price ?? "BUY") {
                    if accounts.isSignedIn(provider) {
                        ConfirmPopup.show(.init(symbol: "creditcard", color: .blue, title: confirmTitle,
                                                message: confirmMessage, confirmTitle: confirmButton)) {
                            Task { await buy() }
                        }
                    } else {
                        Task { await signIn(provider) }
                    }
                }
                .buttonStyle(CapsuleButtonStyle())
                .accessibilityLabel(price.price.map { "Buy for \($0)" } ?? "Buy")
            }
        }
    }

    /// A line under the paid package's button, when it needs one.
    private func paidNote(needed: Bool) -> String? {
        guard needed else { return nil }
        switch offer {
        case .loading:
            return nil
        case .noProvider:
            return "\(source.title) does not sell this package to package managers. Buy it on the source's website."
        case .failed(let message), .refused(let message):
            return message
        case .signInFirst:
            let seller = provider?.name ?? source.title
            return "\(seller) did not show this package's price without an account. "
                + "Sign in to \(seller) to buy it, or to download it if you already did."
        case .ready(_, let price):
            guard let provider else { return nil }
            if !price.available && !price.purchased {
                return "\(provider.name) does not sell this package right now."
            }
            if !price.purchased && !accounts.isSignedIn(provider) {
                return "Sign in to \(provider.name) to buy it, or to download it if you already did."
            }
            return nil
        }
    }

    private func loadOffer() async {
        await accounts.discover(sources: sources)
        guard let provider = accounts.provider(forSource: source.id) else {
            offer = accounts.discovered ? .noProvider : .loading
            return
        }
        do {
            offer = .ready(endpoint: provider.endpoint, price: try await accounts.price(of: identifier, at: provider))
        } catch is PaymentClient.PriceNeedsSignIn {
            offer = .signInFirst(endpoint: provider.endpoint)
        } catch let failure as PaymentProvider.Failure {
            offer = failure.fromProvider ? .refused(failure.message) : .failed(failure.message)
        } catch {
            offer = .failed("\(error)")
        }
    }

    private func signIn(_ provider: PaymentAccounts.Provider) async {
        if let message = await accounts.signIn(provider) {
            problem = message
        }
    }

    private var confirmTitle: String {
        "Buy \(name)?"
    }

    private var confirmButton: String {
        price?.price.map { "Buy for \($0)" } ?? "Buy"
    }

    private var confirmMessage: String {
        guard let provider else { return "" }
        let cost = price?.price.map { " charges you \($0) and" } ?? ""
        return "\(provider.name)\(cost) adds \(name) to your account there. Then tap GET to install it."
    }

    private func buy() async {
        guard let provider else { return }
        buying = true
        let outcome = await accounts.buy(identifier, name: name, at: provider)
        await loadOffer()
        buying = false
        switch outcome {
        case .done:
            if price?.purchased == false {
                problem = "\(provider.name) has not confirmed the purchase yet. If you paid, open this page again in a moment."
            }
        case .cancelled:
            break
        case .failed(let message):
            problem = message
        }
    }

    private func queuedText(_ operation: PackageOperation, installed: Bool) -> String {
        switch operation {
        case .install, .purchased, .file: return installed ? "Queued to upgrade" : "Queued to install"
        case .remove: return "Queued to remove"
        case .restore: return "Queued to restore"
        }
    }
}

/// A name and its value on one line, as a row of the details card; rows
/// after the first draw a line above them.
struct InfoRow: View {
    let name: String
    let value: String
    var monospaced = false
    var first = false

    var body: some View {
        NameValue {
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Palette.muted)
        } value: {
            Text(value)
                .font(monospaced ? .subheadline.monospaced() : .subheadline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            if !first {
                Rectangle()
                    .fill(Palette.divider.opacity(0.45))
                    .frame(height: 1)
                    .padding(.horizontal, 13)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A package a depiction links to, by identifier: its page when one source
/// offers it, a choice when several do.
struct PackageLookupView: View {
    let identifier: String
    @EnvironmentObject private var sources: SourcesModel
    @StateObject private var model = PackageLookupModel()

    var body: some View {
        Group {
            if !model.loaded {
                ProgressView()
            } else if model.offers.count == 1, let offer = model.offers.first, let info = sources.info(for: offer.source) {
                PackageView(source: info, identifier: offer.package, summary: offer)
            } else if model.offers.isEmpty {
                Text("None of your sources offers \(identifier).")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        CardHeading(title: "Offered by", symbol: "tray.full")
                        let offers = model.offers.filter { sources.info(for: $0.source) != nil }
                        CardRows(items: offers, dividerInset: 72) { offer in
                            if let info = sources.info(for: offer.source) {
                                NavigationLink(destination: PackageView(source: info, identifier: offer.package, summary: offer)) {
                                    CatalogCardRow(package: offer, source: info, showSource: true)
                                }
                                .buttonStyle(CardRowButtonStyle())
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .background(WallBackground())
                .navigationTitle(identifier)
            }
        }
        .task {
            await model.load(store: sources.store, identifier: identifier)
        }
    }
}

/// A native depiction that another depiction links to.
struct DepictionPageView: View {
    let url: URL
    let title: String
    @StateObject private var router = DepictionRouter()
    @State private var phase: Phase = .loading

    enum Phase {
        case loading
        case loaded(NativeDepiction)
        case failed(String)
    }

    var body: some View {
        ScrollView {
            switch phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(32)
            case .loaded(let depiction):
                NativeDepictionContent(depiction: depiction)
                    .padding(.vertical, 8)
                    .pageColumn(maxWidth: PageLayout.packageWidth)
            case .failed(let message):
                VStack(spacing: 10) {
                    Text(message)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {
                        Task { await load() }
                    }
                }
                .padding(32)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .depictionRouting(router, base: url)
    }

    private func load() async {
        phase = .loading
        do {
            let data = try await MediaLoader.shared.data(from: url)
            let depiction = try await Task.detached(priority: .userInitiated) {
                try NativeDepiction.parse(data, base: url)
            }.value
            phase = .loaded(depiction)
        } catch let error as MediaLoader.LoadError {
            phase = .failed("The page could not be loaded. \(error.message)")
        } catch {
            phase = .failed("The page could not be read: it is not a valid Sileo depiction.")
        }
    }
}
