import OdeteCore
@testable import OdeteEditor
import Testing

/// TypeScript, TSX e JavaScript — as linguagens com mais nome vindo de lugar nenhum.
///
/// A metade que importa aqui é a segunda, e por uma margem grande. `document`, `process`,
/// `fetch`, `describe`, `<div>`, `{ foo }` abreviado, `export ... from` — cada um destes é
/// um jeito de a ferramenta gritar em arquivo que está certo. Os testes de "não acusa" são
/// arquivos inteiros, de verdade, e não trechos escolhidos para passar.
struct ResolveWebTests {
    func erros(_ texto: String, _ lang: Language) -> [LintIssue] {
        Resolvedor.problemas(text: texto, language: lang).filter { $0.severity == .error }
    }

    func conta(_ achados: [LintIssue]) -> String {
        achados.map { "l\($0.line):\($0.column) \($0.message)" }.joined(separator: " | ")
    }

    // MARK: - acha

    @Test func tsAcusaNomeQueNaoExiste() {
        let achados = erros("""
        const total = 10
        console.log(totaal)
        """, .typescript)
        #expect(achados.count == 1, "esperava um só: \(conta(achados))")
        #expect(achados.first?.message.contains("totaal") == true)
        #expect(achados.first?.line == 2)
    }

    @Test func tsAcusaFuncaoEClasseQueNaoExistem() {
        #expect(erros("export function f(x: number) { return soma(x, 1) }", .typescript)
            .contains { $0.message.contains("soma") })
        #expect(erros("const l = new Loja()", .typescript).contains { $0.message.contains("Loja") })
    }

    @Test func tsAcusaTipoQueNaoFoiImportado() {
        let achados = erros("""
        export function nome(p: Pessoa): string {
          return p.nome
        }
        """, .typescript)
        #expect(achados.contains { $0.message.contains("Pessoa") }, "\(conta(achados))")
    }

    @Test func jsAcusaNomeQueNaoExiste() {
        let achados = erros("""
        function main() {
          const nomes = ['ana']
          return nomes.map((n) => formata(n))
        }
        """, .javascript)
        #expect(achados.count == 1, "esperava um só: \(conta(achados))")
        #expect(achados.first?.message.contains("formata") == true)
    }

    @Test func tsxAcusaComponenteQueNaoExiste() {
        let achados = erros("""
        export default function Pagina() {
          return <div>{titulo}</div>
        }
        """, .tsx)
        #expect(achados.contains { $0.message.contains("titulo") }, "\(conta(achados))")
        #expect(!achados.contains { $0.message.contains("div") }, "acusou uma tag de HTML")
    }

    // MARK: - não acusa

    /// Um componente React de verdade: hooks, props tipadas, JSX com tag nativa e
    /// componente importado, `map`, evento, e um tipo do próprio arquivo.
    @Test func tsxNaoAcusaComponenteCerto() {
        let achados = erros("""
        'use client'

        import { useState, useCallback } from 'react'
        import Link from 'next/link'
        import { Botao } from '@/components/botao'

        type Item = { id: string; titulo: string }

        interface Props {
          itens: Item[]
          aoEscolher?: (item: Item) => void
        }

        export default function Lista({ itens, aoEscolher }: Props) {
          const [busca, setBusca] = useState('')
          const filtrados = itens.filter((i) => i.titulo.includes(busca))

          const escolher = useCallback(
            (item: Item) => {
              aoEscolher?.(item)
            },
            [aoEscolher],
          )

          return (
            <div className="lista">
              <input value={busca} onChange={(e) => setBusca(e.target.value)} />
              {filtrados.map((item) => (
                <Link key={item.id} href={`/item/${item.id}`}>
                  <Botao onClick={() => escolher(item)}>{item.titulo}</Botao>
                </Link>
              ))}
            </div>
          )
        }
        """, .tsx)
        #expect(achados.isEmpty, "acusou código certo: \(conta(achados))")
    }

    /// TypeScript com o que a linguagem tem de mais próprio: genérico, enum, classe com
    /// campo privado, desestruturação, `async`, `try/catch`, tipo utilitário.
    @Test func tsNaoAcusaCodigoCerto() {
        let achados = erros("""
        import type { Readable } from 'node:stream'
        import { createHash } from 'node:crypto'

        export enum Estado {
          Parado,
          Rodando,
        }

        export type Resumo = Pick<Tarefa, 'id' | 'estado'>

        export interface Tarefa {
          id: string
          estado: Estado
          entrada?: Readable
        }

        export class Fila<T extends Tarefa> {
          private readonly itens: T[] = []

          constructor(private readonly limite: number) {}

          add(item: T): boolean {
            if (this.itens.length >= this.limite) return false
            this.itens.push(item)
            return true
          }

          async processa(fn: (t: T) => Promise<void>): Promise<Resumo[]> {
            const out: Resumo[] = []
            for (const item of this.itens) {
              try {
                await fn(item)
                out.push({ id: item.id, estado: Estado.Rodando })
              } catch (erro) {
                console.error(erro)
              }
            }
            return out
          }
        }

        export function digest(texto: string): string {
          return createHash('sha256').update(texto).digest('hex')
        }
        """, .typescript)
        #expect(achados.isEmpty, "acusou código certo: \(conta(achados))")
    }

    /// Node puro, do jeito que aparece num script de build.
    @Test func jsNaoAcusaScriptDeNode() {
        let achados = erros("""
        const fs = require('fs')
        const path = require('path')

        const raiz = path.join(__dirname, '..')

        function lista(dir) {
          return fs.readdirSync(dir).filter((n) => !n.startsWith('.'))
        }

        async function main() {
          const arquivos = lista(raiz)
          for (const [i, nome] of arquivos.entries()) {
            const { size } = fs.statSync(path.join(raiz, nome))
            console.log(`${i} ${nome} ${size}`)
          }
          const r = await fetch('https://exemplo.com')
          process.stdout.write(String(r.status))
        }

        main().catch((e) => {
          process.exitCode = 1
          console.error(e)
        })

        module.exports = { lista }
        """, .javascript)
        #expect(achados.isEmpty, "acusou código certo: \(conta(achados))")
    }

    /// O navegador e os arcabouços de teste trazem nomes que ninguém declara.
    @Test func naoAcusaGlobaisDoNavegadorNemDeTeste() {
        #expect(erros("""
        document.querySelector('#a')?.addEventListener('click', () => {
          window.localStorage.setItem('x', JSON.stringify({ t: Date.now() }))
          setTimeout(() => location.reload(), 1000)
        })
        """, .javascript).isEmpty)

        let testes = erros("""
        import { soma } from './soma'

        describe('soma', () => {
          it('soma dois', () => {
            expect(soma(1, 2)).toBe(3)
          })
        })
        """, .javascript)
        #expect(testes.isEmpty, "acusou um arquivo de teste: \(conta(testes))")
    }

    /// `{ foo }` abreviado e `export ... from` são os dois jeitos mais silenciosos de a
    /// ferramenta errar: um faria um import usado parecer sem uso, o outro acusaria um
    /// nome que nem passa por este arquivo.
    @Test func abreviadoEReexportacaoNaoConfundem() {
        let todos = Resolvedor.problemas(text: """
        import { alpha } from './alpha'
        export { beta } from './beta'

        export const tudo = { alpha }
        """, language: .typescript)
        #expect(todos.isEmpty, "\(conta(todos))")
    }

    @Test func importSemUsoEhAvisoENaoErro() {
        let todos = Resolvedor.problemas(
            text: "import { alpha } from './alpha'\n\nexport const x = 1\n",
            language: .typescript
        )
        #expect(todos.count == 1, "\(conta(todos))")
        #expect(todos.first?.severity == .warning)
        #expect(todos.first?.message.contains("alpha") == true)
    }

    /// Arquivos de um projeto de verdade, copiados como estão: `type` importado junto com
    /// valor, tipo indexado, `as const`, `!` de não-nulo, JSX aninhado. Nada disto foi
    /// escrito para passar no teste — foi escrito antes dele.
    @Test func projetoDeVerdadeNaoEhAcusado() {
        let catalogo = Resolvedor.problemas(text: """
        import { useMemo, useState } from "react";
        import { PECAS, type Peca } from "./dados";

        export function Catalogo() {
          const [busca, setBusca] = useState("");
          const [so, setSo] = useState<Peca["tipo"] | "tudo">("tudo");

          const lista = useMemo(
            () =>
              PECAS.filter((p) => so === "tudo" || p.tipo === so).filter((p) =>
                p.nome.toLowerCase().includes(busca.toLowerCase()),
              ),
            [busca, so],
          );

          return (
            <main id="catalogo" className="catalogo">
              <h1>Peças que duram</h1>
              <div className="filtros">
                <input
                  placeholder="Buscar peça"
                  value={busca}
                  onChange={(e) => setBusca(e.target.value)}
                />
                {(["tudo", "ceramica", "vidro"] as const).map((t) => (
                  <button key={t} className={so === t ? "on" : ""} onClick={() => setSo(t)}>
                    {t}
                  </button>
                ))}
              </div>
              <ul className="grade">
                {lista.map((p) => (
                  <li key={p.id} className="peca">
                    <span className="tipo">{p.tipo}</span>
                    <strong>R$ {p.preco.toFixed(2)}</strong>
                  </li>
                ))}
              </ul>
              {lista.length === 0 && <p className="vazio">Nada com esse nome.</p>}
            </main>
          );
        }
        """, language: .tsx)
        #expect(catalogo.isEmpty, "acusou código certo: \(conta(catalogo))")

        let main = Resolvedor.problemas(text: """
        import { StrictMode } from "react";
        import { createRoot } from "react-dom/client";
        import { App } from "./App";
        import { Catalogo } from "./Catalogo";
        import "./style.css";

        createRoot(document.getElementById("root")!).render(
          <StrictMode>
            <App />
            <Catalogo />
          </StrictMode>,
        );
        """, language: .tsx)
        #expect(main.isEmpty, "acusou código certo: \(conta(main))")

        let dados = Resolvedor.problemas(text: """
        export type Peca = {
          id: string;
          nome: string;
          tipo: "ceramica" | "vidro";
          preco: number;
          estoque?: number;
        };

        export const PECAS: Peca[] = [
          { id: "06", nome: "Bule alto", tipo: "ceramica", preco: 175, estoque: 4 },
        ];
        """, language: .typescript)
        #expect(dados.isEmpty, "acusou código certo: \(conta(dados))")
    }

    @Test func comSintaxeQuebradaNaoInventa() {
        #expect(erros("const x = (\n", .typescript).isEmpty)
    }
}
