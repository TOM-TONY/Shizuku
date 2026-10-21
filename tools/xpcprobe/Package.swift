// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "xpcprobe",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../third_party/Shizuku/Core")],
    targets: [
        .executableTarget(
            name: "xpcprobe",
            dependencies: [.product(name: "Core", package: "Core")],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
    ],
    swiftLanguageModes: [.v5]
)
