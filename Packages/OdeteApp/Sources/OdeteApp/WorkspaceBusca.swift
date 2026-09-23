import Foundation
import OdeteFiles
import OdeteI18n

/// Trocar tudo na busca do projeto.
///
/// Antes a troca ia direto ao disco de todo arquivo e, depois, relia os buffers — e
/// `reloadBuffer` marcava a aba como limpa: o que estava digitado e não salvo sumia. E a
/// troca usava outra regex que a busca, então trocava outra coisa que a lista mostrava.
/// Agora a busca e a troca olham os mesmos textos (a aba aberta, com o que não foi salvo;
/// o disco dos fechados) com a mesma `ConsultaDeTexto`.
public extension WorkspaceModel {
    /// Os textos das abas abertas, por caminho: onde a busca e a troca do projeto olham no
    /// lugar do disco.
    func textosAbertos() -> [String: String] {
        var out: [String: String] = [:]
        for t in tabs where !naoEhTexto.contains(t.path) {
            out[t.path] = buffers[t.path]
        }
        return out
    }

    /// Quantas trocas cada arquivo teria — a mesma conta de `trocarNoProjeto`, sem gravar.
    struct PreviaDaTroca: Equatable {
        public var arquivos: [ArquivoDaTroca] = []
        public var total: Int {
            arquivos.reduce(0) { $0 + $1.trocas }
        }
    }

    struct ArquivoDaTroca: Equatable, Identifiable {
        public var path: String
        public var trocas: Int
        public var id: String {
            path
        }
    }

    func previaDaTroca(_ consulta: ConsultaDeTexto, por troca: String, em paths: [String]) -> PreviaDaTroca {
        guard let re = try? consulta.expressao() else { return PreviaDaTroca() }
        var p = PreviaDaTroca()
        for path in paths {
            guard let texto = textoParaTrocar(path),
                  let r = try? consulta.trocar(em: texto, por: troca, re), r.trocas > 0, r.texto != texto
            else { continue }
            p.arquivos.append(ArquivoDaTroca(path: path, trocas: r.trocas))
        }
        return p
    }

    /// Faz a troca: na aba aberta, no texto dela — que chega ao editor como um passo do
    /// desfazer —; no arquivo fechado, no disco.
    ///
    /// Aba que estava limpa é gravada em seguida (passando pela conferência de conflito
    /// com o disco); aba com alteração não salva fica como estava, suja, com a troca por
    /// cima do que a pessoa digitou — gravar isso sem ela pedir seria gravar o que ela
    /// ainda não quis gravar.
    @discardableResult
    func trocarNoProjeto(
        _ consulta: ConsultaDeTexto,
        por troca: String,
        em paths: [String]
    ) -> (arquivos: Int, trocas: Int) {
        let re: NSRegularExpression
        do {
            re = try consulta.expressao()
        } catch {
            self.error = error.localizedDescription
            return (0, 0)
        }
        var arquivos = 0
        var trocas = 0
        var falhas: [String] = []
        for path in paths {
            guard let texto = textoParaTrocar(path),
                  let r = try? consulta.trocar(em: texto, por: troca, re), r.trocas > 0, r.texto != texto
            else { continue }
            if let aba = tabs.first(where: { $0.path == path }), buffers[path] != nil {
                let estavaLimpa = !aba.isDirty
                setText(r.texto, for: path)
                if estavaLimpa {
                    save(path)
                }
            } else {
                do {
                    try ops.write(path, r.texto)
                } catch {
                    falhas.append(path)
                    continue
                }
            }
            arquivos += 1
            trocas += r.trocas
        }
        if !falhas.isEmpty {
            error = tr("Não deu para gravar: %1$@", falhas.joined(separator: ", "))
        }
        reload()
        git.agendarMarcas()
        return (arquivos, trocas)
    }

    /// O texto que a troca vê: o da aba aberta, ou o do disco.
    private func textoParaTrocar(_ path: String) -> String? {
        if tabs.contains(where: { $0.path == path }), !naoEhTexto.contains(path), let aberto = buffers[path] {
            return aberto
        }
        guard let u = try? ops.url(path) else { return nil }
        return TextSearch.ler(u)
    }
}
