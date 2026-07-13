// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WacomDTH2420Driver",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "wacomdriver", targets: ["wacomdriver"]),
        .library(name: "WacomDriverCore", targets: ["WacomDriverCore"]),
    ],
    targets: [
        // C shim over IOHIDManager (device open + raw input report delivery).
        .target(
            name: "CWacomHID",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // Pure-Swift protocol logic: report parsing + event mapping.
        // Kept dependency-free so it is unit-testable without hardware.
        .target(name: "WacomDriverCore", dependencies: ["CWacomHID"]),
        // The daemon: wires HID transport -> parser -> CGEvent emitter.
        .executableTarget(
            name: "wacomdriver",
            dependencies: ["WacomDriverCore", "CWacomHID"],
            // Single-threaded AppKit agent (everything on the main run loop); use the
            // Swift 5 language mode to avoid false-positive strict-concurrency errors.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(name: "WacomDriverCoreTests", dependencies: ["WacomDriverCore"]),
    ]
)
