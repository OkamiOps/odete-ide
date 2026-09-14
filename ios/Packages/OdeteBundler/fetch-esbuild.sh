#!/bin/zsh
# Atualiza o esbuild-wasm empacotado. Uso: ./fetch-esbuild.sh 0.28.2
set -euo pipefail
VER="${1:?versão}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
curl -sL -o "$TMP/e.tgz" "https://registry.npmjs.org/esbuild-wasm/-/esbuild-wasm-$VER.tgz"
tar xzf "$TMP/e.tgz" -C "$TMP"
cp "$TMP/package/esbuild.wasm" "$TMP/package/lib/browser.js" "$TMP/package/LICENSE.md" "$HERE/Sources/OdeteBundler/Resources/esbuild/"
echo "$VER" > "$HERE/Sources/OdeteBundler/Resources/esbuild/VERSION"
echo "esbuild-wasm $VER"
