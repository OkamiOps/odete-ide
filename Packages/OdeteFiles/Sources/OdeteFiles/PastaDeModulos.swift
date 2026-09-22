import Foundation
import OdeteCore

/// Onde mora o `node_modules` de um projeto — e por que, no iCloud, ele mora em outro lugar.
///
/// Projeto no iCloud Drive sincroniza tudo o que tem dentro. Um `npm install` são
/// milhares de arquivos, e o iCloud sobe cada um deles: trabalho dos processos do sistema,
/// que não aparece na conta de CPU do app mas aparece na bateria e no calor do iPad. E
/// não serve para nada — `node_modules` se refaz a partir do `package-lock.json`.
///
/// O iCloud não sincroniza item cujo nome termina em `.nosync`. Então, no iCloud, os
/// pacotes moram de verdade em `node_modules.nosync`, e `node_modules` vira um link
/// relativo para ela. Quem procura módulo — o runtime, o bundler, o `.bin` — continua
/// achando tudo em `node_modules`, e o link, que é um arquivo minúsculo, pode sincronizar
/// à vontade. O `.git` não entra nessa regra: é justamente para o histórico sobreviver a
/// uma desinstalação que os projetos moram no iCloud.
///
/// Projeto local fica exatamente como sempre foi: `node_modules` é uma pasta de verdade.
public enum PastaDeModulos {
    public static let nome = "node_modules"
    public static let nomeForaDaNuvem = Ignore.modulosForaDaNuvem

    /// O projeto mora no iCloud Drive?
    ///
    /// Duas pistas, porque nenhuma sozinha cobre tudo: o caminho (o container do app e o
    /// iCloud Drive do app Arquivos ficam em `Library/Mobile Documents`, mesmo quando a
    /// pasta veio de um bookmark) e o próprio sistema dizendo que o item é ubíquo. Não
    /// chama `url(forUbiquityContainerIdentifier:)`: ela pode demorar, e quem pergunta
    /// aqui é a abertura do projeto.
    public static func naNuvem(_ raiz: URL) -> Bool {
        if raiz.standardizedFileURL.path.contains("/Mobile Documents/") {
            return true
        }
        return (try? raiz.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    /// O que existe hoje no lugar de `node_modules`.
    enum Situacao: Equatable {
        case nada
        case pasta
        /// Link que a Odete criou, para `node_modules.nosync`.
        case nosso
        /// Link que a pessoa criou, para outro lugar. Não é da nossa conta.
        case alheio
        case outro
    }

    static func situacao(_ raiz: URL) -> Situacao {
        let caminho = raiz.appending(path: nome).path
        let fm = FileManager.default
        // `attributesOfItem` não segue link: é o que diz se `node_modules` é o link ou a
        // pasta. `fileExists` seguiria e diria "pasta" para os dois.
        guard let tipo = (try? fm.attributesOfItem(atPath: caminho))?[.type] as? FileAttributeType else {
            return .nada
        }
        switch tipo {
        case .typeDirectory: return .pasta
        case .typeSymbolicLink:
            let destino = (try? fm.destinationOfSymbolicLink(atPath: caminho)) ?? ""
            return destino == nomeForaDaNuvem || destino == raiz.appending(path: nomeForaDaNuvem).path
                ? .nosso : .alheio
        default: return .outro
        }
    }

    /// Deixa `node_modules` pronto para receber pacotes.
    ///
    /// No iCloud, garante a pasta `node_modules.nosync` e o link apontando para ela, seja
    /// qual for o estado de partida: projeto antigo com a pasta de verdade, link apagado
    /// por um `rm -rf node_modules`, pasta real apagada e link sobrando. Fora do iCloud,
    /// cria a pasta como sempre.
    ///
    /// Sobrou só a pasta real, sem o link: alguém apagou `node_modules` — no terminal, o
    /// `rm -rf` leva só o link. O que a pessoa quis foi começar do zero, então a pasta
    /// órfã vai embora antes de a instalação recomeçar, em vez de ser reaproveitada
    /// calada.
    ///
    /// Se o sistema de arquivos recusar o link, volta para a pasta comum: instalar
    /// sincronizando é melhor que não instalar.
    public static func preparar(_ raiz: URL, nuvem: Bool) throws {
        let fm = FileManager.default
        let link = raiz.appending(path: nome)
        let real = raiz.appending(path: nomeForaDaNuvem)
        let situacao = situacao(raiz)
        guard nuvem else {
            // Projeto que saiu do iCloud com o arranjo feito continua funcionando pelo
            // link; só precisa que a pasta do outro lado exista.
            if situacao == .nosso {
                try fm.createDirectory(at: real, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: link, withIntermediateDirectories: true)
            }
            return
        }
        switch situacao {
        case .pasta:
            // Migração recusada deixa a pasta comum onde estava, e a instalação segue.
            try? migrar(raiz)
        case .nosso:
            try fm.createDirectory(at: real, withIntermediateDirectories: true)
        case .nada:
            if fm.fileExists(atPath: real.path) {
                try fm.removeItem(at: real)
            }
            try fm.createDirectory(at: real, withIntermediateDirectories: true)
            do {
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: nomeForaDaNuvem)
            } catch {
                try? fm.removeItem(at: real)
                try fm.createDirectory(at: link, withIntermediateDirectories: true)
            }
        case .alheio, .outro:
            // Link para outro lugar é escolha da pessoa; arquivo com esse nome faz a
            // instalação falhar como falhava antes. Nos dois casos, não mexer.
            try fm.createDirectory(at: link, withIntermediateDirectories: true)
        }
    }

    /// Troca a pasta `node_modules` de verdade pelo arranjo do iCloud: renomeia para
    /// `node_modules.nosync` e põe o link no lugar. Renomear é uma operação só, sem copiar
    /// nada; para o iCloud, é a pasta sumindo da nuvem, que é o que se quer.
    ///
    /// Se já existia uma `node_modules.nosync` ao lado, é sobra: quem responde pelo
    /// projeto é a pasta que está em `node_modules`, então a outra sai.
    static func migrar(_ raiz: URL) throws {
        let fm = FileManager.default
        let link = raiz.appending(path: nome)
        let real = raiz.appending(path: nomeForaDaNuvem)
        if fm.fileExists(atPath: real.path) || (try? fm.destinationOfSymbolicLink(atPath: real.path)) != nil {
            try fm.removeItem(at: real)
        }
        try fm.moveItem(at: link, to: real)
        do {
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: nomeForaDaNuvem)
        } catch {
            // Sem link não há como achar os pacotes: desfaz e deixa como estava.
            try? fm.moveItem(at: real, to: link)
            throw error
        }
    }

    /// A migração da abertura do projeto: projeto no iCloud com `node_modules` de verdade
    /// ganha o arranjo, uma vez. Nos outros casos não faz nada — nem cria pasta, nem
    /// recria link apagado; isso fica para o próximo `npm install`, que é quando se sabe
    /// que a pessoa quer pacotes ali.
    ///
    /// `nuvem` força a decisão: quem vai mover um projeto local para o iCloud migra antes
    /// de mover, senão o iCloud começa a subir o `node_modules` no próprio movimento.
    ///
    /// Devolve se migrou. Não lança: abrir o projeto não pode falhar por causa disto.
    @discardableResult
    public static func migrarSePreciso(_ raiz: URL, nuvem: Bool? = nil) -> Bool {
        guard situacao(raiz) == .pasta, nuvem ?? naNuvem(raiz) else { return false }
        do {
            try migrar(raiz)
        } catch {
            return false
        }
        garantirGitignore(raiz, nuvem: true)
        return true
    }

    /// Onde os pacotes estão de fato, com o link de `node_modules` resolvido.
    ///
    /// As APIs de URL do `FileManager` — `contentsOfDirectory(at:)`, `enumerator(at:)` —
    /// não entram num link que seja o último componente do caminho: devolvem erro de
    /// "não é pasta" ou nada. Quem lista `node_modules` precisa listar esta.
    public static func pastaReal(_ raiz: URL) -> URL {
        let link = raiz.appending(path: nome)
        guard let destino = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return link
        }
        return destino.hasPrefix("/") ? URL(fileURLWithPath: destino) : raiz.appending(path: destino)
    }

    // MARK: - .gitignore

    /// O que falta no `.gitignore` para o git não ver os pacotes.
    ///
    /// Fora do iCloud é a regra de sempre: qualquer menção a `node_modules` basta, e
    /// faltando entra `node_modules/`.
    ///
    /// No iCloud são duas coisas, e a barra no fim faz diferença: `node_modules/` só vale
    /// para pasta, e para o git o link `node_modules` não é pasta — ele apareceria como
    /// arquivo novo no painel. Então entra `node_modules` sem barra, que pega os dois, e
    /// `node_modules.nosync/`, que é onde os milhares de arquivos estão.
    public static func linhasQueFaltam(noGitignore texto: String?, nuvem: Bool) -> [String] {
        let texto = texto ?? ""
        guard nuvem else {
            let semNosync = texto.replacingOccurrences(of: nomeForaDaNuvem, with: "")
            return semNosync.contains(nome) ? [] : ["node_modules/"]
        }
        let regras = texto.split(whereSeparator: \.isNewline).map { linha -> String in
            var r = linha.trimmingCharacters(in: .whitespaces)
            if r.hasPrefix("/") {
                r.removeFirst()
            }
            if r.hasPrefix("**/") {
                r.removeFirst(3)
            }
            return r
        }
        var faltam: [String] = []
        if !regras.contains(where: { $0 == "node_modules" || $0 == "node_modules*" }) {
            faltam.append("node_modules")
        }
        let cobreReal: Set = [
            "node_modules.nosync", "node_modules.nosync/", "*.nosync", "*.nosync/", "node_modules*", "node_modules.*",
        ]
        if !regras.contains(where: { cobreReal.contains($0) }) {
            faltam.append("node_modules.nosync/")
        }
        return faltam
    }

    /// Acrescenta ao `.gitignore` o que falta e devolve o que acrescentou. Sem
    /// `.gitignore`, cria um com o de sempre (`dist/`, `.DS_Store`) junto.
    @discardableResult
    public static func garantirGitignore(_ raiz: URL, nuvem: Bool) -> [String] {
        let u = raiz.appending(path: ".gitignore")
        let atual = try? String(contentsOf: u, encoding: .utf8)
        let faltam = linhasQueFaltam(noGitignore: atual, nuvem: nuvem)
        guard !faltam.isEmpty else { return [] }
        let novo: String = if let atual {
            atual + (atual.hasSuffix("\n") || atual.isEmpty ? "" : "\n") + faltam.map { $0 + "\n" }.joined()
        } else {
            (faltam + ["dist/", ".DS_Store"]).map { $0 + "\n" }.joined()
        }
        do {
            try novo.write(to: u, atomically: true, encoding: .utf8)
        } catch {
            return []
        }
        return faltam
    }
}
