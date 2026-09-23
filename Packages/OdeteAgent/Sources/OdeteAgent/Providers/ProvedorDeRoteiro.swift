#if DEBUG
    import Foundation
    import Synchronization

    /// Provedor que toca um roteiro em vez de falar com um modelo. Só existe em DEBUG.
    ///
    /// Serve para o QA visual no simulador, que não tem Apple Intelligence nem conta de IA:
    /// com ele um turno inteiro roda pelo laço de verdade — as ferramentas saem como
    /// chamadas de ferramenta normais, então checkpoint, patch, licença e tela se comportam
    /// exatamente como com um modelo.
    ///
    /// Liga com `ODETE_AGENTE_ROTEIRO=<caminho absoluto do JSON>` no ambiente do processo
    /// (no simulador: `SIMCTL_CHILD_ODETE_AGENTE_ROTEIRO=… xcrun simctl launch …`). Ligado,
    /// ele atende o agente seja qual for o modelo escolhido, e nada vai para o disco: nem
    /// conta, nem modelo no estado do app.
    ///
    /// O roteiro é uma lista de turnos; cada turno, uma lista de passos. Cada mensagem
    /// enviada consome o próximo turno; acabados os turnos, a resposta é uma frase curta.
    /// O cursor é do processo: reabrir o app volta ao primeiro turno.
    ///
    /// ```json
    /// {
    ///   "turnos": [
    ///     [
    ///       {"ferramenta": "write_file", "argumentos": {"path": "qa/nota.md", "content": "# Nota\n"}},
    ///       {"ferramenta": "str_replace", "argumentos": {"path": "index.html", "old": "Olá", "new": "Oi"}},
    ///       {"texto": "pronto"}
    ///     ],
    ///     [
    ///       {"ferramenta": "run_shell", "argumentos": {"command": "touch qa/do-shell.txt"}},
    ///       {"texto": "criei pelo shell"}
    ///     ]
    ///   ]
    /// }
    /// ```
    ///
    /// A lista de turnos também pode vir sozinha, sem o objeto em volta. Cada passo tem
    /// `ferramenta` (o nome, como em `Tools.all`, com `argumentos` opcionais) ou `texto`
    /// (a resposta, que chega aos pedaços, como num modelo). Texto antes de uma ferramenta
    /// sai na mesma rodada dela; texto no fim fecha o turno.
    public final class ProvedorDeRoteiro: Provider, Sendable {
        /// A variável de ambiente que liga o roteiro.
        public static let variavel = "ODETE_AGENTE_ROTEIRO"
        /// Como o roteiro aparece no lugar do modelo.
        public static let rotulo = "Roteiro (QA)"
        public static let idDoModelo = "roteiro-qa"

        public let kind: ProviderKind = .openaiCompat
        public let caminho: String
        /// Entre um pedaço de texto e o seguinte, para a tela ver a resposta chegando.
        let pausa: Duration

        /// Quantos turnos de cada roteiro já foram tocados neste processo. Estático porque o
        /// app cria um provedor a cada mensagem enviada.
        private static let cursor = Mutex<[String: Int]>([:])
        /// As rodadas que faltam do turno deste envio. `nil` até a primeira: é nela que o
        /// turno é tirado do roteiro.
        private let rodadas = Mutex<[[StreamEvent]]?>(nil)

        public init(caminho: String, pausa: Duration = .milliseconds(18)) {
            self.caminho = caminho
            self.pausa = pausa
        }

        /// O caminho do roteiro, se o ambiente liga um. Sem `ambiente`, lê o do processo
        /// agora, com `getenv` — o `ProcessInfo` pode guardar uma cópia de quando o app abriu.
        public static func caminhoDoAmbiente(_ ambiente: [String: String]? = nil) -> String? {
            let bruto: String? = if let ambiente {
                ambiente[variavel]
            } else {
                getenv(variavel).map { String(cString: $0) }
            }
            guard let c = bruto?.trimmingCharacters(in: .whitespaces), !c.isEmpty else { return nil }
            return c
        }

        /// Um provedor novo — um por mensagem enviada —, se o ambiente liga um roteiro.
        public static func doAmbiente() -> ProvedorDeRoteiro? {
            caminhoDoAmbiente().map { ProvedorDeRoteiro(caminho: $0) }
        }

        /// Volta o cursor de um roteiro ao primeiro turno. Para os testes.
        static func recomecar(_ caminho: String) {
            cursor.withLock { $0[caminho] = nil }
        }

        public func models() async throws -> [ModelInfo] {
            [ModelInfo(id: Self.idDoModelo, label: Self.rotulo)]
        }

        public func stream(_: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error> {
            let eventos = proximaRodada()
            let pausa = pausa
            return AsyncThrowingStream { cont in
                let t = Task {
                    for e in eventos {
                        if Task.isCancelled {
                            break
                        }
                        if case .text = e, pausa > .zero {
                            try? await Task.sleep(for: pausa)
                        }
                        cont.yield(e)
                    }
                    cont.finish()
                }
                cont.onTermination = { _ in t.cancel() }
            }
        }

        /// A próxima rodada deste envio.
        ///
        /// Acabadas as rodadas do turno, a resposta é vazia: o laço pede mais uma quando o
        /// turno termina em texto sem ter editado nada (a cutucada do Build), e uma resposta
        /// vazia encerra sem desenhar mais um balão.
        func proximaRodada() -> [StreamEvent] {
            rodadas.withLock { r in
                if r == nil {
                    r = tirarTurno()
                }
                guard var restantes = r, !restantes.isEmpty else { return [.done] }
                let proxima = restantes.removeFirst()
                r = restantes
                return proxima
            }
        }

        private func tirarTurno() -> [[StreamEvent]] {
            let roteiro: Roteiro
            do {
                roteiro = try Roteiro.ler(Data(contentsOf: URL(fileURLWithPath: caminho)))
            } catch {
                return [[.error("\(Self.rotulo): \(error.localizedDescription)"), .done]]
            }
            let n = Self.cursor.withLock { c in
                let n = c[caminho, default: 0]
                c[caminho] = n + 1
                return n
            }
            guard n < roteiro.turnos.count else {
                return [[.text("\(Self.rotulo): os \(roteiro.turnos.count) turnos do roteiro acabaram."), .done]]
            }
            return Roteiro.rodadas(roteiro.turnos[n])
        }
    }

    /// O roteiro lido do JSON — ver `ProvedorDeRoteiro`.
    public struct Roteiro: Sendable, Equatable {
        public enum Passo: Sendable, Equatable {
            /// Nome da ferramenta e os argumentos, já em JSON.
            case ferramenta(String, argumentos: String)
            case texto(String)
        }

        public var turnos: [[Passo]]

        public struct Erro: LocalizedError, Equatable {
            public var motivo: String
            public var errorDescription: String? {
                motivo
            }
        }

        public static func ler(_ data: Data) throws -> Roteiro {
            let raiz: Any
            do { raiz = try JSONSerialization.jsonObject(with: data) } catch {
                throw Erro(motivo: "o arquivo não é JSON válido")
            }
            let lista: Any? = if let objeto = raiz as? [String: Any] {
                objeto["turnos"]
            } else {
                raiz
            }
            guard let turnos = lista as? [Any] else {
                throw Erro(motivo: "esperava uma lista de turnos, ou {\"turnos\": [...]}")
            }
            return try Roteiro(turnos: turnos.enumerated().map { i, turno in
                guard let passos = turno as? [Any] else {
                    throw Erro(motivo: "turno \(i + 1): esperava uma lista de passos")
                }
                return try passos.enumerated().map { j, bruto in
                    try passo(bruto, onde: "turno \(i + 1), passo \(j + 1)")
                }
            })
        }

        static func passo(_ bruto: Any, onde: String) throws -> Passo {
            guard let o = bruto as? [String: Any] else {
                throw Erro(motivo: "\(onde): esperava um objeto")
            }
            switch (o["ferramenta"], o["texto"]) {
            case let (nome as String, nil):
                guard !nome.isEmpty else { throw Erro(motivo: "\(onde): ferramenta sem nome") }
                let args = o["argumentos"] ?? [String: Any]()
                guard args is [String: Any],
                      let d = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
                else { throw Erro(motivo: "\(onde): argumentos precisa ser um objeto") }
                return .ferramenta(nome, argumentos: String(decoding: d, as: UTF8.self))
            case let (nil, texto as String):
                return .texto(texto)
            default:
                throw Erro(motivo: "\(onde): cada passo tem \"ferramenta\" ou \"texto\", um dos dois")
            }
        }

        /// As rodadas de um turno. Uma ferramenta por rodada, levando junto o texto que veio
        /// antes dela; o texto que sobra no fim é a rodada que fecha o turno.
        static func rodadas(_ passos: [Passo]) -> [[StreamEvent]] {
            var out: [[StreamEvent]] = []
            var texto = ""
            for passo in passos {
                switch passo {
                case let .texto(t):
                    texto += texto.isEmpty ? t : "\n\n" + t
                case let .ferramenta(nome, argumentos):
                    let chamada = ToolCall(id: "roteiro-\(UUID().uuidString)", name: nome, arguments: argumentos)
                    out.append(pedacos(texto).map(StreamEvent.text) + [.tools([chamada]), .done])
                    texto = ""
                }
            }
            if !texto.isEmpty {
                out.append(pedacos(texto).map(StreamEvent.text) + [.done])
            }
            return out
        }

        /// O texto em pedaços de umas poucas palavras, como chega de um modelo.
        static func pedacos(_ texto: String) -> [String] {
            var out: [String] = []
            var atual = ""
            for c in texto {
                atual.append(c)
                if c == " " || c == "\n", atual.count >= 12 {
                    out.append(atual)
                    atual = ""
                }
            }
            if !atual.isEmpty {
                out.append(atual)
            }
            return out
        }
    }
#endif
