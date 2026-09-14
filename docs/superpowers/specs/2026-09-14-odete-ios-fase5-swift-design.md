# Odete iOS — Fase 5: Swift e Swift Playgrounds

Data: 2026-09-14. Depende das fases 1 a 4 (`ios/` na branch `iOS`).

## Objetivo

Projetos Swift de verdade no iPad: pacotes `.swiftpm` que o Swift Playgrounds abre e roda,
editados na Odete com destaque de sintaxe e agente, e um preview instantâneo do
subconjunto de SwiftUI renderizado como SwiftUI nativo dentro do próprio Preview. Sem
compilador no iPad: o que o interpretador não entende mostra um aviso e o botão
"Abrir no Playgrounds".

Fora desta fase: compilar Swift, SourceKit/autocompletar, depurar, UIKit.

## Componentes

### OdeteSwift (pacote novo)

- `SwiftParser`: tokenizador e parser recursivo de um subconjunto do Swift, produzindo uma
  árvore de expressões: literais (String com interpolação, Int, Double, Bool), identificadores,
  chamadas com rótulos e trailing closures, acesso a membro (`.font(.title)`), operadores
  (`+ - * / % == != < > <= >= && || !`), `if/else` dentro de closures de view, `ForEach` sobre
  intervalos e arrays literais, `@State`/`@Binding`/`let`/`var` com valores iniciais,
  `struct X: View { var body: some View { … } }`, várias structs no mesmo arquivo e em
  arquivos separados do pacote, funções simples (`func tocar() { count += 1 }`).
  Erros de sintaxe viram `SwiftDiagnostic { file, line, message }` com a linha.
- `Interpreter`: avalia a árvore com um ambiente (`[String: Value]`) por instância de view;
  `Value` = string, int, double, bool, array, color, font, closure, view. Atribuições e
  `+= -= toggle()` mutam o estado da instância, que é `@Observable` para a UI reagir.
- `ViewBuilder` (SwiftUI): `Text`, `Button`, `Toggle`, `TextField`, `Slider`, `Stepper`,
  `Image(systemName:)`, `Label`, `Divider`, `Spacer`, `VStack`, `HStack`, `ZStack`, `List`,
  `Form`, `Section`, `ScrollView`, `NavigationStack` (com `.navigationTitle`),
  `NavigationLink` (empilha), `ForEach`, `Group`, `Rectangle`, `Circle`,
  `RoundedRectangle(cornerRadius:)`, `Color.*`, `Capsule`. Modificadores: `.font`, `.bold`,
  `.foregroundStyle`/`.foregroundColor`, `.background`, `.padding`, `.frame`, `.cornerRadius`,
  `.clipShape`, `.opacity`, `.buttonStyle(.bordered/.borderedProminent/.plain)`,
  `.tint`, `.multilineTextAlignment`, `.lineLimit`, `.disabled`, `.hidden`, `.shadow`,
  `.overlay`/`.background` com view, `.onAppear` (executa uma vez), `.animation` (ignora),
  `.navigationTitle`, `.toolbar` (ignora), `.listStyle` (aplica quando conhecido).
- `PlaygroundPackage`: lê `Package.swift` do `.swiftpm` (nome, `bundleIdentifier`, targets),
  lista os `.swift`, acha o `@main struct: App` e a raiz da `WindowGroup`; `ContentView` é o
  padrão quando não há `@main`.
- `PlaygroundLauncher`: abre o `.swiftpm` no Swift Playgrounds via
  `UIDocumentInteractionController` (o UTI `com.apple.swift-playgrounds.package` é registrado
  pelo Playgrounds) e, como fallback, `UIActivityViewController` com a pasta; também "Mostrar
  no Arquivos" via `shareddocuments://` com o caminho do pacote. Se o Playgrounds não está
  instalado: link para a App Store (`itms-apps://apps.apple.com/app/id908519492`).

### App

- `Stack.detect` já marca `.swift`. Para stack Swift o Preview mostra `SwiftPreviewPane`:
  cabeçalho com o arquivo/raiz renderizada (menu com as `View`s encontradas), recarregar,
  reset de estado, viewport iPhone/iPad/livre (reaproveita `Viewport`), botão
  "Abrir no Playgrounds", e a área de render. Erros do parser e recursos fora do subconjunto
  vão para o `ProblemsPane` (fonte "swift") com toque abrindo a linha.
- O preview recompila ao salvar (o `DirectoryWatcher` já dispara o `reload`) e mantém o estado
  (`@State`) enquanto a estrutura das views não muda de nome; "reset" zera.
- Terminal: `swift` no shell explica que não há compilador no iPad e sugere Playgrounds.
- Template `swiftPlayground` ganha um `ContentView` mais rico (lista, toggle, navegação) e
  um `README` com o fluxo. Novo template `swiftUIComponent` (um arquivo só, para brincar).
- Agente: skill embutida `swiftui` atualizada com o subconjunto suportado e a dica de
  Playgrounds; a lista de arquivos e ferramentas já funcionam.

## Erros

- Sintaxe: item em Problemas com linha e um banner no preview "não entendi a linha N";
  mantém a última render boa.
- Recurso fora do subconjunto (`GeometryReader`, `Canvas`, `async`, generics…): a view vira
  um placeholder tracejado com o nome, e um aviso "fora do subconjunto: X" em Problemas;
  o botão Abrir no Playgrounds fica em destaque.
- Runtime (divisão por zero, índice fora): a view vira placeholder com a mensagem.

## Testes

- `OdeteSwiftTests`: parser (literais, chamadas, trailing closures, modificadores
  encadeados, interpolação, if/else, ForEach, structs múltiplas, erros com linha),
  interpretador (contador com `+=`, toggle, texto com interpolação, ForEach sobre range,
  TextField binding), `PlaygroundPackage` no template, render smoke via
  `ImageRenderer` de `ContentView` do template (não vazio).
- App: `SwiftPreviewPane` aparece para stack Swift (teste de `WorkspaceModel` com o template).
- Simulador: template Swift → editar `ContentView` → preview atualiza ao salvar → botão
  do Playgrounds abre a folha de compartilhamento.
