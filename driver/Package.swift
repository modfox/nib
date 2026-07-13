// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nib",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "nib", targets: ["nib"]),
        .library(name: "NibCore", targets: ["NibCore"]),
    ],
    targets: [
        // C shim over IOHIDManager (device open + raw input report delivery).
        .target(
            name: "CNibHID",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // Pure-Swift protocol logic: report parsing + event mapping.
        // Kept dependency-free so it is unit-testable without hardware.
        .target(name: "NibCore", dependencies: ["CNibHID"]),
        // The daemon: wires HID transport -> parser -> CGEvent emitter.
        .executableTarget(
            name: "nib",
            dependencies: ["NibCore", "CNibHID"],
            // Single-threaded AppKit agent (everything on the main run loop); use the
            // Swift 5 language mode to avoid false-positive strict-concurrency errors.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(name: "NibCoreTests", dependencies: ["NibCore"]),
    ]
)
