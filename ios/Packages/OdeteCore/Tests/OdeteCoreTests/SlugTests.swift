@testable import OdeteCore
import Testing

/// O nome que vai para o GitHub sai arrumado antes de a pessoa apertar o botão.
struct SlugTests {
    @Test func tiraEspacoEAcento() {
        #expect(Slug.repo("Vitrine Cerâmica") == "vitrine-ceramica")
        #expect(Slug.repo("meu projeto  legal") == "meu-projeto-legal")
        #expect(Slug.repo("São Paulo/Loja") == "sao-paulo-loja")
    }

    @Test func nomeJaValidoPassaInteiro() {
        #expect(Slug.repo("odete-ide") == "odete-ide")
        #expect(Slug.repo("app_2.0") == "app_2.0")
    }

    @Test func naoSobraTracoNaPontaNemDobrado() {
        #expect(Slug.repo(" -- teste -- ") == "teste")
        #expect(Slug.repo("a///b") == "a-b")
    }
}
