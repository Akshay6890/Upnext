// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Upnext",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Upnext", targets: ["Upnext"]),
    ],
    targets: [
        // Platform-independent logic: version comparison, Sparkle appcast parsing,
        // Homebrew catalog parsing, Info.plist reading. Unit tested.
        .target(name: "UpnextCore"),
        // The macOS app: SwiftUI UI, scanning, downloading and installing.
        .executableTarget(
            name: "Upnext",
            dependencies: ["UpnextCore"]
        ),
        .testTarget(
            name: "UpnextCoreTests",
            dependencies: ["UpnextCore"]
        ),
    ]
)
