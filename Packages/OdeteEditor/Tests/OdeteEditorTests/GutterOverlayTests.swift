@testable import OdeteEditor
import Testing
import UIKit

/// A camada das marcas do git mora dentro do editor e tem a altura do arquivo inteiro.
/// Se ela aceitar toque fora da própria tira, engole o toque que devia levar o cursor
/// para a linha — foi o que aconteceu, e em toda linha com marca.
@MainActor
struct GutterOverlayTests {
    func fazer() -> GutterOverlay {
        let o = GutterOverlay(frame: CGRect(x: 0, y: 0, width: 42, height: 5299))
        o.placed = [.init(y: 100, h: 20, mark: EditorGutterMark(line: 5, kind: .modified))]
        return o
    }

    @Test func aceitaEmCimaDaMarca() {
        #expect(fazer().point(inside: CGPoint(x: 36, y: 105), with: nil))
    }

    @Test func naoAceitaNoMeioDoCodigo() {
        #expect(!fazer().point(inside: CGPoint(x: 132, y: 105), with: nil))
        #expect(!fazer().point(inside: CGPoint(x: 600, y: 105), with: nil))
    }

    @Test func naoAceitaNosNumerosDaLinha() {
        #expect(!fazer().point(inside: CGPoint(x: 8, y: 105), with: nil))
    }

    @Test func naoAceitaEmLinhaSemMarca() {
        #expect(!fazer().point(inside: CGPoint(x: 36, y: 400), with: nil))
    }
}
