// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KickUnblockCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "KickUnblockCore", targets: ["KickUnblockCore"])],
    targets: [
        .target(name: "KickUnblockCore", path: "Sources/KickUnblockCore"),
    ]
)
