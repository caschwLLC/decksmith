// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Decksmith",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DecksmithApp", targets: ["DecksmithApp"]),
        .library(name: "DecksmithCore", targets: ["DecksmithCore"]),
        .library(name: "DecksmithProtocol", targets: ["DecksmithProtocol"]),
        .library(name: "DecksmithTransport", targets: ["DecksmithTransport"]),
        .library(name: "DecksmithDevice", targets: ["DecksmithDevice"]),
        .library(name: "DecksmithRendering", targets: ["DecksmithRendering"]),
        .library(name: "DecksmithRuntime", targets: ["DecksmithRuntime"]),
        .library(name: "DecksmithPluginSwift", targets: ["DecksmithPluginSwift"]),
        .library(name: "DecksmithPluginWebSocket", targets: ["DecksmithPluginWebSocket"]),
        .library(name: "DecksmithPersistence", targets: ["DecksmithPersistence"]),
        .library(name: "DecksmithObservability", targets: ["DecksmithObservability"]),
        .library(name: "DecksmithUSB", targets: ["DecksmithUSB"])
    ],
    targets: [
        .executableTarget(name: "DecksmithApp", dependencies: ["DecksmithRuntime", "DecksmithDevice", "DecksmithObservability", "DecksmithPersistence"], exclude: ["Info.plist"]),
        .target(name: "DecksmithCore"),
        .target(name: "DecksmithProtocol", dependencies: ["DecksmithCore"]),
        .target(name: "DecksmithTransport", dependencies: ["DecksmithCore"]),
        .target(name: "DecksmithDevice", dependencies: ["DecksmithCore", "DecksmithProtocol", "DecksmithTransport", "DecksmithRendering"]),
        .target(name: "DecksmithRendering", dependencies: ["DecksmithCore"]),
        .target(name: "DecksmithRuntime", dependencies: ["DecksmithCore", "DecksmithPluginSwift", "DecksmithPluginWebSocket"]),
        .target(name: "DecksmithPluginSwift", dependencies: ["DecksmithCore", "DecksmithRendering"]),
        .target(name: "DecksmithPluginWebSocket", dependencies: ["DecksmithCore"]),
        .target(name: "DecksmithPersistence", dependencies: ["DecksmithCore"]),
        .target(name: "DecksmithObservability", dependencies: ["DecksmithCore"]),
        .target(name: "DecksmithUSB", dependencies: ["DecksmithCore"]),
        .testTarget(name: "DecksmithCoreTests", dependencies: ["DecksmithCore"]),
        .testTarget(name: "DecksmithProtocolTests", dependencies: ["DecksmithProtocol"]),
        .testTarget(name: "DecksmithTransportTests", dependencies: ["DecksmithTransport"]),
        .testTarget(name: "DecksmithDeviceTests", dependencies: ["DecksmithDevice"]),
        .testTarget(name: "DecksmithRenderingTests", dependencies: ["DecksmithRendering"]),
        .testTarget(name: "DecksmithRuntimeTests", dependencies: ["DecksmithRuntime"]),
        .testTarget(name: "DecksmithPluginSwiftTests", dependencies: ["DecksmithPluginSwift"]),
        .testTarget(name: "DecksmithPluginWebSocketTests", dependencies: ["DecksmithPluginWebSocket"]),
        .testTarget(name: "DecksmithPersistenceTests", dependencies: ["DecksmithPersistence"]),
        .testTarget(name: "DecksmithAppTests", dependencies: ["DecksmithApp"]),
        .testTarget(name: "DecksmithObservabilityTests", dependencies: ["DecksmithObservability"]),
        .testTarget(name: "DecksmithUSBTests", dependencies: ["DecksmithUSB"])
    ]
)
