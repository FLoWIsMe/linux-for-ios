#!/usr/bin/env bash
# Downloads and verifies the prebuilt command frameworks listed in Toolchain/manifest.tsv.
#
# Usage:
#   scripts/fetch-toolchain.sh            download anything missing, verify everything
#   scripts/fetch-toolchain.sh --check    verify only, exit non-zero if anything is missing
#   scripts/fetch-toolchain.sh --clean    remove downloaded archives and extracted frameworks
#
# Archives land in Toolchain/cache/ and are extracted to Toolchain/frameworks/<name>.xcframework.
# Both directories are ignored by git. Every archive is checked against the SHA-256 in the manifest
# before it is extracted, so a tampered or truncated download never reaches the app bundle.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/Toolchain/manifest.tsv"
CACHE="$ROOT/Toolchain/cache"
FRAMEWORKS="$ROOT/Toolchain/frameworks"

mode="fetch"
case "${1:-}" in
  --check) mode="check" ;;
  --clean) mode="clean" ;;
  "") ;;
  *) echo "usage: $0 [--check|--clean]" >&2; exit 2 ;;
esac

if [[ "$mode" == "clean" ]]; then
  rm -rf "$CACHE" "$FRAMEWORKS"
  echo "Removed $CACHE and $FRAMEWORKS"
  exit 0
fi

mkdir -p "$CACHE" "$FRAMEWORKS"

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

missing=0
while IFS=$'\t' read -r name url sha group; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  zip="$CACHE/$name.xcframework.zip"
  dest="$FRAMEWORKS/$name.xcframework"

  if [[ -f "$zip" ]] && [[ "$(sha256_of "$zip")" != "$sha" ]]; then
    echo "checksum mismatch for cached $name, re-downloading" >&2
    rm -f "$zip"
    rm -rf "$dest"
  fi

  if [[ ! -f "$zip" ]]; then
    if [[ "$mode" == "check" ]]; then
      echo "missing: $name" >&2
      missing=1
      continue
    fi
    echo "Downloading $name ($group)"
    tmp="$zip.part"
    curl --fail --location --silent --show-error --retry 3 --output "$tmp" "$url"
    actual="$(sha256_of "$tmp")"
    if [[ "$actual" != "$sha" ]]; then
      rm -f "$tmp"
      echo "error: SHA-256 mismatch for $name" >&2
      echo "  expected $sha" >&2
      echo "  actual   $actual" >&2
      exit 1
    fi
    mv "$tmp" "$zip"
    rm -rf "$dest"
  fi

  if [[ ! -d "$dest" ]]; then
    if [[ "$mode" == "check" ]]; then
      echo "not extracted: $name" >&2
      missing=1
      continue
    fi
    tmpdir="$(mktemp -d "$FRAMEWORKS/.extract.XXXXXX")"
    if command -v ditto >/dev/null 2>&1; then
      ditto -x -k "$zip" "$tmpdir"
    else
      unzip -q "$zip" -d "$tmpdir"
    fi
    found="$(find "$tmpdir" -maxdepth 2 -name '*.xcframework' -type d | head -n 1)"
    if [[ -z "$found" ]]; then
      echo "error: $zip did not contain an .xcframework" >&2
      rm -rf "$tmpdir"
      exit 1
    fi
    mv "$found" "$dest"
    rm -rf "$tmpdir"
    # The archive may name the framework differently from the manifest (libssh2-dynamic -> libssh2).
    echo "Extracted $name"
  fi
done < "$MANIFEST"

# Vim runtime files (syntax, help, ftplugins). The vim framework is Vim 8.1, so the runtime must match.
VIM_TAG="v8.1.2424"
VIM_SHA="8aec5f2c79fe2bc5536c1e6ad9a0396a76e6a4657495eafeeff8816bd2bec2e6"
VIM_RUNTIME="$ROOT/Toolchain/vimruntime/vim"
vim_zip="$CACHE/vim-$VIM_TAG.tar.gz"
if [[ ! -d "$VIM_RUNTIME" ]]; then
  if [[ "$mode" == "check" ]]; then
    echo "missing: vim runtime" >&2
    missing=1
  else
    if [[ ! -f "$vim_zip" ]] || [[ "$(sha256_of "$vim_zip")" != "$VIM_SHA" ]]; then
      echo "Downloading Vim runtime $VIM_TAG"
      curl --fail --location --silent --show-error --retry 3 --output "$vim_zip.part" \
        "https://github.com/vim/vim/archive/refs/tags/$VIM_TAG.tar.gz"
      actual="$(sha256_of "$vim_zip.part")"
      if [[ "$actual" != "$VIM_SHA" ]]; then
        rm -f "$vim_zip.part"
        echo "error: SHA-256 mismatch for the Vim runtime archive ($actual)" >&2
        exit 1
      fi
      mv "$vim_zip.part" "$vim_zip"
    fi
    tmpdir="$(mktemp -d)"
    tar -xzf "$vim_zip" -C "$tmpdir" "vim-${VIM_TAG#v}/runtime"
    src="$tmpdir/vim-${VIM_TAG#v}/runtime"
    # Trim what a phone does not need: translations, the tutor, printing support, logos, and
    # spelling files other than English UTF-8.
    rm -rf "$src/lang" "$src/tutor" "$src/print" "$src/icons" "$src/tools"
    rm -f "$src"/vimlogo.* "$src"/vim16x16.* "$src"/vim32x32.* "$src"/vim48x48.*
    find "$src/spell" -type f ! -name 'en.utf-8.spl' ! -name 'en.utf-8.sug' ! -name '*.vim' -delete
    mkdir -p "$(dirname "$VIM_RUNTIME")"
    rm -rf "$VIM_RUNTIME"
    mv "$src" "$VIM_RUNTIME"
    rm -rf "$tmpdir"
    echo "Extracted Vim runtime"
  fi
fi

if [[ "$missing" -ne 0 ]]; then
  echo "Run scripts/fetch-toolchain.sh to download the toolchain." >&2
  exit 1
fi

echo "Toolchain ready in $FRAMEWORKS"
