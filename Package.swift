// swift-tools-version:5.9
// Kajo builds with SwiftPM so the terminal engine (SwiftTerm) can be a declared
// dependency instead of vendored source. `make build` / `make dev` drive `swift build`
// and assemble the .app bundle around the produced binary (see Makefile).
import PackageDescription

let package = Package(
    name: "Kajo",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
    ],
    targets: [
        .executableTarget(
            name: "Kajo",
            dependencies: ["SwiftTerm"],
            path: "Sources"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
