// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Liman",
    platforms: [.macOS("26.0")],
    targets: [
        // Tray uygulaması ile arka plan ajanının paylaştığı kod.
        .target(
            name: "LimanCore",
            path: "Sources/LimanCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // launchd altında çalışan arka plan servisi.
        .executableTarget(
            name: "LimanAgent",
            dependencies: ["LimanCore"],
            path: "Sources/LimanAgent",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Menü çubuğu (tray) uygulaması.
        .executableTarget(
            name: "Liman",
            dependencies: ["LimanCore"],
            path: "Sources/Liman",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("ServiceManagement"), .linkedFramework("UserNotifications")]
        ),
    ]
)
