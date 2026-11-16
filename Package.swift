// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CcinnOpenRTB",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RTBKit", targets: ["RTBKit"]),
        .library(name: "CcinnOpenRTBKit", targets: ["CcinnOpenRTBKit"]),
        .executable(name: "CcinnOpenRTB", targets: ["CcinnOpenRTB"]),
    ],
    targets: [
        // OpenRTB 2.x/3.0, Native 1.0–1.2, VAST 2.0–4.2, macros, tracking plan, devices, validation. Foundation only.
        .target(name: "RTBKit", swiftSettings: settings),
        // Network (simulated/real dispatch, recorder, HAR), sample media, updates. No UI.
        .target(name: "CcinnOpenRTBKit", dependencies: ["RTBKit"], swiftSettings: settings),
        // SwiftUI application.
        .executableTarget(name: "CcinnOpenRTB", dependencies: ["RTBKit", "CcinnOpenRTBKit"], swiftSettings: settings),

        .testTarget(name: "RTBKitTests", dependencies: ["RTBKit"], swiftSettings: settings),
        .testTarget(name: "CcinnOpenRTBKitTests", dependencies: ["RTBKit", "CcinnOpenRTBKit"], swiftSettings: settings),
        // WebKit / AVFoundation behaviour of the app's renderers.
        .testTarget(name: "CcinnOpenRTBAppTests", dependencies: ["CcinnOpenRTB", "RTBKit", "CcinnOpenRTBKit"], swiftSettings: settings),
    ],
    swiftLanguageModes: [.v6]
)
