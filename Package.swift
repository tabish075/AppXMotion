// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppXMotion",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "AppXMotion", targets: ["AppXMotion"])],
    targets: [
        .executableTarget(
            name: "AppXMotion",
            path: "Sources/AppXMotion",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
