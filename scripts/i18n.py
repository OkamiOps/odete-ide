#!/usr/bin/env python3
"""Confere o catálogo contra o código.

Uma frase nova entra no app escrita em português dentro de `tr("…")`. Se ninguém
percebe, ela fica em português nos outros quatro idiomas para sempre, sem erro de
compilação e sem teste vermelho. Este script é o que percebe.

    make i18n          lista chave sem tradução e tradução sem chave
    make i18n-limpa    tira do catálogo o que não existe mais no código

Rode da pasta `ios/`.
"""
import json
import pathlib
import re
import sys

RAIZ = pathlib.Path(__file__).resolve().parent.parent
CATALOGO = RAIZ / 'Packages/OdeteI18n/Sources/OdeteI18n/Resources/Localizable.xcstrings'
IDIOMAS = ['en', 'de', 'fr', 'es']
# `tr("…")` traduz na hora; `chave("…")` só marca uma frase que vai ser traduzida
# mais tarde, quando ela chega a uma tela por variável. As duas viram chave.
CHAMADA = re.compile(r'\b(?:tr|chave)\(\s*"((?:[^"\\]|\\.)*)"')
PLACEHOLDER = re.compile(r'%\d+\$@')


ESCAPES = {'\\"': '"', '\\\\': '\\', '\\n': '\n', '\\t': '\t'}


def sem_escape(literal: str) -> str:
    """O texto como o Swift entrega em execução, não como ele aparece no fonte.

    No código a frase é `\\"Swift Playground\\"`; em execução a chave chega
    `"Swift Playground"`. Comparar a versão escapada com o catálogo faz o script
    cobrar uma chave que nunca existiu e não ver a que existe.
    """
    fora: list[str] = []
    i = 0
    while i < len(literal):
        par = literal[i:i + 2]
        if par in ESCAPES:
            fora.append(ESCAPES[par]); i += 2
        else:
            fora.append(literal[i]); i += 1
    return ''.join(fora)


def chaves_do_codigo() -> dict[str, str]:
    """chave -> primeiro lugar onde aparece."""
    achadas: dict[str, str] = {}
    for f in sorted((RAIZ / 'Packages').rglob('*.swift')):
        if '/.build/' in str(f) or '/Tests/' in str(f):
            continue
        # Linha de comentário não é código: um `tr("…")` citado numa explicação
        # viraria uma chave fantasma que nunca aparece na tela de ninguém.
        linhas = f.read_text(encoding='utf-8').splitlines(keepends=True)
        src = ''.join(' ' * len(l) if l.lstrip().startswith('//') else l for l in linhas)
        for m in CHAMADA.finditer(src):
            achadas.setdefault(sem_escape(m.group(1)), f'{f.relative_to(RAIZ)}:{src.count(chr(10), 0, m.start()) + 1}')
    return achadas


def main() -> int:
    codigo = chaves_do_codigo()
    cat = json.loads(CATALOGO.read_text(encoding='utf-8'))
    tabela = cat['strings']

    sem_entrada = [k for k in codigo if k not in tabela]
    sem_idioma: dict[str, list[str]] = {}
    placeholder_errado: list[str] = []
    for k in codigo:
        entrada = tabela.get(k, {})
        locs = entrada.get('localizations', {})
        faltam = [i for i in IDIOMAS if i not in locs]
        if faltam:
            sem_idioma[k] = faltam
        esperado = sorted(set(PLACEHOLDER.findall(k)))
        for i, v in locs.items():
            achado = sorted(set(PLACEHOLDER.findall(v['stringUnit']['value'])))
            if achado != esperado:
                placeholder_errado.append(f'{i} · {k[:60]!r}: {esperado} -> {achado}')

    orfas = [k for k in tabela if k not in codigo]

    print(f'chaves no código:  {len(codigo)}')
    print(f'chaves no catálogo: {len(tabela)}')
    for titulo, lista in [
        ('sem entrada no catálogo', sem_entrada),
        ('órfãs (no catálogo, fora do código)', orfas),
        ('placeholder diferente da chave', placeholder_errado),
    ]:
        if lista:
            print(f'\n{titulo}: {len(lista)}')
            for x in lista[:25]:
                print('  ', x if isinstance(x, str) and ' -> ' in x else f'{x[:70]!r}  {codigo.get(x, "")}')
            if len(lista) > 25:
                print(f'   … e mais {len(lista) - 25}')
    if sem_idioma:
        print(f'\nsem tradução em algum idioma: {len(sem_idioma)}')
        for k, faltam in list(sem_idioma.items())[:25]:
            print(f'   {",".join(faltam)}  {k[:70]!r}  {codigo[k]}')
        if len(sem_idioma) > 25:
            print(f'   … e mais {len(sem_idioma) - 25}')

    if '--limpa' in sys.argv and orfas:
        for k in orfas:
            del tabela[k]
        cat['strings'] = dict(sorted(tabela.items()))
        CATALOGO.write_text(json.dumps(cat, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print(f'\ntirei {len(orfas)} órfãs do catálogo')
        return 0

    ruim = sem_entrada or sem_idioma or placeholder_errado
    print('\n' + ('faltou traduzir' if ruim else 'catálogo em dia'))
    return 1 if ruim else 0


if __name__ == '__main__':
    sys.exit(main())
