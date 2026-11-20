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

    init() {
        let environment = RuntimeEnvironment.current()
        self.environment = environment
        MediaLoader.shared = MediaLoader(environment: environment)
        _sources = StateObject(wrappedValue: SourcesModel(environment: environment))
        _burrow = StateObject(wrappedValue: BurrowModel(environment: environment))
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                SourcesView(model: sources)
                    .tabItem { Label("Sources", systemImage: "tray.full") }
                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                InstalledView(environment: environment, model: installed)
                    .tabItem { Label("Installed", systemImage: "shippingbox") }
                QueueView(environment: environment, queue: queue)
                    .tabItem { Label("Queue", systemImage: "tray.and.arrow.down") }
                    .badge(queue.items.count)
                SystemCheckView(environment: environment, health: health, sources: sources, burrow: burrow)
                    .tabItem { Label("System", systemImage: "gearshape") }
            }
            .environmentObject(sources)
            .environmentObject(installed)
            .environmentObject(queue)
            .environment(\.device, DeviceFacts(systemVersion: environment.systemVersion, scheme: environment.scheme))
            .task { await installed.load(statusPath: environment.dpkgStatusPath) }
        }
    }
}
