import Foundation
@testable import OdeteSwift
import Testing

struct PackageTests {
    @Test @MainActor func findsSwiftpmAndLooseFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "odete-pg-\(UUID().uuidString)")
        let pkg = root.appending(path: "Meu.swiftpm")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try "// swift-tools-version: 5.9\nlet package = Package(name: \"Meu\", products: [.iOSApplication(name: \"Meu App\", targets: [\"AppModule\"])])"
            .write(
                to: pkg.appending(path: "Package.swift"),
                atomically: true,
                encoding: .utf8
            )
        try "import SwiftUI\n@main struct MyApp: App { var body: some Scene { WindowGroup { ContentView() } } }".write(
            to: pkg.appending(path: "MyApp.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "import SwiftUI\nstruct ContentView: View { var body: some View { Text(\"oi\") } }".write(
            to: pkg.appending(path: "ContentView.swift"),
            atomically: true,
            encoding: .utf8
        )
        let p = try #require(PlaygroundPackage.find(in: root))
        #expect(p.isPackage && p.name == "Meu" && p.displayName == "Meu" && p.swiftFiles.map(\.lastPathComponent) == [
            "ContentView.swift",
            "MyApp.swift",
        ])
        let files = p.load(projectRoot: root)
        #expect(files.map(\.path) == ["Meu.swiftpm/ContentView.swift", "Meu.swiftpm/MyApp.swift"])
        let prog = Program(files: files)
        #expect(prog.rootName == "ContentView" && prog.diagnostics.isEmpty)
        // solto
        let loose = FileManager.default.temporaryDirectory.appending(path: "odete-pg2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        try "struct A: View { var body: some View { Text(\"a\") } }".write(
            to: loose.appending(path: "A.swift"),
            atomically: true,
            encoding: .utf8
        )
        let l = try #require(PlaygroundPackage.find(in: loose))
        #expect(!l.isPackage && Program(files: l.load(projectRoot: loose)).rootName == "A")
        #expect(PlaygroundPackage
            .find(in: FileManager.default.temporaryDirectory.appending(path: "nada-\(UUID().uuidString)")) == nil)
    }
}
