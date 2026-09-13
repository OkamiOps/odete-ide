#!/bin/zsh
# Compila o libgit2 para iOS (device + simulador, arm64) e gera libgit2.xcframework.
# Uso: ./build-libgit2.sh [versão]   (padrão 1.9.7). Requer cmake e Xcode.
set -euo pipefail
VER="${1:-1.9.7}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/libgit2-$VER"
OUT="$HERE/build"
mkdir -p "$HERE/src" "$OUT"
if [ ! -d "$SRC" ]; then
  curl -sL -o "$HERE/src/libgit2-$VER.tar.gz" "https://github.com/libgit2/libgit2/archive/refs/tags/v$VER.tar.gz"
  tar xzf "$HERE/src/libgit2-$VER.tar.gz" -C "$HERE/src"
fi

build() { # sdk
  local sdk=$1 dir="$OUT/$1"
  rm -rf "$dir"; mkdir -p "$dir"
  cmake -S "$SRC" -B "$dir" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DBUILD_EXAMPLES=OFF -DBUILD_FUZZERS=OFF \
    -DUSE_SSH=OFF -DUSE_HTTPS=SecureTransport -DUSE_SHA1=CommonCrypto -DUSE_SHA256=CommonCrypto \
    -DUSE_BUNDLED_ZLIB=ON -DREGEX_BACKEND=builtin -DUSE_ICONV=OFF -DUSE_NTLMCLIENT=OFF -DUSE_GSSAPI=OFF \
    -DUSE_THREADS=ON -DLIBGIT2_FILENAME=git2 \
    >/dev/null
  cmake --build "$dir" --config Release --target libgit2package -- -quiet
  # junta libgit2 e dependências embutidas numa lib só
  local libs=("${(@f)$(find "$dir" -name '*.a' -path '*Release*')}")
  echo "  libs ($sdk): ${#libs[@]}"
  libtool -static -o "$dir/libgit2-all.a" "${libs[@]}"
}

build iphoneos
build iphonesimulator

rm -rf "$HERE/libgit2.xcframework"
xcodebuild -create-xcframework \
  -library "$OUT/iphoneos/libgit2-all.a" -headers "$SRC/include" \
  -library "$OUT/iphonesimulator/libgit2-all.a" -headers "$SRC/include" \
  -output "$HERE/libgit2.xcframework"
for d in "$HERE"/libgit2.xcframework/*/Headers; do
  printf 'module Clibgit2 {\n    header "git2.h"\n    export *\n}\n' > "$d/module.modulemap"
done
echo "ok: $HERE/libgit2.xcframework (libgit2 $VER)"
