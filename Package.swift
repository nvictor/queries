// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "QueriesCore", platforms: [.macOS("27.2")], products: [.library(name: "QueriesCore", targets: ["QueriesCore"])], targets: [
    .target(name: "QueriesCore", path: "Queries/Queries/Core"),
    .target(name: "QueriesAppState", dependencies: ["QueriesCore"], path: "Queries/Queries", exclude: ["Core", "ContentView.swift", "QueryCard.swift", "QueriesApp.swift", "Assets.xcassets"], sources: ["StackViewModel.swift"]),
    .testTarget(name: "QueriesCoreTests", dependencies: ["QueriesCore", "QueriesAppState"], path: "Tests/QueriesCoreTests", resources: [.copy("Fixtures")])
], swiftLanguageModes: [.v5])
