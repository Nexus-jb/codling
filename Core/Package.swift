// swift-tools-version:5.7
// SPDX-License-Identifier: Apache-2.0
//
// CodlingCore: the parts of Codling that are plain Foundation (reading APT
// sources, Release files and package indexes), built into the app and tested
// here on any platform with `swift test --package-path Core`.

import PackageDescription

let package = Package(
    name: "CodlingCore",
    products: [
        .library(name: "CodlingCore", targets: ["CodlingCore"]),
    ],
    targets: [
        .target(name: "CodlingCore"),
        .testTarget(name: "CodlingCoreTests", dependencies: ["CodlingCore"]),
    ]
)
