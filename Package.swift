// swift-tools-version: 5.10
import PackageDescription

// The app's display name lives in scripts/build-app.sh (APP_NAME).
// The Swift target keeps a neutral name so renaming the product never touches code.
let package = Package(
    name: "TeamPointer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "TeamPointer",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift")
            ],
            path: "Sources/TeamPointer"
        )
    ]
)
