// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MarketBar",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MarketBar", targets: ["MarketBar"])],
    targets: [
        .target(name: "TickerCore"),
        .executableTarget(name: "MarketBar", dependencies: ["TickerCore"]),
        .executableTarget(name: "TickerCoreTests", dependencies: ["TickerCore"], path: "Tests/TickerCoreTests")
    ]
)
