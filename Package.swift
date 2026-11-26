// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "APKInMacOS",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ShelfKit",
            targets: ["ShelfKit"]
        ),
        .library(
            name: "APKRuntime",
            targets: ["APKRuntime"]
        ),
        .library(
            name: "WineRuntime",
            targets: ["WineRuntime"]
        ),
        .executable(
            name: "APKInMacOS",
            targets: ["APKShelfApp"]
        ),
        .executable(
            name: "EXEInMacOS",
            targets: ["EXEShelfApp"]
        )
    ],
    targets: [
        .target(
            name: "ShelfKit",
            path: "Sources/ShelfKit",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "APKRuntime",
            dependencies: ["ShelfKit"],
            path: "Sources/APKRuntime",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "WineRuntime",
            dependencies: ["ShelfKit"],
            path: "Sources/WineRuntime",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "APKShelfApp",
            dependencies: ["ShelfKit", "APKRuntime"],
            path: "Sources/APKShelfApp",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "EXEShelfApp",
            dependencies: ["ShelfKit", "WineRuntime"],
            path: "Sources/EXEShelfApp",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "APKRuntimeTests",
            dependencies: ["ShelfKit", "APKRuntime"],
            path: "Tests/APKRuntimeTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "WineRuntimeTests",
            dependencies: ["ShelfKit", "WineRuntime"],
            path: "Tests/WineRuntimeTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
