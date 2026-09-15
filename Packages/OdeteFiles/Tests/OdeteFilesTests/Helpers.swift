import Foundation

func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appending(
        path: "odete-files-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
