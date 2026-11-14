// swift-tools-version: 5.10
import PackageDescription

// The app's display name lives in Resources/Info.plist and scripts/build-app.sh (APP_NAME).
// The Swift target keeps a neutral name so renaming the product never touches code.
let package = Package(
    name: "TeamPointer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TeamPointer",
            path: "Sources/TeamPointer"
        )
    ]
)
