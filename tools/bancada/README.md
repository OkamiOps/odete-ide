# Bancada do modelo local

Roda o modelo do sistema da Apple **de verdade**, no Mac, com o mesmo contexto que o app
manda no iPad — e imprime a sequência de chamadas de ferramenta.

Existe porque o simulador não tem Apple Intelligence. Sem isto, a única forma de saber se
o agente local funciona era pedir para alguém instalar uma build e testar no iPad, o que
transforma a pessoa em bancada de teste e faz cada experimento custar uma build inteira.
Com isto, um experimento custa dez segundos.

O Mac precisa de Apple Intelligence ligado. Para conferir:

    swift -e 'import FoundationModels; print(SystemLanguageModel.default.availability)'

## Como rodar

O contexto vem do próprio app, e não de uma cópia escrita à mão que envelhece: o teste
`DespejaContexto` imprime as instruções e os schemas reais em pedaços numerados de base64
— numerados porque o `xcodebuild` entremeia a saída dos outros testes no meio deles.

    cd Packages/OdeteAgent
    xcodebuild test -scheme OdeteAgent \
      -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)' \
      -derivedDataPath ../../build 2>&1 \
      | grep -o 'ODETE_CTX [0-9]* .*' | sort -u -k2,2n \
      | cut -d' ' -f3 | tr -d '\n' | base64 -d > /tmp/contexto.json

    cd ../../tools/bancada
    xcrun swiftc -target arm64-apple-macos27.0 main.swift -o bancada
    ./bancada /tmp/contexto.json "Preciso trocar a cor do botao de contagem de cliques para azul"

Para rodar o mesmo laço contra a nuvem privada, que é o segundo modelo oferecido no app:

    ODETE_NUVEM=1 ./bancada /tmp/contexto.json "Preciso trocar a cor do botao de contagem de cliques para azul"

Saída boa é curta:

    1. read_file src/style.css
    2. str_replace src/style.css
    3. texto: A cor do botão foi alterada para azul no arquivo.

## O que ela já achou

- O bloco `Formato (obrigatório… use ## e listas)` do prompt do sistema impedia o modelo
  de chamar ferramenta: ele obedecia ao formato e respondia em prosa. Mesma conversa sem
  o bloco, ele edita.
- O modelo atende pedido que mapeia numa ferramenta ("leia src/style.css") e não decompõe
  objetivo em passos ("preciso trocar a cor do botão"). Decompor é trabalho do harness.
- Ordem de continuação sem estado vira laço: mandar "aplique com str_replace" depois de
  aplicado faz ele aplicar de novo, vinte vezes seguidas.
