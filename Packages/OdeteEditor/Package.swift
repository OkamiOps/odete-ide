// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OdeteEditor",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "OdeteEditor", targets: ["OdeteEditor"]),
    ],
    dependencies: [
        .package(path: "../OdeteI18n"),
        .package(path: "../OdeteCore"),
        .package(url: "https://github.com/simonbs/Runestone.git", from: "0.5.2"),
        .package(url: "https://github.com/simonbs/TreeSitterLanguages.git", from: "0.1.10"),
    ],
    targets: [
        .target(
            name: "OdeteEditor",
            dependencies: [
                .product(name: "OdeteI18n", package: "OdeteI18n"),
                .product(name: "OdeteCore", package: "OdeteCore"),
                .product(name: "Runestone", package: "Runestone"),
                .product(name: "TreeSitterHTMLRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterCSSRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterJavaScriptRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterTypeScriptRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterTSXRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterJSONRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterMarkdownRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterMarkdownInlineRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterSwiftRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterYAMLRunestone", package: "TreeSitterLanguages"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OdeteEditorTests",
            dependencies: ["OdeteEditor"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
