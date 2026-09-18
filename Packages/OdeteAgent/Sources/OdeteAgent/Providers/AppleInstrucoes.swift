import Foundation
import OdeteI18n

/// As instruções que o modelo do sistema recebe.
///
/// Elas são **as mesmas** que os provedores por assinatura recebem. Aqui já houve um
/// resumo escrito à mão, com medo da janela, e a conta não fechava: o modo escolhido na
/// tela não chegava, as regras da pilha e do projeto não chegavam, e o modelo local
/// virava um primo pobre — pedia licença para editar no modo cujo nome é "pode editar",
/// e chegou a perguntar para a pessoa qual ferramenta deveria usar. A economia nem
/// existia de verdade: num projeto de quatro arquivos o prompt inteiro ocupa uma fração
/// da janela que o aparelho informa em tempo de execução.
///
/// Então vai o prompt de verdade, e o corte só acontece quando ele realmente não cabe —
/// encolhendo a lista de arquivos, que é a única parte que cresce sem limite.
enum AppleInstrucoes {
    /// Regras que os modelos grandes não precisam e este precisa.
    ///
    /// Não são limites: são o contrário. Todas existem porque o modelo pequeno parou no
    /// meio do caminho pedindo permissão que ninguém pediu para ele pedir.
    static let comFerramentas = """
    Ferramentas:
    - Aja. Nunca pergunte "posso seguir?", "confirma?" nem "qual ferramenta devo usar?" —
      a escolha da ferramenta é sua, e quem aprova a mudança é o app, que mostra cada
      patch para a pessoa aceitar antes de valer.
    - Não anuncie o que vai fazer. Nada de "Plano:", "Próximos passos:" ou "Agora vou
      abrir o arquivo": enquanto houver trabalho, a mensagem termina numa chamada de
      ferramenta, não num aviso. Texto só no fim, contando o que mudou.
    - Uma ferramenta por vez. O resultado chega na mensagem seguinte e você segue sozinho,
      até terminar o que foi pedido. Só pare para perguntar se não der para saber em qual
      arquivo mexer.
    - Em str_replace, `old` tem que ser copiado caractere por caractere do que o read_file
      devolveu, com a indentação igual. Nunca escreva o trecho de memória. Não achou?
      Leia o arquivo de novo em vez de tentar outro palpite.
    - O que entra num arquivo é texto puro na linguagem dele: CSS num .css, HTML num
      .html. Nunca escreva JSON dentro de um arquivo que não seja .json — nem quando a
      chamada da ferramenta é JSON.
    - Não sabe o caminho? list_dir ou grep, sem perguntar.
    - Nunca responda que não consegue editar.
    """

    static let semFerramentas = """
    Nesta rodada você está sem ferramentas: responda com o que dá para responder e diga,
    em uma frase, o que precisaria abrir para ir além.
    """

    static func texto(sistema: String, comFerramentas temFerramentas: Bool, teto: Int) -> String {
        let regras = temFerramentas ? comFerramentas : semFerramentas
        let idioma = tr("Responda em %1$@.", Texto.idioma.paraOModelo)
        let fixo = "\n\n" + regras + "\n\n" + idioma
        let base = temFerramentas ? semOFormato(sistema) : sistema
        return cabendo(base, teto: max(0, teto - fixo.count)) + fixo
    }

    /// Tira do prompt o bloco que manda responder em `##` e listas.
    ///
    /// Medido numa bancada com o modelo do sistema rodando de verdade: mesmo laço, mesma
    /// conversa, única diferença este bloco. Com ele, o modelo lê o arquivo e escreve
    /// `## Mudança de cor do botão` com bullets, e nunca edita. Sem ele, lê e chama
    /// `str_replace`. Não é prompt mal escrito — é que "formato de resposta obrigatório"
    /// e "chame a ferramenta" disputam a mesma saída, e num modelo de poucos bilhões de
    /// parâmetros o formato obrigatório ganha.
    ///
    /// O bloco continua valendo para os provedores por assinatura, que fazem as duas
    /// coisas sem se atrapalhar. Sai só daqui, e só quando há ferramenta em jogo.
    static func semOFormato(_ sistema: String) -> String {
        guard let inicio = sistema.range(of: marcaDoFormato) else { return sistema }
        let resto = sistema[inicio.upperBound...]
        guard let fim = resto.range(of: "\n\n") else { return String(sistema[..<inicio.lowerBound]) }
        return String(sistema[..<inicio.lowerBound]) + String(resto[fim.upperBound...])
    }

    static let marcaDoFormato = "Formato (obrigatório"

    /// O prompt inteiro quando cabe; com a lista de arquivos encolhida quando não cabe.
    ///
    /// A lista é a primeira a encolher porque é a única parte que depende do tamanho do
    /// projeto — o resto é texto fixo, e cortar texto fixo é cortar regra. Se mesmo sem
    /// lista nenhuma não couber, aí o corte é no fim, que é onde ficam os acréscimos
    /// (pilha, skills, regras do projeto) e não o essencial.
    static func cabendo(_ sistema: String, teto: Int) -> String {
        if sistema.count <= teto {
            return sistema
        }
        guard let faixa = sistema.range(of: marcaDaLista) else {
            return String(sistema.prefix(teto))
        }
        let antes = String(sistema[..<faixa.upperBound])
        let resto = sistema[faixa.upperBound...]
        let linhas = resto.split(separator: "\n", omittingEmptySubsequences: false)
        let lista = linhas.prefix { !$0.isEmpty }
        let depois = String(resto.dropFirst(lista.reduce(0) { $0 + $1.count + 1 }))

        var cabem: [Substring] = []
        var usado = antes.count + depois.count
        for caminho in lista where usado + caminho.count + 1 <= teto {
            cabem.append(caminho)
            usado += caminho.count + 1
        }
        let cortada = antes + cabem.joined(separator: "\n") + depois
        return cortada.count <= teto ? cortada : String(cortada.prefix(teto))
    }

    static let marcaDaLista = "Arquivos no projeto:\n"
}
