// swift-tools-version:5.9
import PackageDescription

// SwiftPM only, no Xcode project: builds with the Command Line Tools on macOS 13+.
// Universal (x86_64 + arm64) .app is assembled by Scripts/build-app.sh.
let package = Package(
    name: "Clementine",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Clementine",
            path: "Sources/Clementine",
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("PDFKit", .when(platforms: [.macOS])),
                .linkedFramework("Quartz", .when(platforms: [.macOS])),
                .linkedFramework("ImageIO", .when(platforms: [.macOS])),
                .linkedFramework("UniformTypeIdentifiers", .when(platforms: [.macOS])),
            ]
        )
    ]
)
