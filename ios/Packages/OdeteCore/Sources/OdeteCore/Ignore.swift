import Foundation

/// Portado de `src/lib/workspace/ignore.ts`. Caminhos que ficam fora da árvore, da busca e do agente.
public enum Ignore {
    public static let noiseDirs: Set<String> = [
        "node_modules", ".git", "dist", "build", ".next", "coverage", "vendor",
    ]
    public static let noiseFiles: Set<String> = [".DS_Store"]

    public static func isNoisePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard let last = parts.last else { return false }
        if noiseFiles.contains(last) {
            return true
        }
        return parts.contains { noiseDirs.contains($0) }
    }
}
