// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FangcunLauncher",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LauncherCore", targets: ["LauncherCore"]), .executable(name: "FangcunLauncher", targets: ["FangcunLauncher"])],
    targets: [
        .target(name: "LauncherCore"),
        .executableTarget(name: "FangcunLauncher", dependencies: ["LauncherCore"]),
        .testTarget(name: "LauncherCoreTests", dependencies: ["LauncherCore"])
    ]
)
