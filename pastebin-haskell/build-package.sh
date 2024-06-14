#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
outfile="$PWD/../dist-newstyle/tmp/pastebin-haskell.tar.gz"

tempdir="$(mktemp -d)"
trap 'rm -rf "$tempdir"' EXIT

cabal install pastebin-haskell --installdir="$tempdir"

cp "$(realpath "$tempdir/pastebin-haskell")" "$tempdir/pastebin-haskell-exec"
mv "$tempdir/pastebin-haskell-exec" "$tempdir/pastebin-haskell"

for f in $(grep '^extra-source-files:' pastebin-haskell.cabal | cut -d: -f2 | tr ' ' $'\n' | grep -v 'ChangeLog.md'); do
  mkdir -p "$tempdir/$(dirname "$f")"
  cp "$f" "$tempdir/$f"
done

(
	cd "$tempdir"
	tar -cvzf "$outfile" -- *
)

echo "Written to:"
echo "$outfile"

echo "Deploy to tomsmeding.com? [y/N]"
read -r RESPONSE
if [[ $RESPONSE = y || $RESPONSE = Y ]]; then
  ssh tomsmeding.com tar -C git/pastebin-haskell/deploy -xz <../dist-newstyle/tmp/pastebin-haskell.tar.gz
  echo "Please restart the service on the VPS:"
  echo "$ sudo systemctl restart tom-pastebin-haskell"
fi
