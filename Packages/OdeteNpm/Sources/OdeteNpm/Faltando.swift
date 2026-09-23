import Foundation

/// O que o package.json pede e node_modules não tem.
///
/// Substitui o `EsmFallback`, que mandava o que faltava para o esm.sh. Misturar o esm.sh
/// com node_modules não tem conserto: o `react-dom` de lá traz o React de lá, o app usa o
/// daqui, e com duas cópias do React todo hook quebra ("Invalid hook call", Preview
/// preto). Sem rede o esm.sh também não responde — então ele não salvava nem o caso
/// offline. O que falta agora é instalado antes de o dev server subir (`npm run dev`
/// roda o `npm install` sozinho), e sem rede o erro diz isso.
public enum Faltando {
    /// Dependências (e devDependencies) sem pasta em node_modules, ou com uma versão
    /// instalada que não atende a faixa pedida — o `git pull` que sobe o React de 18 para
    /// 19 no package.json cai aqui também. Opcionais não contam: podem faltar de propósito.
    public static func dependencias(projeto: URL) -> [String] {
        let pkg = PackageJSON(url: projeto.appending(path: "package.json"))
        guard pkg.existe else { return [] }
        var out: [String] = []
        let todas = pkg.dependencies.merging(pkg.devDependencies) { a, _ in a }
        for (nome, spec) in todas.sorted(by: { $0.key < $1.key }) {
            let instalado = PackageJSON(url: projeto.appending(path: "node_modules/\(nome)/package.json"))
            guard instalado.existe else {
                out.append(nome)
                continue
            }
            // Só a faixa do registro dá para conferir; `file:`, GitHub e URL valem pela pasta.
            guard case let .registro(real, faixa) = Pedido.de(spec) else { continue }
            if !real.isEmpty, let n = instalado.json["name"]?.comoTexto, n != real {
                out.append(nome)
                continue
            }
            let r = SemverRange(faixa)
            if let v = instalado.version.flatMap(Version.init), !r.isAny, Version(faixa) != nil || faixa.first
                .map({ "^~<>=0123456789".contains($0) }) == true, !r.satisfies(v)
            {
                out.append(nome)
            }
        }
        return out
    }
}
