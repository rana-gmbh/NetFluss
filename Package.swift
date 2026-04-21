// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "NetFluss",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "NetflussHelperShared"
        ),
        .target(
            name: "PrivilegedExecution"
        ),
        .executableTarget(
            name: "NetflussPrivilegedHelper",
            dependencies: ["NetflussHelperShared"]
        ),
        .executableTarget(
            name: "Netfluss",
            dependencies: ["PrivilegedExecution", "NetflussHelperShared"],
            resources: [
                .process("Resources")
            ]
        ),
    ]
)
