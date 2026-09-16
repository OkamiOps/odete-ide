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
                .product(name: "TreeSitterAstroRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterSvelteRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterRustRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterCRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterCPPRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterCSharpRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterGoRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterJavaRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterPythonRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterRubyRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterPHPRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterBashRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterSQLRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterTOMLRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterLuaRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterPerlRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterRRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterHaskellRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterElixirRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterElmRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterOCamlRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterJuliaRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterLaTeXRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterSCSSRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterCommentRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterJSDocRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterRegexRunestone", package: "TreeSitterLanguages"),
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
