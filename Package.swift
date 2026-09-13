// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EditHere",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "EditHereCore", targets: ["EditHereCore"]),
        .library(name: "EditHere", targets: ["EditHere"]),
        .library(name: "EditHereFileDestination", targets: ["EditHereFileDestination"]),
        .library(name: "EditHereLocalHostDestination", targets: ["EditHereLocalHostDestination"])
    ],
    targets: [
        .target(
            name: "EditHereCore",
            path: "Sources/EditHereCore"
        ),
        .target(
            name: "EditHere",
            dependencies: ["EditHereCore"],
            path: "Sources/EditHere"
        ),
        .target(
            name: "EditHereFileDestination",
            dependencies: ["EditHereCore"],
            path: "Sources/EditHereFileDestination"
        ),
        .target(
            name: "EditHereLocalHostDestination",
            dependencies: ["EditHereCore"],
            path: "Sources/EditHereLocalHostDestination"
        ),
        .testTarget(
            name: "EditHereCoreTests",
            dependencies: ["EditHereCore"],
            path: "Tests/EditHereCoreTests"
        ),
        .testTarget(
            name: "EditHereTests",
            dependencies: ["EditHere", "EditHereCore"],
            path: "Tests/EditHereTests"
        ),
        .testTarget(
            name: "EditHereFileDestinationTests",
            dependencies: ["EditHereCore", "EditHereFileDestination"],
            path: "Tests/EditHereFileDestinationTests"
        ),
        .testTarget(
            name: "EditHereLocalHostDestinationTests",
            dependencies: ["EditHereCore", "EditHereLocalHostDestination"],
            path: "Tests/EditHereLocalHostDestinationTests"
        )
    ]
)
