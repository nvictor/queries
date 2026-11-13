// swift-tools-version: 6.0
import PackageDescription
// The package hosts core/state tests on CI's macOS 27.0 runner.
// The released app's deployment target remains macOS 27.2 in the Xcode project.
let package = Package(name: "QueriesCore", platforms: [.macOS("27.0")], products: [.library(name: "QueriesCore", targets: ["QueriesCore"])], targets: [
    .target(name: "QueriesCore", path: "Queries/Queries/Core"),
    .target(name: "QueriesAppState", dependencies: ["QueriesCore"], path: "Queries/Queries", exclude: ["Core", "ContentView.swift", "QueryCard.swift", "QueriesApp.swift", "Assets.xcassets"], sources: ["StackViewModel.swift"]),
    .testTarget(name: "QueriesCoreTests", dependencies: ["QueriesCore", "QueriesAppState"], path: "Tests/QueriesCoreTests", resources: [.copy("Fixtures")])
], swiftLanguageModes: [.v5])
