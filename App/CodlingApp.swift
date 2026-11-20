// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@main
struct CodlingApp: App {
    private let environment: RuntimeEnvironment
    @StateObject private var sources: SourcesModel

    init() {
        let environment = RuntimeEnvironment.current()
        self.environment = environment
        _sources = StateObject(wrappedValue: SourcesModel(environment: environment))
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                SourcesView(model: sources)
                    .tabItem { Label("Sources", systemImage: "tray.full") }
                InstalledView(environment: environment)
                    .tabItem { Label("Installed", systemImage: "shippingbox") }
                SystemCheckView(environment: environment)
                    .tabItem { Label("System", systemImage: "gearshape") }
            }
        }
    }
}
