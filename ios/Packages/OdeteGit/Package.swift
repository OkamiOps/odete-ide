// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OdeteGit",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "OdeteGit", targets: ["OdeteGit"]),
    ],
    dependencies: [
        .package(path: "../OdeteI18n"),
        .package(path: "../OdeteCore"),
    ],
    targets: [
        .binaryTarget(name: "Clibgit2", path: "../../Vendor/libgit2/libgit2.xcframework"),
        .target(
            name: "OdeteGit",
            dependencies: [
                .product(name: "OdeteI18n", package: "OdeteI18n"),
                "Clibgit2",
                .product(name: "OdeteCore", package: "OdeteCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("iconv"),
            ]
        ),
        .testTarget(name: "OdeteGitTests", dependencies: ["OdeteGit"]),
    ]
)
