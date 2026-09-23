#if DEBUG
    import Foundation
    @testable import OdeteAgent
    import OdeteI18n
    import Testing

    /// O provedor de roteiro do QA: lê o JSON, e cada mensagem enviada toca o próximo turno
    /// pelo laço de verdade.
    @Suite(.serialized) struct RoteiroTests {
        init() {
            Texto.escolher(.ptBR)
        }

        func arquivo(_ json: String) throws -> String {
            let u = FileManager.default.temporaryDirectory.appending(path: "roteiro-\(UUID().uuidString).json")
            try json.write(to: u, atomically: true, encoding: .utf8)
            return u.path
        }

        func ler(_ json: String) throws -> Roteiro {
            try Roteiro.ler(Data(json.utf8))
        }

        @Test func leComESemOObjetoEmVolta() throws {
            let r = try ler("""
            {"turnos": [
              [{"texto": "oi"}],
              [{"ferramenta": "read_file", "argumentos": {"path": "a.txt"}}, {"ferramenta": "list_dir"}]
            ]}
            """)
            #expect(r.turnos == [
                [.texto("oi")],
                [.ferramenta("read_file", argumentos: #"{"path":"a.txt"}"#), .ferramenta("list_dir", argumentos: "{}")],
            ])
            #expect(try ler(#"[[{"texto": "só a lista"}]]"#).turnos == [[.texto("só a lista")]])
        }

        /// O erro diz onde está o problema: quem escreve o roteiro é gente.
        @Test func errosDizemOnde() {
            func motivo(_ json: String) -> String? {
                do { _ = try ler(json); return nil } catch {
                    return (error as? Roteiro.Erro)?.motivo
                }
            }
            #expect(motivo("{") == "o arquivo não é JSON válido")
            #expect(motivo(#"{"turno": []}"#) == "esperava uma lista de turnos, ou {\"turnos\": [...]}")
            #expect(motivo(#"[{"texto": "a"}]"#) == "turno 1: esperava uma lista de passos")
            #expect(motivo(#"[[], ["x"]]"#) == "turno 2, passo 1: esperava um objeto")
            #expect(motivo(#"[[{"texto": "a"}, {"texto": "b", "ferramenta": "x"}]]"#)
                == "turno 1, passo 2: cada passo tem \"ferramenta\" ou \"texto\", um dos dois")
            #expect(motivo(#"[[{"ferramenta": "write_file", "argumentos": [1]}]]"#)
                == "turno 1, passo 1: argumentos precisa ser um objeto")
            #expect(motivo(#"[[{"ferramenta": ""}]]"#) == "turno 1, passo 1: ferramenta sem nome")
        }

        /// Texto antes de uma ferramenta sai na mesma rodada dela; o do fim fecha o turno.
        @Test func rodadas() {
            let r = Roteiro.rodadas([
                .texto("vou ler o arquivo agora"),
                .ferramenta("read_file", argumentos: #"{"path":"a.txt"}"#),
                .ferramenta("list_dir", argumentos: "{}"),
                .texto("li tudo"),
            ])
            #expect(r.count == 3)
            func texto(_ rodada: [StreamEvent]) -> String {
                rodada.reduce("") {
                    if case let .text(t) = $1 {
                        return $0 + t
                    }
                    return $0
                }
            }
            func ferramentas(_ rodada: [StreamEvent]) -> [String] {
                rodada.flatMap {
                    if case let .tools(c) = $0 {
                        return c.map(\.name)
                    }
                    return []
                }
            }
            #expect(texto(r[0]) == "vou ler o arquivo agora" && ferramentas(r[0]) == ["read_file"])
            #expect(
                r[0].filter {
                    if case .text = $0 {
                        true
                    } else {
                        false
                    }
                }.count > 1,
                "o texto não veio aos pedaços"
            )
            #expect(texto(r[1]).isEmpty && ferramentas(r[1]) == ["list_dir"])
            #expect(texto(r[2]) == "li tudo" && ferramentas(r[2]).isEmpty && r[2].last == .done)
        }

        /// O roteiro do QA, de ponta a ponta, pelo laço de verdade: as escritas viram patch,
        /// o shell roda, os checkpoints anotam — e o desfazer volta o que o roteiro fez.
        @Test func cadaMensagemTocaUmTurnoPeloLaco() async throws {
            let root = try tmpProject()
            let caminho = try arquivo(#"""
            {"turnos": [
              [
                {"ferramenta": "write_file", "argumentos": {"path": "qa/nota.md", "content": "# Nota do QA\n"}},
                {"ferramenta": "str_replace", "argumentos": {"path": "a.txt", "old": "b", "new": "B"}},
                {"texto": "pronto"}
              ],
              [
                {"ferramenta": "run_shell", "argumentos": {"command": "touch qa/do-shell.txt"}},
                {"texto": "criei pelo shell"}
              ]
            ]}
            """#)
            defer { ProvedorDeRoteiro.recomecar(caminho) }
            let host = ShellDeVerdade(root: root)
            let patches = PatchStore(root: root)
            let cs = CheckpointStore(root: root, host: host)
            func enviar(_ texto: String) async -> [ChatItem] {
                // Um provedor por mensagem, como o app faz.
                let loop = AgentLoop(
                    provider: ProvedorDeRoteiro(caminho: caminho, pausa: .zero),
                    host: host,
                    patches: patches,
                    checkpoints: cs
                )
                return await runAll(loop, texto, LoopConfig(mode: .build, permit: .full, model: "qualquer")).items
            }
            func resposta(_ items: [ChatItem]) -> String? {
                items.reversed().lazy.compactMap {
                    if case let .assistant(_, t) = $0 {
                        return t
                    }
                    return nil
                }.first
            }

            let primeiro = await enviar("faz o primeiro")
            #expect(host.read("qa/nota.md") == "# Nota do QA\n")
            #expect(host.read("a.txt") == "a\nB\nc\n")
            #expect(patches.pending.map(\.path).sorted() == ["a.txt", "qa/nota.md"])
            #expect(resposta(primeiro) == "pronto")
            #expect(primeiro.filter {
                if case .patch = $0 {
                    true
                } else {
                    false
                }
            }.count == 2)

            let segundo = await enviar("faz o segundo")
            #expect(host.exists("qa/do-shell.txt"))
            #expect(resposta(segundo) == "criei pelo shell")
            #expect(!segundo.contains {
                if case .error = $0 {
                    true
                } else {
                    false
                }
            })

            let terceiro = await enviar("e agora?")
            #expect(resposta(terceiro) == "Roteiro (QA): os 2 turnos do roteiro acabaram.")

            /// O terceiro turno não mexeu em nada; o segundo criou pelo shell.
            func desfazerUltimo() throws -> VoltaDoTurno {
                let id = try #require(cs.last).id
                return try #require(cs.desfazer(id))
            }
            let nada = try desfazerUltimo()
            #expect(nada.apagados.isEmpty && nada.voltaram.isEmpty && nada.mantidos.isEmpty)
            let volta = try desfazerUltimo()
            #expect(volta.apagados == ["qa/do-shell.txt"] && !host.exists("qa/do-shell.txt"))
            let primeiraVolta = try desfazerUltimo()
            #expect(primeiraVolta.apagados == ["qa/nota.md"] && primeiraVolta.voltaram == ["a.txt"])
            #expect(host.read("a.txt") == "a\nb\nc\n" && !host.exists("qa"))
        }

        /// Roteiro que não abre vira erro na conversa, e não trava o laço.
        @Test func roteiroQuebradoViraErro() async throws {
            let root = try tmpProject()
            let caminho = try arquivo("[[{\"texto\": 1}]]")
            let loop = AgentLoop(
                provider: ProvedorDeRoteiro(caminho: caminho, pausa: .zero),
                host: TestHost(root: root),
                patches: PatchStore(root: root)
            )
            let r = await runAll(loop, "oi", LoopConfig(mode: .chat, permit: .full, model: "m"))
            #expect(r.items.contains {
                if case let .error(_, t) = $0 {
                    t.hasPrefix("Roteiro (QA): turno 1, passo 1")
                } else {
                    false
                }
            })
        }

        @Test func ligaSoPeloAmbiente() {
            #expect(ProvedorDeRoteiro.caminhoDoAmbiente([:]) == nil)
            #expect(ProvedorDeRoteiro.caminhoDoAmbiente(["ODETE_AGENTE_ROTEIRO": "  "]) == nil)
            #expect(ProvedorDeRoteiro.caminhoDoAmbiente(["ODETE_AGENTE_ROTEIRO": "/tmp/r.json"]) == "/tmp/r.json")
        }
    }
#endif
