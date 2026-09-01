#!/bin/sh
# Build the DocC archive for TabletKit.
#
# Deliberately not a SwiftPM plugin. swift-docc-plugin was a declared dependency
# until 2026-09-01, which meant every clone of this package — and of the app that
# consumes it — resolved two remote packages just to build code, and produced a
# Package.resolved that churned between toolchains. Docs are an occasional task,
# so they get an opt-in script instead. `docc` itself ships in the Xcode
# toolchain, so this needs nothing that isn't already installed.
#
# Usage: tools/build-docs.sh [output-path]   (default: ./TabletKit.doccarchive)
# Open the result with: open <output-path>
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
OUT="${1:-$ROOT/TabletKit.doccarchive}"
SG="$(mktemp -d)"
trap 'rm -rf "$SG"' EXIT

cd "$ROOT"

# Symbol graphs are emitted by the compiler, so they only appear when the target
# actually recompiles — a cached build silently produces none, and docc then
# resolves no symbols and warns that ``TabletKit`` doesn't exist. Build into a
# scratch directory so this never depends on, or disturbs, .build's state.
swift build --target TabletKit \
    --scratch-path "$SG/build" \
    -Xswiftc -emit-symbol-graph \
    -Xswiftc -emit-symbol-graph-dir -Xswiftc "$SG"

rm -rf "$OUT"
xcrun docc convert Sources/TabletKit/TabletKit.docc \
    --fallback-display-name TabletKit \
    --fallback-bundle-identifier com.cyzor.TabletKit \
    --additional-symbol-graph-dir "$SG" \
    --output-path "$OUT"

echo "Documentation archive: $OUT"
