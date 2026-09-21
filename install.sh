#!/usr/bin/env bash
# Install the freshly built Chorus core + UI into the local LogosBasecamp user dir.
#
# Core dylibs get the rm + cp + `codesign --force --sign -` treatment: Apple
# Silicon validates every executable page at map time, and nix's ad-hoc
# signature (plus a reused inode from overwriting in place) makes the kernel
# SIGKILL Basecamp with "Code Signature Invalid" on the next launch.
set -euo pipefail

BASE="$HOME/Library/Application Support/Logos/LogosBasecamp"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_LGX="$HERE/core/result-portable/logos-chorus_core-module-lib.lgx"
UI_LGX="$HERE/ui/result-portable/logos-chorus-module.lgx"
VARIANT="darwin-arm64"

for f in "$CORE_LGX" "$UI_LGX"; do
    [ -f "$f" ] || { echo "missing $f — build it first" >&2; exit 1; }
done

echo "==> Quitting Basecamp"
osascript -e 'tell application "LogosBasecamp" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 20); do pgrep -f LogosBasecamp.bin >/dev/null || break; sleep 0.5; done
pkill -9 -f LogosBasecamp.bin >/dev/null 2>&1 || true
pkill -9 -f logos_host      >/dev/null 2>&1 || true
pkill -9 -f ui-host         >/dev/null 2>&1 || true
sleep 1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/core" "$TMP/ui"
tar -xzf "$CORE_LGX" -C "$TMP/core"
tar -xzf "$UI_LGX"   -C "$TMP/ui"

echo "==> Installing core -> modules/chorus_core"
DEST="$BASE/modules/chorus_core"
mkdir -p "$DEST"
for f in "$TMP/core/variants/$VARIANT"/*; do
    name="$(basename "$f")"
    rm -f "$DEST/$name"                 # fresh inode — see header comment
    cp "$f" "$DEST/$name"
    chmod u+w "$DEST/$name"
    case "$name" in
        *.dylib)
            codesign --force --sign - "$DEST/$name" >/dev/null 2>&1
            xattr -c "$DEST/$name" 2>/dev/null || true
            codesign -v "$DEST/$name" || { echo "codesign FAILED for $name" >&2; exit 1; }
            ;;
    esac
    echo "    $name"
done
cp "$TMP/core/manifest.json" "$DEST/manifest.json"
printf '%s' "$VARIANT" > "$DEST/variant"

echo "==> Installing UI -> plugins/chorus"
DEST="$BASE/plugins/chorus"
mkdir -p "$DEST"
cp -R "$TMP/ui/variants/$VARIANT/." "$DEST/"
# The manifest points `icon` at assets/icon.png, which lives at the package
# root rather than inside the variant — without this the sidebar falls back to
# a two-letter text tile.
# Replace rather than copy over: `cp -R src existing-dir` nests the new copy
# at assets/assets and leaves the previous icon in place.
if [ -d "$TMP/ui/assets" ]; then
    rm -rf "$DEST/assets"
    cp -R "$TMP/ui/assets" "$DEST/assets"
fi
cp "$TMP/ui/manifest.json" "$DEST/manifest.json"
printf '%s' "$VARIANT" > "$DEST/variant"
chmod -R u+w "$DEST"
ls "$DEST" | sed 's/^/    /'

echo "==> Done. Launch two peers with:"
echo "    open -n /Applications/LogosBasecamp.app"
echo "    CHORUS_TCPPORT=60001 open -n /Applications/LogosBasecamp.app"
