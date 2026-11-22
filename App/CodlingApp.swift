// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@main
struct CodlingApp: App {
    private let environment: RuntimeEnvironment
    @StateObject private var sources: SourcesModel
    @StateObject private var installed = InstalledPackagesModel()
    @StateObject private var health = PackageHealthModel()
    @StateObject private var queue: QueueModel
    @StateObject private var burrow: BurrowModel
    /// Crash reports for tweaks' developers, sent only with the user's
    /// consent (docs/reports.md).
    @StateObject private var reports: ReportsModel
    @StateObject private var systemSheet = SystemSheet()
    @StateObject private var devicePanel = DeviceInfoPanel()
    @StateObject private var accounts: PaymentAccounts
    @StateObject private var updates = UpdatesModel()
    /// A .deb opened from the share sheet or Files.
    @StateObject private var opened = OpenedFiles()
    /// Adding sources, from the Sources tab or a codling://source link.
    @StateObject private var adder = AddSourceFlow()
    /// The package a codling://package link shows.
    @State private var linkedPackage: LinkedPackage?
    /// Whether the sources are read, so that a link can be followed; one
    /// that comes before waits here.
    @State private var sourcesReady = false
    @State private var pendingLink: CodlingLink?
    /// The queue opens once the opened file's sheet is gone, to review it.
    @State private var queueAfterOpened = false
    @State private var tab: AppTab = .featured
    /// The queue, opened from the queue bar over the current page.
    @State private var queueShown = false
    /// The floating tab bar steps aside while the keyboard is up.
    @State private var keyboardShown = false
    /// The launch screen stays until the sources have refreshed once.
    @State private var launched: Bool

    init() {
        let environment = RuntimeEnvironment.current()
        self.environment = environment
        MediaLoader.shared = MediaLoader(environment: environment)
        // Web depictions keep nothing between launches.
        WebDepictionView.emptyAppSession()
        _sources = StateObject(wrappedValue: SourcesModel(environment: environment))
        // The launch screen is for the first refresh; after it Codling opens
        // on its index at once.
        _launched = State(initialValue: SourcesModel.refreshedBefore)
        _burrow = StateObject(wrappedValue: BurrowModel(environment: environment))

        // The queue downloads bought packages with the accounts' sign-ins.
        let accounts = PaymentAccounts(environment: environment)
        let queue = QueueModel()
        queue.accounts = accounts
        // The queue tells the reports what a change did, for install
        // results the user chose to share.
        let reports = ReportsModel(environment: environment)
        queue.reports = reports
        _reports = StateObject(wrappedValue: reports)
        _accounts = StateObject(wrappedValue: accounts)
        _queue = StateObject(wrappedValue: queue)
        if #unavailable(iOS 26) {
            UITabBar.appearance().isHidden = true
        }
        if #unavailable(iOS 16) {
            UITableView.appearance().backgroundColor = .clear
        }
        Palette.applyToUIKit()
    }

    /// Featured, Sources, Queue and Installed, with Search apart as a round
    /// button at the end: on iOS 26 the system's Liquid Glass tab bar, and
    /// before it a floating bar drawn after it.
    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 26, *) {
            let native = TabView(selection: $tab) {
                Tab("Featured", systemImage: "star", value: AppTab.featured) {
                    FeaturedView(environment: environment)
                }
                Tab("Sources", systemImage: "tray.full", value: AppTab.sources) {
                    SourcesView(model: sources)
                }
                Tab("Queue", systemImage: "tray.and.arrow.down", value: AppTab.queue) {
                    QueueView(environment: environment, queue: queue)
                }
                .badge(queue.items.count)
                Tab("Installed", systemImage: "shippingbox", value: AppTab.installed) {
                    InstalledView(environment: environment, model: installed)
                }
                .badge(updates.updates.count)
                Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                    SearchView()
                }
            }
            // The queue bar sits above the tab bar, where the system puts
            // a tab view's accessory.
            if #available(iOS 26.1, *) {
                native.tabViewBottomAccessory(isEnabled: queueBarShown) {
                    queueBar(glass: false)
                }
            } else {
                native.tabViewBottomAccessory {
                    if queueBarShown {
                        queueBar(glass: false)
                    }
                }
            }
        } else {
            // The system tab bar is hidden, and the floating bar drawn after
            // iOS 26's takes its place, with the queue bar above it.
            let room = queueBarShown ? QueueBar.height + 8 : 0
            TabView(selection: $tab) {
                FeaturedView(environment: environment)
                    .floatingTabBarSpace(extra: room)
                    .tag(AppTab.featured)
                SourcesView(model: sources)
                    .floatingTabBarSpace(extra: room)
                    .tag(AppTab.sources)
                QueueView(environment: environment, queue: queue)
                    .floatingTabBarSpace(extra: 0)
                    .tag(AppTab.queue)
                InstalledView(environment: environment, model: installed)
                    .floatingTabBarSpace(extra: room)
                    .tag(AppTab.installed)
                SearchView()
                    .floatingTabBarSpace(extra: room)
                    .tag(AppTab.search)
            }
            .overlay(alignment: .bottom) {
                if !keyboardShown {
                    VStack(spacing: 8) {
                        if queueBarShown {
                            queueBar(glass: true)
                                .frame(maxWidth: FloatingTabBar.maxWidth)
                                .padding(.horizontal, 14)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        FloatingTabBar(selection: $tab, queueCount: queue.items.count,
                                       updateCount: updates.updates.count)
                    }
                    .animation(UIAccessibility.isReduceMotionEnabled ? nil : .spring(response: 0.35, dampingFraction: 0.85),
                               value: queueBarShown)
                    .transition(.opacity)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardShown = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardShown = false
            }
        }
    }

    /// The queue bar shows while packages wait or apt is at work, except on
    /// the Queue tab, which shows the same, and under the queue sheet.
    private var queueBarShown: Bool {
        QueueBar.shows(queue) && tab != .queue && !queueShown
    }

    private func queueBar(glass: Bool) -> some View {
        QueueBar(queue: queue, glass: glass) {
            queueShown = true
        }
    }

    /// Follows a codling:// link: a source is offered to add, with the
    /// prompt over whatever is on screen, and a package opens in a sheet.
    @MainActor
    private func follow(_ link: CodlingLink) async {
        switch link {
        case .source(let uri):
            await adder.offerLink(uri)
        case .package(let identifier):
            // One sheet at a time: the one up goes first.
            if queueShown || systemSheet.shown || opened.shown || linkedPackage != nil {
                queueShown = false
                systemSheet.shown = false
                opened.shown = false
                linkedPackage = nil
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            linkedPackage = LinkedPackage(identifier: identifier)
        }
    }

    var body: some Scene {
        WindowGroup {
            tabs
                .overlay { DeviceInfoOverlay(panel: devicePanel) }
                .overlay {
                    if !launched {
                        LaunchView(sources: sources) {
                            withAnimation(.easeOut(duration: 0.25)) { launched = true }
                        }
                        .transition(.opacity)
                    }
                }
                .sheet(isPresented: $queueShown) {
                    QueueView(environment: environment, queue: queue, close: { queueShown = false })
                        .environmentObject(systemSheet)
                        .environmentObject(devicePanel)
                        .environmentObject(accounts)
                        .environmentObject(sources)
                        .environmentObject(installed)
                        .environmentObject(queue)
                        .environmentObject(updates)
                        .environment(\.device, DeviceFacts(systemVersion: environment.systemVersion, scheme: environment.scheme))
                        .tint(Palette.text)
                        .accentColor(Palette.text)
                }
                .sheet(isPresented: $opened.shown, onDismiss: {
                    opened.dismissed()
                    if queueAfterOpened {
                        queueAfterOpened = false
                        queueShown = true
                    }
                }) {
                    if let state = opened.state {
                        OpenedPackageView(state: state, environment: environment, queue: queue, onInstall: { package in
                            queue.addForReview(.file(package.package, token: package.token), name: package.displayName)
                            queueAfterOpened = true
                            opened.shown = false
                        }, onClose: { opened.shown = false })
                        .environmentObject(installed)
                        .tint(Palette.text)
                        .accentColor(Palette.text)
                    }
                }
                .sheet(item: $linkedPackage) { linked in
                    NavigationView {
                        PackageLookupView(identifier: linked.identifier)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Close") { linkedPackage = nil }
                                }
                            }
                    }
                    .navigationViewStyle(.stack)
                    .environmentObject(systemSheet)
                    .environmentObject(accounts)
                    .environmentObject(sources)
                    .environmentObject(installed)
                    .environmentObject(queue)
                    .environmentObject(updates)
                    .environment(\.device, DeviceFacts(systemVersion: environment.systemVersion, scheme: environment.scheme))
                    .tint(Palette.text)
                    .accentColor(Palette.text)
                }
                // iOS hands Codling a .deb shared to it or opened from Files
                // (CFBundleDocumentTypes in Info.plist), and codling:// links
                // (CFBundleURLTypes).
                .onOpenURL { url in
                    guard url.isFileURL else {
                        if let link = CodlingLink(url.absoluteString) {
                            if sourcesReady {
                                Task { await follow(link) }
                            } else {
                                pendingLink = link
                            }
                        }
                        return
                    }
                    Task {
                        // One sheet at a time: the one up goes first.
                        if queueShown || systemSheet.shown {
                            queueShown = false
                            systemSheet.shown = false
                            try? await Task.sleep(nanoseconds: 700_000_000)
                        }
                        await opened.open(url)
                    }
                }
                .sheet(isPresented: $systemSheet.shown, onDismiss: {
                    // Burrow's Safe Mode list queued a removal to review.
                    if systemSheet.queueAfterClosing {
                        systemSheet.queueAfterClosing = false
                        queueShown = true
                    }
                }) {
                    SystemCheckView(environment: environment, health: health, sources: sources, burrow: burrow)
                        .environmentObject(systemSheet)
                        .environmentObject(reports)
                        .environmentObject(sources)
                        .environmentObject(installed)
                        .environmentObject(queue)
                        .tint(Palette.text)
                        .accentColor(Palette.text)
                }
                .environmentObject(systemSheet)
                .environmentObject(devicePanel)
                .environmentObject(accounts)
                .environmentObject(sources)
                .environmentObject(installed)
                .environmentObject(queue)
                .environmentObject(updates)
                .environmentObject(adder)
                .environmentObject(reports)
                .environment(\.device, DeviceFacts(systemVersion: environment.systemVersion, scheme: environment.scheme))
                // The design draws buttons, links and the selected tab in
                // the text color.
                .tint(Palette.text)
                .accentColor(Palette.text)
                .task { await installed.load(statusPath: environment.dpkgStatusPath) }
                // apt's lists follow Codling's sources in the background, so
                // that a review need not update them first.
                .onChange(of: sources.indexGeneration) { _ in
                    queue.sourcesChanged(sources.rows.map(\.source.uri))
                }
                // The updates follow the index and the installed packages.
                .task(id: "\(sources.indexGeneration) \(sources.rows.count) \(installed.versions.hashValue)") {
                    await updates.refresh(store: sources.store, installed: installed.versions)
                }
                .task {
                    // Codling opens on the index it has, and refreshes the
                    // sources behind it when the last refresh is over half
                    // an hour old. Only the first launch, with no index yet,
                    // waits for the refresh.
                    await sources.load()
                    queue.sourcesKnown(sources.rows.map(\.source.uri))
                    adder.model = sources
                    adder.installed = installed
                    reports.sources = sources
                    reports.burrow = burrow
                    sourcesReady = true
                    if let link = pendingLink {
                        pendingLink = nil
                        Task { await follow(link) }
                    }
                    if sources.hasIndex {
                        withAnimation(.easeOut(duration: 0.25)) { launched = true }
                        await sources.start()
                    } else {
                        await sources.start()
                        withAnimation(.easeOut(duration: 0.25)) { launched = true }
                    }
                    await accounts.discover(sources: sources)
                    // Crash reports the user chose to always send go when
                    // Codling opens; no one else's leave the device.
                    if !reports.alwaysSend.isEmpty {
                        await burrow.load()
                        if let state = burrow.state {
                            await reports.prepare(state.crashLog)
                            await reports.sendAutomatically(state.crashLog, loader: state.loader)
                        }
                    }
                }
        }
    }
}

/// A package a codling://package link asked to show.
struct LinkedPackage: Identifiable {
    let identifier: String
    var id: String { identifier }
}
