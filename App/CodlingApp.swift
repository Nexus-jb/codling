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
    @StateObject private var systemSheet = SystemSheet()
    @StateObject private var devicePanel = DeviceInfoPanel()
    @StateObject private var accounts: PaymentAccounts
    @State private var tab: AppTab = .featured
    /// The queue, opened from the queue bar over the current page.
    @State private var queueShown = false
    /// The floating tab bar steps aside while the keyboard is up.
    @State private var keyboardShown = false
    /// The launch screen stays until the sources have refreshed once.
    @State private var launched = false

    init() {
        let environment = RuntimeEnvironment.current()
        self.environment = environment
        MediaLoader.shared = MediaLoader(environment: environment)
        // Web depictions keep nothing between launches.
        WebDepictionView.emptyAppSession()
        _sources = StateObject(wrappedValue: SourcesModel(environment: environment))
        _burrow = StateObject(wrappedValue: BurrowModel(environment: environment))
        // The queue downloads bought packages with the accounts' sign-ins.
        let accounts = PaymentAccounts(environment: environment)
        let queue = QueueModel()
        queue.accounts = accounts
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
                                .padding(.horizontal, 14)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        FloatingTabBar(selection: $tab, queueCount: queue.items.count)
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: queueBarShown)
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
                        .environment(\.device, DeviceFacts(systemVersion: environment.systemVersion, scheme: environment.scheme))
                        .tint(Palette.text)
                        .accentColor(Palette.text)
                }
                .sheet(isPresented: $systemSheet.shown) {
                    SystemCheckView(environment: environment, health: health, sources: sources, burrow: burrow)
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
                .task {
                    // Read and refresh the sources at launch, whichever tab
                    // opens first, before Featured shows.
                    await sources.start()
                    withAnimation(.easeOut(duration: 0.25)) { launched = true }
                    await accounts.discover(sources: sources)
                }
        }
    }
}
