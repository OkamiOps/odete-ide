#!/usr/bin/env python3
"""Monta as capturas da App Store: print real, moldura de iPad, fundo desenhado, legenda.

A Apple exige que a captura mostre o app em uso (2.3.3) — arte que não mostra a tela é
recusada. O que passa é o print de verdade com tratamento em volta, que é o que isto faz.

    python3 scripts/capturas-loja.py docs/store/shots
"""
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

RAIZ = pathlib.Path(__file__).resolve().parent.parent
FONTES = RAIZ / 'Odete/Fonts'
# Prints crus do simulador, na orientação em que o simctl os entrega (retrato, girados).
ORIG = RAIZ / 'docs/store/origem'

# iPad 13" em paisagem, a medida que o App Store Connect aceita
LARG, ALT = 2752, 2064

# O iPhone entra no mesmo molde, em retrato. O App Store Connect exige as duas famílias
# quando o app declara iPhone e iPad, e 1284×2778 é uma das medidas que ele aceita no
# lugar de 6,5". O print do iPhone já sai em pé do simulador, então não gira.
FORMATOS = {
    'ipad':   {'larg': 2752, 'alt': 2064, 'origem': 'docs/store/origem', 'gira': True,
               'titulo': 104, 'apoio': 52, 'largura_aparelho': 0.72, 'topo_texto': 150,
               'espaco': 46, 'reserva': 430, 'redige_conta': True},
    'iphone': {'larg': 1284, 'alt': 2778, 'origem': 'docs/store/origem-iphone', 'gira': False,
               'titulo': 68, 'apoio': 34, 'largura_aparelho': 0.78, 'topo_texto': 110,
               'espaco': 30, 'reserva': 300, 'redige_conta': False},
}

# tema Odete, o mesmo hex do ThemePalette
FUNDO = (8, 8, 10)
BRASA = (255, 106, 0)
CIANO = (79, 212, 234)
CLARO = (238, 238, 242)
MUDO = (154, 154, 164)


def fonte(nome: str, tam: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(FONTES / nome), tam)


# Placa de fundo gerada no Higgsfield: preto profundo, brasa em cima à esquerda,
# ciano embaixo à direita, centro vazio. A tela nunca é gerada — ela é o print de
# verdade, porque a Apple recusa captura que não mostra o app (2.3.3), e porque uma
# interface inventada não é a Odete.
PLACA = RAIZ / 'docs/store/fundo.png'


def cobre(im: Image.Image, larg: int, alt: int) -> Image.Image:
    """Redimensiona cobrindo a moldura e corta o excesso pelo centro."""
    escala = max(larg / im.width, alt / im.height)
    m = im.resize((round(im.width * escala), round(im.height * escala)), Image.LANCZOS)
    x, y = (m.width - larg) // 2, (m.height - alt) // 2
    return m.crop((x, y, x + larg, y + alt))


def fundo(larg: int = LARG, alt: int = ALT) -> Image.Image:
    if PLACA.exists():
        return cobre(Image.open(PLACA).convert('RGB'), larg, alt)
    # Sem a placa, o degradê desenhado à mão — mesma paleta, menos atmosfera.
    im = Image.new('RGB', (larg, alt), FUNDO)
    halo = Image.new('RGB', (larg // 8, alt // 8), FUNDO)
    d = ImageDraw.Draw(halo)
    w, h = halo.size
    d.ellipse((-w * 0.15, -h * 0.35, w * 0.55, h * 0.45), fill=(58, 24, 6))
    d.ellipse((w * 0.6, h * 0.55, w * 1.25, h * 1.4), fill=(6, 34, 40))
    halo = halo.filter(ImageFilter.GaussianBlur(w // 12))
    return Image.blend(im, halo.resize((larg, alt), Image.LANCZOS), 0.9)


def moldura(print_: Image.Image, larg: int) -> Image.Image:
    """iPad: bezel escuro, cantos arredondados, um fio de luz na borda de cima."""
    pw, ph = print_.size
    alt = round(ph * larg / pw)
    tela = print_.resize((larg, alt), Image.LANCZOS)

    bezel, raio = round(larg * 0.018), round(larg * 0.042)
    W, H = larg + bezel * 2, alt + bezel * 2
    corpo = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(corpo)
    d.rounded_rectangle((0, 0, W - 1, H - 1), radius=raio, fill=(26, 26, 30, 255))
    d.rounded_rectangle((0, 0, W - 1, H - 1), radius=raio, outline=(64, 64, 72, 255), width=3)

    recorte = Image.new('L', (larg, alt), 0)
    ImageDraw.Draw(recorte).rounded_rectangle(
        (0, 0, larg - 1, alt - 1), radius=round(raio * 0.7), fill=255
    )
    corpo.paste(tela, (bezel, bezel), recorte)
    return corpo


def sombra(im: Image.Image, desfoque: int = 48, desce: int = 40) -> Image.Image:
    """Sombra grande e macia, para o aparelho não flutuar recortado."""
    s = Image.new('RGBA', (im.width + desfoque * 4, im.height + desfoque * 4 + desce), (0, 0, 0, 0))
    preto = Image.new('RGBA', im.size, (0, 0, 0, 150))
    s.paste(preto, (desfoque * 2, desfoque * 2 + desce), im)
    return s.filter(ImageFilter.GaussianBlur(desfoque))


def texto_centrado(d, y, txt, f, cor, larg=LARG):
    x0, y0, x1, y1 = d.textbbox((0, 0), txt, font=f)
    d.text(((larg - (x1 - x0)) / 2 - x0, y), txt, font=f, fill=cor)
    return y1 - y0


# O print é de verdade, e o cabeçalho do agente mostra a conta de quem capturou. Publicar
# isso seria expor um endereço pessoal na App Store, então o texto sai aqui, na origem —
# e não no resultado final, senão voltaria na próxima geração.
CONTA = 'you@example.com'
CONTA_ORIGINAL = 'msant262@gmail.com'
# cabeçalho do painel do agente, no print já girado para paisagem
JANELA_CONTA = (1815, 112, 2080, 152)


def sem_conta(print_: Image.Image) -> Image.Image:
    """Troca o e-mail da conta conectada por um genérico, quando ele aparece."""
    x0, y0, x1, y1 = JANELA_CONTA
    px = print_.load()
    pontos = [
        (x, y)
        for y in range(y0, y1)
        for x in range(x0, x1)
        if (lambda r, g, b: abs(r - g) < 14 and abs(g - b) < 14 and 110 < (r + g + b) // 3 < 205)(
            *px[x, y]
        )
    ]
    if not pontos:
        return print_  # tela sem o painel do agente
    # só as linhas com densidade de texto: a borda do "Grok" logo acima também é cinza,
    # e sem esse filtro ela entra no retângulo e o cálculo do tamanho sai errado
    por_linha: dict[int, int] = {}
    for _, y in pontos:
        por_linha[y] = por_linha.get(y, 0) + 1
    linhas = [y for y, n in por_linha.items() if n >= 20]
    if not linhas:
        return print_
    ty0, ty1 = min(linhas), max(linhas)
    xs = [x for x, y in pontos if ty0 <= y <= ty1]
    tx0, tx1 = min(xs), max(xs)
    if not (170 <= tx1 - tx0 <= 270 and 12 <= ty1 - ty0 <= 26):
        return print_

    # a cor do texto é o cinza mais claro do bloco; o fundo vem da linha logo acima
    cor = max(px[x, y] for x, y in pontos)
    fundo_y = ty0 - 5
    d = ImageDraw.Draw(print_)
    for x in range(tx0 - 4, tx1 + 5):
        d.line((x, ty0 - 4, x, ty1 + 9), fill=px[x, fundo_y])

    # o corpo é o mesmo; o tamanho vem de casar a largura do texto que estava ali
    alvo = tx1 - tx0
    tam = min(
        range(14, 32),
        key=lambda s: abs(d.textlength(CONTA_ORIGINAL, font=fonte('IBMPlexSans-Regular.ttf', s))
                          - alvo),
    )
    f = fonte('IBMPlexSans-Regular.ttf', tam)
    # posicionar pelo retângulo do texto que estava ali: assim os dois compartilham a
    # linha de base, em vez de o novo descer porque tem letras com altura diferente
    bx0, by0, _, _ = d.textbbox((0, 0), CONTA_ORIGINAL, font=f)
    d.text((tx0 - bx0, ty0 - by0), CONTA, font=f, fill=cor)
    return print_


def compoe(origem: str, titulo: str, apoio: str, saida: pathlib.Path, fmt: dict) -> None:
    larg, alt = fmt['larg'], fmt['alt']
    im = fundo(larg, alt)
    d = ImageDraw.Draw(im)

    topo_texto = fmt['topo_texto']
    h = texto_centrado(d, topo_texto, titulo, fonte('IBMPlexSans-SemiBold.ttf', fmt['titulo']),
                       CLARO, larg)
    texto_centrado(d, topo_texto + h + fmt['espaco'], apoio,
                   fonte('IBMPlexSans-Regular.ttf', fmt['apoio']), MUDO, larg)

    print_ = Image.open(RAIZ / fmt['origem'] / origem).convert('RGB')
    if fmt['gira']:
        print_ = print_.rotate(-90, expand=True)
    if fmt['redige_conta']:
        print_ = sem_conta(print_)
    apar = moldura(print_, round(larg * fmt['largura_aparelho']))
    som = sombra(apar)
    # centrado no espaço que sobra abaixo do texto, com folga igual em cima e embaixo
    topo = fmt['reserva'] + (alt - fmt['reserva'] - apar.height) // 2
    im.paste(som, ((larg - som.width) // 2, topo - 96), som)
    im.paste(apar, ((larg - apar.width) // 2, topo), apar)

    im.save(saida, optimize=True)
    print(f'{saida.name}  {im.size[0]}×{im.size[1]}')


# origem, título, apoio — na ordem em que aparecem na loja
CENAS = [
    ('s4.png', 'A full IDE on the iPad',
     'Editor, terminal, git and live preview. No Mac, no server.'),
    ('s3.png', 'Real npm. Real dev server.',
     'npm install and npm run dev run on the device itself.'),
    ('s7.png', 'Git that is actually git',
     'libgit2: stage by hunk, branches, merge, pull requests.'),
    ('s6.png', 'Your projects, where you left them',
     'In the Files app, or in iCloud Drive. No account needed.'),
    ('b7.png', 'An agent that asks before it writes',
     'Every edit is a patch you accept, reject, or undo.'),
    ('c2.png', 'Eleven themes, one editor',
     'Odete, Catppuccin, Darcula, GitHub, Linear and more.'),
    ('s8.png', 'Five languages',
     'Português, English, Deutsch, Français, Español.'),
    ('de2.png', 'The whole app, in your language',
     'Screens, terminal, git and the agent. Switch without reopening.'),
]

CENAS_IPHONE = [
    ('edit.png', 'The editor, in your pocket',
     'tree-sitter, git marks, completion.'),
    ('git.png', 'Git, the real one',
     'Commit, branch, push. libgit2 on the device.'),
    ('arvore.png', 'Your project, your files',
     'In the Files app. No account needed.'),
    ('agent.png', 'An agent that asks first',
     'Every edit is a patch you accept or reject.'),
    ('settings.png', 'Eleven themes, five languages',
     'It follows your iPhone, and changes instantly.'),
]

if __name__ == '__main__':
    qual = 'iphone' if '--iphone' in sys.argv else 'ipad'
    dst = pathlib.Path([a for a in sys.argv[1:] if not a.startswith('--')][0])
    dst.mkdir(parents=True, exist_ok=True)
    fmt = FORMATOS[qual]
    cenas = CENAS_IPHONE if qual == 'iphone' else CENAS
    for i, (origem, titulo, apoio) in enumerate(cenas, 1):
        compoe(origem, titulo, apoio, dst / f'{i:02d}-{origem[:-4]}.png', fmt)
