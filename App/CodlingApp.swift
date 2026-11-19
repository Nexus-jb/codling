// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@main
struct CodlingApp: App {
    private let environment = RuntimeEnvironment.current()

    var body: some Scene {
        WindowGroup {
            TabView {
                InstalledView(environment: environment)
                    .tabItem { Label("Installed", systemImage: "shippingbox") }
                SystemCheckView(environment: environment)
                    .tabItem { Label("System", systemImage: "gearshape") }
            }
        }
    }
}
