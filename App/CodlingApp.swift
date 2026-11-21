// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@main
struct CodlingApp: App {
    private let environment: RuntimeEnvironment
    @StateObject private var sources: SourcesModel
    @StateObject private var installed = InstalledPackagesModel()
    @StateObject private var health = PackageHealthModel()
    @StateObject private var queue = QueueModel()
    @StateObject private var burrow: BurrowModel
    @StateObject private var systemSheet = SystemSheet()
    @StateObject private var devicePanel = DeviceInfoPanel()
    @StateObject private var accounts: PaymentAccounts
    @State private var tab: AppTab = .featured
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
        _accounts = StateObject(wrappedValue: PaymentAccounts(environment: environment))
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
            TabView {
                Tab("Featured", systemImage: "star") {
                    FeaturedView(environment: environment)
                }
                Tab("Sources", systemImage: "tray.full") {
                    SourcesView(model: sources)
                }
                Tab("Queue", systemImage: "tray.and.arrow.down") {
                    QueueView(environment: environment, queue: queue)
                }
                .badge(queue.items.count)
                Tab("Installed", systemImage: "shippingbox") {
                    InstalledView(environment: environment, model: installed)
                }
                Tab("Search", systemImage: "magnifyingglass", role: .search) {
                    SearchView()
                }
            }
        } else {
            // The system tab bar is hidden, and the floating bar drawn after
            // iOS 26's takes its place.
            TabView(selection: $tab) {
                FeaturedView(environment: environment)
                    .floatingTabBarSpace()
                    .tag(AppTab.featured)
                SourcesView(model: sources)
                    .floatingTabBarSpace()
                    .tag(AppTab.sources)
                QueueView(environment: environment, queue: queue)
                    .floatingTabBarSpace()
                    .tag(AppTab.queue)
                InstalledView(environment: environment, model: installed)
                    .floatingTabBarSpace()
                    .tag(AppTab.installed)
                SearchView()
                    .floatingTabBarSpace()
                    .tag(AppTab.search)
            }
            .overlay(alignment: .bottom) {
                if !keyboardShown {
                    FloatingTabBar(selection: $tab, queueCount: queue.items.count)
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
