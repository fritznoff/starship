// swift-tools-version: 5.9
import PackageDescription
import Foundation

// FM_FLOATER_AMBIENT_DISABLED=1 builds the app without the optional Metal module.
let ambient = ProcessInfo.processInfo.environment["FM_FLOATER_AMBIENT_DISABLED"] != "1"

let package = Package(
    name: "DeskFloater",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DeskFloater", targets: ["DeskFloater"])
    ],
    targets: [
        .executableTarget(
            name: "DeskFloater",
            dependencies: ambient ? ["FloaterAmbient"] : [],
            path: "Sources"
        ),
        .testTarget(
            name: "DeskFloaterTests",
            dependencies: ambient ? ["DeskFloater", "FloaterAmbient"] : ["DeskFloater"],
            path: "Tests/DeskFloaterTests"
        )
    ] + (ambient ? [.target(name: "FloaterAmbient", path: "Ambient")] : [])
)
