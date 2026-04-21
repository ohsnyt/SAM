#!/usr/bin/env bash
# Build polish-bench via xcodebuild so MLX's Metal shaders are compiled
# into default.metallib. `swift build` can't do this — see
# mlx-swift README: "SwiftPM (command line) cannot build the Metal shaders".
#
# Output: ./build/polish-bench  +  ./build/mlx-swift_Cmlx.bundle
# Run:    ./build/polish-bench --models mlx-community/Qwen3-8B-4bit,...

set -euo pipefail
cd "$(dirname "$0")"

echo "==> xcodebuild (Release)…"
# -skipMacroValidation auto-approves MLXHuggingFaceMacros (needed for the
# #hubDownloader() / #huggingFaceTokenizerLoader() call in MLXBackend).
xcodebuild \
    -scheme PolishBench \
    -configuration Release \
    -destination 'platform=macOS' \
    -skipMacroValidation \
    -quiet \
    build

DERIVED_ROOT="$HOME/Library/Developer/Xcode/DerivedData"
BIN=$(find "$DERIVED_ROOT" -path "*polish-bench-*/Build/Products/Release/polish-bench" -type f 2>/dev/null \
    | xargs -I{} stat -f "%m %N" {} \
    | sort -rn | head -1 | cut -d' ' -f2-)

if [[ -z "$BIN" || ! -f "$BIN" ]]; then
    echo "error: could not locate built polish-bench binary" >&2
    exit 1
fi

BUILT=$(dirname "$BIN")

echo "==> copying artifacts to ./build/…"
mkdir -p build
cp "$BUILT/polish-bench" build/
cp -R "$BUILT/mlx-swift_Cmlx.bundle" build/

echo ""
echo "done. run:"
echo "  ./build/polish-bench --models mlx-community/Qwen3-8B-4bit,mlx-community/Qwen3.5-9B-MLX-4bit"
