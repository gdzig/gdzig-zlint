#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PATCH_DIR="$REPO_ROOT/patches"

REPO="https://github.com/DonIsaac/zlint.git"
# v0.10.0 (annotated tag 31a1fc5fd8c4b45d4d9ec9f963bb9b2821baf66b)
REF="3ef67af7dfed776cb03012563942cdf3a97f1b59"
DEST="${1:-vendor/zlint}"

case "$DEST" in
    vendor/zlint|*/vendor/zlint) ;;
    *)
        echo "refusing to remove '$DEST': expected vendor/zlint" >&2
        exit 1
        ;;
esac

apply_patches() {
    for patch in "$PATCH_DIR"/*.patch; do
        [ -e "$patch" ] || continue
        if git -C "$DEST" apply --check "$patch" 2>/dev/null; then
            git -C "$DEST" apply "$patch"
            echo "Applied $(basename "$patch")"
        fi
    done
}

if [ -d "$DEST/.git" ]; then
    current="$(git -C "$DEST" rev-parse HEAD 2>/dev/null || true)"
    if [ "$current" = "$REF" ]; then
        apply_patches
        echo "zlint already at $REF"
        exit 0
    fi
fi

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
git init -q "$DEST"
git -C "$DEST" remote add origin "$REPO"
git -C "$DEST" fetch -q --depth 1 origin "$REF"
git -C "$DEST" checkout -q FETCH_HEAD

actual="$(git -C "$DEST" rev-parse HEAD)"
if [ "$actual" != "$REF" ]; then
    echo "zlint fetch mismatch: expected $REF, got $actual" >&2
    exit 1
fi

apply_patches
echo "Fetched zlint $REF into $DEST"
