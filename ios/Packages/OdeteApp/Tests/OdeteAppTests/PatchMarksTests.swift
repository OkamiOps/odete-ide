@testable import OdeteApp
import OdeteEditor
import Testing

/// O patch do agente desenhado dentro do código: linha que entrou em verde e o ponto
/// onde linhas saíram. A comparação é sempre com o texto de antes do agente.
struct PatchMarksTests {
    @Test func linhaQueEntrouFicaMarcadaNaPosicaoNova() {
        let m = PatchMarks.linhas(antes: "a\nb\n", agora: "a\nNOVA\nb\n")
        #expect(m == [EditorLineChange(line: 2, kind: .added)])
    }

    @Test func linhaQueSaiuViraUmaMarcaSo() {
        let m = PatchMarks.linhas(antes: "a\nb\nc\nd\n", agora: "a\nd\n")
        #expect(m.count == 1)
        #expect(m.first?.kind == .removed)
        #expect(m.first?.line == 2)
    }

    /// Editar por cima da alteração não pode apagar o verde: é o caso de quando o agente
    /// quase acertou e a pessoa ajusta a linha.
    @Test func edicaoPorCimaMantemALinhaMarcada() {
        let m = PatchMarks.linhas(antes: "a\nb\n", agora: "a\nNOVA editada por mim\nb\n")
        #expect(m == [EditorLineChange(line: 2, kind: .added)])
    }

    @Test func semMudancaNaoMarcaNada() {
        #expect(PatchMarks.linhas(antes: "a\nb\n", agora: "a\nb\n").isEmpty)
    }

    @Test func blocoInteiroNovoMarcaTodasAsLinhas() {
        let m = PatchMarks.linhas(antes: "a\n", agora: "a\nx\ny\nz\n")
        #expect(m == [
            EditorLineChange(line: 2, kind: .added),
            EditorLineChange(line: 3, kind: .added),
            EditorLineChange(line: 4, kind: .added),
        ])
    }
}
