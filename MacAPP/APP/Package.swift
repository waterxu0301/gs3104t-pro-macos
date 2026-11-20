// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GANSSKeyboard",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "GANSSKeyboard",
            path: "Sources/GANSSKeyboard"
        )
    ]
)
