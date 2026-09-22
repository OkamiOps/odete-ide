import OdeteCore
@testable import OdeteEditor
import Runestone
import SwiftUI
import Testing
import UIKit

/// As decorações (guias de recuo, marcas do git, ondas de erro) são montadas só para a
/// faixa visível e uma tela de folga. Antes as guias pediam a posição de cada linha recuada
/// do arquivo inteiro — até 4000 — e as camadas tinham a altura do arquivo.
@MainActor
struct DecoracaoVisivelTests {
    func montar(linhas: Int) -> (OdeteTextView, CodeEditorView.Coordinator) {
        let texto = (1 ... linhas).map { "    linha \($0)" }.joined(separator: "\n")
        let tv = OdeteTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let editor = CodeEditorView(
            text: .constant(texto),
            documentId: "teste",
            language: .javascript,
            palette: ThemePalette.by(.odete),
            prefs: EditorPrefs()
        )
        let c = CodeEditorView.Coordinator(parent: editor)
        c.textView = tv
        tv.addSubview(c.guides)
        tv.addSubview(c.changeMarks)
        tv.addSubview(c.overlay)
        tv.setState(TextViewState(text: texto, theme: EditorTheme(palette: ThemePalette.by(.odete), fontSize: 13)))
        c.anotarTexto(texto)
        tv.layoutIfNeeded()
        return (tv, c)
    }

    @Test func guiasSoNaFaixaVisivel() {
        let (tv, c) = montar(linhas: 2000)
        #expect(tv.contentSize.height > 10 * tv.bounds.height, "o arquivo é bem maior que a tela")
        c.layoutDecorations()
        // A camada cobre a tela e a folga, não o arquivo.
        #expect(c.guides.frame.height < 3.5 * tv.bounds.height)
        #expect(!c.guides.segments.isEmpty)
        // Duas guias por linha (quatro espaços, recuo de dois): o arquivo inteiro daria 4000.
        #expect(c.guides.segments.count < 400)
        #expect(c.guides.segments.allSatisfy { $0.y >= 0 && $0.y <= c.guides.frame.height })
    }

    @Test func marcaForaDaFaixaNaoEntra() {
        // O coordenador guarda o editor por referência fraca: ele tem de viver até o fim.
        let (tv, c) = montar(linhas: 2000)
        withExtendedLifetime(tv) {
            c.marks = [EditorGutterMark(line: 2, kind: .added), EditorGutterMark(line: 1800, kind: .modified)]
            c.layoutDecorations()
            #expect(c.overlay.placed.map(\.mark.line) == [2])
        }
    }

    /// Rolou para longe: a faixa acompanha e as coordenadas continuam relativas a ela.
    @Test func faixaAcompanhaARolagem() {
        let (tv, c) = montar(linhas: 2000)
        withExtendedLifetime(tv) {
            c.marks = [EditorGutterMark(line: 1500, kind: .modified)]
            let alvo = tv.contentSize.height * 0.75
            tv.contentOffset = CGPoint(x: 0, y: alvo)
            c.layoutDecorations()
            let faixa = c.faixaDecorada
            #expect(faixa?.contains(alvo) == true)
            #expect(c.guides.frame.minY == faixa?.lowerBound)
            #expect(c.overlay.frame.minY == faixa?.lowerBound)
            #expect(!c.guides.segments.isEmpty, "as guias de lá foram montadas")
        }
    }

    /// A linha do cursor sai da árvore de linhas do Runestone, e bate com o mapa de linhas.
    @Test func linhaDoCursorPeloRunestone() {
        let (tv, c) = montar(linhas: 50)
        withExtendedLifetime(tv) {
            let mapa = c.linhas()
            for off in [0, 5, mapa.starts[10], mapa.starts[10] - 1, mapa.starts[49]] {
                #expect(tv.textLocation(at: off)?.lineNumber == mapa.linha(de: off))
                #expect(c.linhaDe(off) == mapa.linha(de: off))
            }
        }
    }
}
