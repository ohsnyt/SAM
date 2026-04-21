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
xcodebuild \
    -scheme PolishBench \
    -configuration Release \
    -destination 'platform=macOS' \
    -quiet \
    build

BUILT=$(xcodebuild \
    -scheme PolishBench \
    -configuration Release \
    -destination 'platform=macOS' \
    -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')

if [[ -z "$BUILT" || ! -d "$BUILT" ]]; then
    echo "error: could not locate BUILT_PRODUCTS_DIR" >&2
    exit 1
fi

echo "==> copying artifacts to ./build/…"
mkdir -p build
cp "$BUILT/polish-bench" build/
cp -R "$BUILT/mlx-swift_Cmlx.bundle" build/

echo ""
echo "done. run:"
echo "  ./build/polish-bench --models mlx-community/Qwen3-8B-4bit,mlx-community/Qwen3.5-9B-MLX-4bit"
