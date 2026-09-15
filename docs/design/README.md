# Medidas tiradas de apps reais

As referências estão em `ref/`: GitHub para iPad (início e pull request), Música e
WhatsApp, os três em iPadOS 26. Cada regra abaixo foi lida de uma dessas telas, não
inventada. Quando houver dúvida de como desenhar algo, a resposta é copiar a medida
daqui, não escolher uma nova.

## Linha de lista

Referência: GitHub, tela de início.

- Ícone: quadrado arredondado de 28 pt, raio 8, fundo na cor do assunto, glifo branco
  ou na cor do assunto. Um por linha, sempre na mesma coluna.
- Rótulo: `.body`. Subtítulo, quando existe, vai **acima** do rótulo em `.caption`
  secundária (GitHub usa "desktop" pequeno em cima de "desktop" em negrito).
- Valor à direita: texto secundário, e logo depois o chevron `chevron.right` em
  `.caption2` com peso negrito.
- Números de diferença ficam na mesma linha, antes do chevron: `+599` em verde e
  `-274` em vermelho, nessa ordem, em `.callout` monoespaçado.
- Altura: 60 a 66 pt com ícone, 44 pt sem.
- Separador: começa onde o texto começa, não na borda. Nunca esconder todos.

## Seção

Referência: GitHub, tela de início e de pull request.

- O título da seção fica **fora** do cartão, colado à esquerda, em `.title3` negrito.
- O menu da seção é um `···` na mesma linha do título, na borda direita.
- O cartão branco começa embaixo do título, com raio 18 e margem lateral igual à do
  título.

## Barra lateral

Referência: Música.

- `List` sem cartão, sem separador, linhas de 40 pt.
- Item selecionado: retângulo arredondado preenchido com a cor de destaque em opacidade
  baixa, ícone e texto na cor de destaque.
- Cabeçalho de grupo em texto secundário com chevron de recolher.
- Ações do topo: texto puro ("Editar") à esquerda e ícone sem fundo à direita.

## Botões

Referência: WhatsApp e Música.

- Ação principal da tela: **um** círculo preenchido na cor de destaque, 44 pt, ícone
  branco. Só um por tela.
- Ações secundárias: símbolo puro, sem fundo, na cor de destaque ou secundária.
- Ação destacada dentro de conteúdo: cápsula preenchida com texto, largura do conteúdo.
- Filtros: cápsula com contorno fino; o selecionado fica preenchido com a cor de
  destaque em opacidade baixa e o texto na cor de destaque. Altura 32 pt.

## Barra flutuante

Referência: Música, tocador.

- Não é uma faixa de ponta a ponta. É uma cápsula de vidro flutuando sobre o conteúdo,
  com margem lateral e inferior de 16 pt.
- Os controles dentro dela são símbolos puros, sem fundo próprio.

## Barra de navegação

Referência: GitHub, tela de pull request.

- Voltar é um círculo de vidro à esquerda.
- Título no centro, com subtítulo menor embaixo quando ajuda.
- Ações à direita agrupadas numa cápsula de vidro única, não em círculos soltos.

## Etiqueta de estado

Referência: GitHub, pull request.

- Cápsula preenchida com a cor do estado, ícone e texto brancos, `.caption` negrito.
- Nome técnico (branch, sha) em cápsula de fundo tênue com fonte monoespaçada.
