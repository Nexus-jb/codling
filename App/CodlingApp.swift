// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@main
struct CodlingApp: App {
    private let environment: RuntimeEnvironment
    @StateObject private var sources: SourcesModel
    @StateObject private var installed = InstalledPackagesModel()
    @StateObject private var health = PackageHealthModel()

    init() {
        let environment = RuntimeEnvironment.current()
        self.environment = environment
        MediaLoader.shared = MediaLoader(environment: environment)
        // Web depictions keep nothing between launches.
        WebDepictionView.emptyAppSession()
        _sources = StateObject(wrappedValue: SourcesModel(environment: environment))
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
                SystemCheckView(environment: environment, health: health, sources: sources)
                    .tabItem { Label("System", systemImage: "gearshape") }
            }
            .environmentObject(sources)
            .environmentObject(installed)
            .task { await installed.load(statusPath: environment.dpkgStatusPath) }
        }
    }
}
