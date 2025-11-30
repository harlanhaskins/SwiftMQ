// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftMQ",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "SwiftMQ",
            targets: ["SwiftMQ"]
        ),
        .executable(
            name: "TestServer",
            targets: ["TestServer"]
        ),
        .executable(
            name: "TestClient",
            targets: ["TestClient"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.3.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "CSwiftMQShims",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SwiftMQ",
            dependencies: [
                "CSwiftMQShims",
                .product(name: "Atomics", package: "swift-atomics")
            ],
            swiftSettings: [
                .enableUpcomingFeature("InternalImportsByDefault")
            ]
        ),
        .testTarget(
            name: "SwiftMQTests",
            dependencies: [
                "SwiftMQ"
            ]
        ),
        .executableTarget(
            name: "TestServer",
            dependencies: ["SwiftMQ"]
        ),
        .executableTarget(
            name: "TestClient",
            dependencies: ["SwiftMQ"]
        ),
    ]
)
