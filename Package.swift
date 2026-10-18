// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Novoterra",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "Novoterra",
            targets: ["Novoterra"]
        ),
    ],
    dependencies: [
        // SWCompression for raw DEFLATE decompression
        .package(url: "https://github.com/tsolomko/SWCompression.git", from: "4.8.0"),
    ],
    targets: [
        .target(
            name: "Novoterra",
            dependencies: ["SWCompression"],
            path: "Novoterra"
        ),
        .testTarget(
            name: "NovoterraTests",
            dependencies: ["Novoterra"],
            path: "NovoterraTests"
        ),
    ]
)
