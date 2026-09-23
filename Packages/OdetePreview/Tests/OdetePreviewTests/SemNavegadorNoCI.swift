import Foundation
import Testing

extension Trait where Self == ConditionTrait {
    /// Página carregada num WKWebView de verdade: no simulador do GitHub o WebKit leva
    /// minutos para subir e o teste desiste por tempo. O CI liga `ODETE_SEM_NAVEGADOR`;
    /// na máquina, roda.
    static var semNavegadorNoCI: Self {
        .disabled(
            if: ProcessInfo.processInfo.environment["ODETE_SEM_NAVEGADOR"] != nil,
            "WKWebView lento demais no simulador do CI"
        )
    }
}
