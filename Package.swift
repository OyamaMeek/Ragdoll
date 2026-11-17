// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ragdoll",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Ragdoll", targets: ["Ragdoll"]), .executable(name: "RagdollService", targets: ["RagdollService"]), .library(name: "RagdollCore", targets: ["RagdollCore"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.6.1")],
    targets: [
        .target(name: "RagdollCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "Ragdoll", dependencies: ["RagdollCore"]),
        .executableTarget(name: "RagdollService", dependencies: ["RagdollCore"]),
        .testTarget(name: "RagdollCoreTests", dependencies: ["RagdollCore"])
    ]
)
