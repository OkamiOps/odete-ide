import Foundation
import Observation

/// Lista de contas (JSON em Application Support) + tokens no Keychain.
@MainActor
@Observable
public final class AccountStore {
    public private(set) var accounts: [HostAccount] = []
    public var authorName: String {
        didSet { save() }
    }

    public var authorEmail: String {
        didSet { save() }
    }

    private let url: URL
    private let keychain: any SecretStore

    private struct File: Codable { var accounts: [HostAccount]; var authorName: String; var authorEmail: String }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Odete/accounts.json")
    }

    public init(url: URL = AccountStore.defaultURL(), keychain: any SecretStore = Keychain()) {
        self.url = url
        self.keychain = keychain
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let f = try? dec.decode(File.self, from: data) {
            accounts = f.accounts
            authorName = f.authorName
            authorEmail = f.authorEmail
        } else {
            authorName = ""
            authorEmail = ""
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(File(accounts: accounts, authorName: authorName, authorEmail: authorEmail)).write(
            to: url,
            options: .atomic
        )
    }

    public func add(_ account: HostAccount, token: String) throws {
        try keychain.set(token, for: account.keychainKey)
        accounts.removeAll { $0.host == account.host && $0.login == account.login }
        accounts.append(account)
        if authorName.isEmpty, let n = account.name ?? Optional(account.login) {
            authorName = n
        }
        if authorEmail.isEmpty, let e = account.email {
            authorEmail = e
        }
        save()
    }

    public func remove(_ account: HostAccount) {
        keychain.delete(account.keychainKey)
        accounts.removeAll { $0.id == account.id }
        save()
    }

    public func token(for account: HostAccount) -> String? {
        keychain.get(account.keychainKey)
    }

    /// Conta que atende um host de remoto.
    public func account(forHost host: String) -> HostAccount? {
        accounts.first { $0.host.lowercased() == host.lowercased() }
    }

    public func account(forRemote url: String) -> HostAccount? {
        HostAccount.host(ofRemote: url).flatMap(account(forHost:))
    }

    public var github: HostAccount? {
        accounts.first { $0.kind == .github && $0.host == "github.com" }
    }

    /// Troca os dados de uma conta já salva (o id que faltava, um nome novo) sem mexer
    /// no token.
    public func update(_ account: HostAccount) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i] = account
        save()
    }

    /// Como o commit vai assinado: o que estiver escrito nos ajustes, ou o que dá para
    /// deduzir da conta conectada. A tela de contas mostra exatamente isto, para não
    /// prometer um nome e gravar outro.
    public var autor: (name: String, email: String) {
        let n = authorName.isEmpty ? (github?.name ?? github?.login ?? "Odete") : authorName
        // O e-mail da conta vale mais que um endereço inventado. Conta do GitHub sem
        // e-mail público assina com o noreply dela: `@odete.local` fazia o commit
        // aparecer no GitHub sem dono, fora do gráfico de contribuições da pessoa.
        // Só sem conta nenhuma é que sobra o `@odete.local`.
        let e = authorEmail.isEmpty
            ? (github.map { $0.email ?? $0.githubNoreplyEmail }
                ?? "\(n.lowercased().replacingOccurrences(of: " ", with: ""))@odete.local")
            : authorEmail
        return (n, e)
    }
}
