import Foundation

// `Date.formatted()` e `ByteCountFormatter` seguem o idioma do aparelho, não o dos
// Ajustes da Odete. Quem escolheu alemão num iPad em inglês via a tela em alemão e a
// data em inglês, na mesma linha.

public extension Date {
    /// Data no idioma escolhido nos Ajustes.
    func noIdioma(_ estilo: Date.FormatStyle) -> String {
        formatted(estilo.locale(Texto.idioma.locale))
    }

    /// "há 8 min", no idioma escolhido nos Ajustes.
    func noIdioma(_ estilo: Date.RelativeFormatStyle) -> String {
        var e = estilo
        e.locale = Texto.idioma.locale
        return formatted(e)
    }

    /// Data e hora com os estilos prontos do sistema, no idioma dos Ajustes.
    func noIdioma(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        noIdioma(Date.FormatStyle(date: date, time: time))
    }
}

public enum Tamanho {
    /// "1,2 MB" — com a vírgula ou o ponto do idioma certo. `ByteCountFormatter` não
    /// aceita `Locale`; `Measurement` aceita.
    public static func arquivo(_ bytes: Int) -> String {
        Measurement(value: Double(max(0, bytes)), unit: UnitInformationStorage.bytes)
            .formatted(.byteCount(style: .file).locale(Texto.idioma.locale))
    }
}
