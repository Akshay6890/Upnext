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
        // The widget (Sources/UpnextWidget) isn't built here: macOS 26+ only
        // runs widgets built as a real Xcode app extension, so it lives in
        // UpnextWidget.xcodeproj and build-app.sh builds it with xcodebuild.
        .testTarget(
            name: "UpnextCoreTests",
            dependencies: ["UpnextCore"]
        ),
    ]
)
