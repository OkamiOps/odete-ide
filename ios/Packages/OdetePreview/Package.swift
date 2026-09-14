// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OdetePreview",
    platforms: [.iOS(.v26)],
    products: [.library(name: "OdetePreview", targets: ["OdetePreview"])],
    dependencies: [.package(path: "../OdeteCore")],
    targets: [
        .target(
            name: "OdetePreview",
            dependencies: [.product(name: "OdeteCore", package: "OdeteCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "OdetePreviewTests", dependencies: ["OdetePreview"]),
    ]
)
