// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HydrationCoach",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "HydrationCoach", targets: ["HydrationCoach"])],
    targets: [
        .target(name: "HydrationCoach"),
        .testTarget(name: "HydrationCoachTests", dependencies: ["HydrationCoach"])
    ]
)
