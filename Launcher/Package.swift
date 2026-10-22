// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FangcunLauncher",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LauncherCore", targets: ["LauncherCore"]), .executable(name: "FangcunLauncher", targets: ["FangcunLauncher"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "LauncherCore"),
        .executableTarget(name: "FangcunLauncher", dependencies: ["LauncherCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "LauncherCoreTests", dependencies: ["LauncherCore"])
    ]
)
