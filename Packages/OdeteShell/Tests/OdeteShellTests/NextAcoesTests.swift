import Foundation
import OdeteBundler
import OdeteNpm
import Testing

/// Server Actions: a função que roda no servidor, chamada de um formulário ou de uma ilha.
///
/// O que liga o `<form action={fn}>` à função é `$$FORM_ACTION`, que o próprio React
/// consulta no render — então o formulário funciona sem JavaScript nenhum. A ilha usa o
/// caminho de rede, porque o corpo da função não desce para o navegador.
struct NextAcoesTests {
    let base = NextIlhasTests()

    func posta(
        _ dev: DevServer,
        _ rota: String,
        _ corpo: String,
        tipo: String
    ) async throws -> (String, HTTPURLResponse?) {
        var req = URLRequest(url: rota == "/" ? dev.url : dev.url.appending(path: rota))
        req.httpMethod = "POST"
        req.setValue(tipo, forHTTPHeaderField: "content-type")
        req.httpBody = Data(corpo.utf8)
        let (d, r) = try await URLSession.shared.data(for: req)
        return (String(decoding: d, as: UTF8.self), r as? HTTPURLResponse)
    }

    @Test func formularioChamaAAcao() async throws {
        guard let raiz = try await base.projeto([
            "app/acoes.ts": """
            "use server";
            let total = 0;
            export async function somar(dados: any) { total += Number(dados.get("n") || 0); }
            export async function ler() { return total; }
            """,
            "app/page.tsx": """
            import { somar, ler } from "./acoes";
            export default async function P() {
              const n = await ler();
              return (
                <main>
                  <p id="total">{n}</p>
                  <form action={somar}><input name="n" defaultValue="3" /><button>somar</button></form>
                </main>
              );
            }
            """,
        ]) else { return }
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .next)
        defer { dev.stop() }

        let (d, _) = try await URLSession.shared.data(from: dev.url)
        let html = String(decoding: d, as: UTF8.self)
        #expect(html.contains("<p id=\"total\">0</p>"), "o estado inicial não veio: \(html.prefix(400))")
        #expect(html.contains("action=\"/\""), "o formulário não sabe para onde postar: \(html.prefix(600))")
        #expect(
            html.contains("name=\"$odete_acao\"") && html.contains("app/acoes.ts#somar"),
            "faltou o campo que diz qual ação chamar: \(html.prefix(600))"
        )

        let (depois, r) = try await posta(
            dev, "/", "$odete_acao=app%2Facoes.ts%23somar&n=5",
            tipo: "application/x-www-form-urlencoded"
        )
        #expect(r?.statusCode == 200)
        #expect(depois.contains("<p id=\"total\">5</p>"), "a ação não rodou: \(depois.prefix(400))")
    }

    /// `redirect()` de dentro da ação é lançado, e o servidor obedece.
    @Test func acaoPodeRedirecionar() async throws {
        guard let raiz = try await base.projeto([
            "app/acoes.ts": """
            "use server";
            import { redirect } from "next/navigation";
            export async function ir() { redirect("/pronto"); }
            """,
            "app/pronto/page.tsx": "export default function P() { return <p>pronto</p>; }",
            "app/page.tsx": """
            import { ir } from "./acoes";
            export default function P() { return <form action={ir}><button>ir</button></form>; }
            """,
        ]) else { return }
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .next)
        defer { dev.stop() }
        let (corpo, r) = try await posta(
            dev, "/", "$odete_acao=app%2Facoes.ts%23ir",
            tipo: "application/x-www-form-urlencoded"
        )
        #expect(r?.url?.path == "/pronto", "não redirecionou: \(String(describing: r?.url))")
        #expect(corpo.contains("<p>pronto</p>"))
    }

    /// Da ilha, a ação vai pela rede: o corpo dela não pode descer para o navegador.
    @Test func ilhaChamaAAcaoPelaRede() async throws {
        guard let raiz = try await base.projeto([
            "app/acoes.ts": """
            "use server";
            const SEGREDO = "chave-que-nao-pode-vazar";
            export async function dobro(n: number) { return { n: n * 2, tem: SEGREDO.length }; }
            """,
            "app/Botao.tsx": """
            "use client";
            import { useState } from "react";
            import { dobro } from "./acoes";
            export default function Botao() {
              const [n, setN] = useState(1);
              return <button onClick={async () => setN((await dobro(n)).n)}>{n} agora</button>;
            }
            """,
            "app/page.tsx": """
            import Botao from "./Botao";
            export default function P() { return <main><Botao /></main>; }
            """,
        ]) else { return }
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .next)
        defer { dev.stop() }

        let (d, _) = try await URLSession.shared.data(from: dev.url)
        #expect(String(decoding: d, as: UTF8.self).contains("/@odete/ilhas/"), "a página não pediu a ilha")

        let (j, _) = try await URLSession.shared.data(from: dev.url.appending(path: "@odete/ilhas/"))
        let js = String(decoding: j, as: UTF8.self)
        #expect(js.contains("/@odete/acao/"), "o talão de rede não entrou no pacote: \(js.prefix(400))")
        #expect(!js.contains("chave-que-nao-pode-vazar"), "o segredo do servidor vazou para o navegador")

        let (resp, r) = try await posta(
            dev, "@odete/acao/app%2Facoes.ts%23dobro", "[21]", tipo: "application/json"
        )
        #expect(r?.statusCode == 200)
        #expect(resp.contains("\"n\":42"), "a ação não respondeu: \(resp.prefix(300))")
    }

    /// `useActionState` liga a ação a um estado. Sem JavaScript o formulário posta e a
    /// ação roda; o estado de volta só aparece depois de hidratar, porque o
    /// `renderToString` não aceita receber o resultado do postback.
    @Test func useActionStateFicaLigado() async throws {
        guard let raiz = try await base.projeto([
            "app/acoes.ts": """
            "use server";
            export async function contar(anterior: number, dados: any) {
              return anterior + Number(dados.get("passo") || 1);
            }
            """,
            "app/Form.tsx": """
            "use client";
            import { useActionState } from "react";
            import { contar } from "./acoes";
            export default function Form() {
              const [n, acao] = useActionState(contar, 10);
              return <form action={acao}><input name="passo" defaultValue="5" /><b>{n}</b></form>;
            }
            """,
            "app/page.tsx": """
            import Form from "./Form";
            export default function P() { return <main><Form /></main>; }
            """,
        ]) else { return }
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .next)
        defer { dev.stop() }
        let (d, _) = try await URLSession.shared.data(from: dev.url)
        let html = String(decoding: d, as: UTF8.self)
        #expect(
            html.contains("name=\"$odete_acao\""),
            "o useActionState não levou a ação até o formulário: \(html.prefix(700))"
        )
        #expect(html.contains("name=\"$odete_ligados\""), "o estado ligado não foi junto")
        #expect(html.contains("value=\"[10]\""), "o estado inicial não foi serializado")

        // sem JavaScript, a ação roda mesmo assim
        let (depois, r) = try await posta(
            dev, "/", "$odete_acao=app%2Facoes.ts%23contar&$odete_ligados=%5B10%5D&passo=5",
            tipo: "application/x-www-form-urlencoded"
        )
        #expect(r?.statusCode == 200, "o postback falhou: \(depois.prefix(300))")

        // e com JavaScript o caminho é a chamada de rede, com o formulário em pares
        let (json, rj) = try await posta(
            dev, "@odete/acao/app%2Facoes.ts%23contar",
            #"[10,{"__odeteFormData":[["passo","7"]]}]"#,
            tipo: "application/json"
        )
        #expect(rj?.statusCode == 200)
        #expect(json.contains("\"valor\":17"), "a ação não somou pelo caminho da ilha: \(json)")
    }
}
