// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "NetFluss",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // In-app updates. Pinned exactly: bump deliberately, together with the
        // Sparkle tooling (sign_update / generate_appcast) used by the release CI.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
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
            dependencies: [
                "PrivilegedExecution",
                "NetflussHelperShared",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                // Sparkle.framework ships in NetFluss.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
    ]
)
