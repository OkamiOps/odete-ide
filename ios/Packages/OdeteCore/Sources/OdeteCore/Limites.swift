import Foundation

/// Onde a Odete para de tratar um arquivo como coisa que alguém escreveu à mão.
public enum Limites {
    /// Acima disto é bundle, minificado ou gerado. Analisar esses arquivos custa caro e
    /// não informa nada: um `react-dom.development.js` de 1,2 MB rendia 1395 avisos
    /// sobre código de terceiro, que enterravam os problemas do próprio projeto, e
    /// pagava cento e cinquenta mil casamentos de regex a cada pausa na digitação.
    public static let arquivoGrande = 400_000
}
