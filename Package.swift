// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "TNG",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.99.0"),
        .package(url: "https://github.com/vapor/leaf.git", from: "4.3.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.6.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0" ..< "5.0.0"),
        .package(url: "https://codeberg.org/sbeitzel/ABCKit.git", from: "0.1.1"),
        .package(url: "https://github.com/sbeitzel/SVGPDFKit.git", from: "0.2.0"),
    ],
    targets: [
        // Library target — imported by both the executable and the test target.
        .target(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Leaf", package: "leaf"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "ABCKit", package: "ABCKit"),
                .product(name: "SVGPDFKit", package: "SVGPDFKit"),
            ],
            path: "Sources/App",
            swiftSettings: swiftSettings
        ),
        // Executable target — `swift run TNG [subcommand]`
        .executableTarget(
            name: "TNG",
            dependencies: [
                .target(name: "App"),
            ],
            path: "Sources/Run",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                .target(name: "App"),
                .product(name: "XCTVapor", package: "vapor"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Tests/AppTests",
            swiftSettings: swiftSettings
        ),
    ]
)

var swiftSettings: [SwiftSetting] {
    []
}
