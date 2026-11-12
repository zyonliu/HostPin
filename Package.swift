// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HostPin",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HostPin", targets: ["HostPin"]),
        .executable(name: "HostPinHelper", targets: ["HostPinHelper"])
    ],
    targets: [
        .target(name: "HostPinCore"),
        .executableTarget(name: "HostPin", dependencies: ["HostPinCore"]),
        .executableTarget(name: "HostPinHelper", dependencies: ["HostPinCore"]),
        .testTarget(name: "HostPinCoreTests", dependencies: ["HostPinCore"]),
        .testTarget(name: "HostPinEditorTests", dependencies: ["HostPin"])
    ]
)
