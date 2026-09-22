import Foundation

/// Portado de `src/lib/workspace/ignore.ts`. Caminhos que ficam fora da árvore, da busca e do agente.
public enum Ignore {
    /// Onde o npm da Odete instala os pacotes num projeto do iCloud Drive: o iCloud não
    /// sincroniza nome terminado em `.nosync`, e `node_modules` vira um link para cá (ver
    /// `PastaDeModulos`, em OdeteFiles). Mora aqui porque é pasta pesada como
    /// `node_modules`, e tudo o que pula uma precisa pular a outra.
    public static let modulosForaDaNuvem = "node_modules.nosync"

    public static let noiseDirs: Set<String> = [
        "node_modules", modulosForaDaNuvem, ".git", "dist", "build", ".next", "coverage", "vendor",
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
