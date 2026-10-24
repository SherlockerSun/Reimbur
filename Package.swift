// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Reimbur",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Reimbur", targets: ["Reimbur"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .executableTarget(name: "Reimbur", dependencies: ["CSQLite"])
    ]
)
