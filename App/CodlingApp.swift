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

    init() {
        let environment = RuntimeEnvironment.current()
        self.environment = environment
        MediaLoader.shared = MediaLoader(environment: environment)
        _sources = StateObject(wrappedValue: SourcesModel(environment: environment))
        _burrow = StateObject(wrappedValue: BurrowModel(environment: environment))
    }

    /// Featured, Sources, Search, Queue and Installed. On iOS 26 the tab
    /// bar is the system's Liquid Glass bar, which keeps Search apart as a
    /// round button at its end.
    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 26, *) {
            TabView {
                Tab("Featured", systemImage: "star") {
                    FeaturedView()
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
            TabView {
                FeaturedView()
                    .tabItem { Label("Featured", systemImage: "star") }
                SourcesView(model: sources)
                    .tabItem { Label("Sources", systemImage: "tray.full") }
                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                QueueView(environment: environment, queue: queue)
                    .tabItem { Label("Queue", systemImage: "tray.and.arrow.down") }
                    .badge(queue.items.count)
                InstalledView(environment: environment, model: installed)
                    .tabItem { Label("Installed", systemImage: "shippingbox") }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            tabs
                .sheet(isPresented: $systemSheet.shown) {
                    SystemCheckView(environment: environment, health: health, sources: sources, burrow: burrow)
                        .environmentObject(sources)
                        .environmentObject(installed)
                        .environmentObject(queue)
                }
                .environmentObject(systemSheet)
                .environmentObject(sources)
                .environmentObject(installed)
                .environmentObject(queue)
                .environment(\.device, DeviceFacts(systemVersion: environment.systemVersion, scheme: environment.scheme))
                .task { await installed.load(statusPath: environment.dpkgStatusPath) }
        }
    }
}
