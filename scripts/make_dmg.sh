#!/usr/bin/env bash
# Builds a self-contained Clutch.app and packs it into build/Clutch.dmg.
#
# Everything the app needs ships inside it — a standalone Python with the
# backend and its dependencies, Tectonic (LaTeX) with a pre-filled package
# cache, and the embedding model — so users install nothing else. Local
# language models are still downloaded in-app, by choice.
#
#   scripts/make_dmg.sh            full build (first run: ~10 min, mostly llama.cpp)
#   SKIP_VERIFY=1 scripts/make_dmg.sh   skip the bundled-backend smoke test
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260924/cpython-3.12.14%2B20260924-aarch64-apple-darwin-install_only.tar.gz"
TECTONIC_URL="https://github.com/tectonic-typesetting/tectonic/releases/download/tectonic%400.17.0/tectonic-0.17.0-aarch64-apple-darwin.tar.gz"
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
mkdir -p "$BUILD/downloads"

step "Building Clutch.app (Release, Apple Silicon)"
xcodebuild -project "$ROOT/Clutch.xcodeproj" -scheme Clutch -configuration Release \
  -derivedDataPath "$BUILD/xcode" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build -quiet
APP="$BUILD/Clutch.app"
rm -rf "$APP" && cp -R "$BUILD/xcode/Build/Products/Release/Clutch.app" "$APP"
RES="$APP/Contents/Resources/backend"
mkdir -p "$RES/bin" "$RES/app"

step "Python runtime + dependencies"
[ -f "$BUILD/downloads/python.tar.gz" ] || curl -fsSL "$PY_URL" -o "$BUILD/downloads/python.tar.gz"
rm -rf "$BUILD/python" && tar -xzf "$BUILD/downloads/python.tar.gz" -C "$BUILD"
PY="$BUILD/python/bin/python3"
export MACOSX_DEPLOYMENT_TARGET=14.0
"$PY" -m pip install --quiet --disable-pip-version-check -r <(grep -v '^llama-cpp-python' "$ROOT/backend/requirements.txt")
# llama.cpp compiled for *any* Apple Silicon Mac (not just this CPU), with
# Metal. --no-cache-dir so pip can't reuse a machine-tuned dev wheel.
CMAKE_ARGS="-DGGML_NATIVE=OFF -DGGML_METAL=ON" "$PY" -m pip install --quiet --disable-pip-version-check \
  --no-cache-dir --no-binary llama-cpp-python llama-cpp-python

step "Pruning what Clutch never uses"
SITE="$BUILD/python/lib/python3.12/site-packages"
# Chroma pulls in a Kubernetes client for its server mode; Clutch only runs it embedded.
rm -rf "$SITE"/kubernetes "$SITE"/pip "$SITE"/pip-* "$SITE"/setuptools "$SITE"/_distutils_hack
rm -rf "$BUILD/python/lib/python3.12"/{test,idlelib,tkinter,turtledemo,ensurepip,lib2to3} "$BUILD/python/share" "$BUILD/python/include"
find "$BUILD/python" -type d \( -name tests -o -name __pycache__ \) -prune -exec rm -rf {} +
"$PY" -m compileall -q "$BUILD/python/lib/python3.12" >/dev/null || true
rm -rf "$RES/runtime" && cp -R "$BUILD/python" "$RES/runtime"

step "Backend source"
rsync -a --delete --exclude '.venv' --exclude '.chroma' --exclude '__pycache__' --exclude 'test_*.py' \
  --exclude 'setup_backend.sh' "$ROOT/backend/" "$RES/app/"

step "Tectonic + a pre-filled LaTeX package cache"
[ -f "$BUILD/downloads/tectonic.tar.gz" ] || curl -fsSL "$TECTONIC_URL" -o "$BUILD/downloads/tectonic.tar.gz"
tar -xzf "$BUILD/downloads/tectonic.tar.gz" -C "$RES/bin"
# Compile every template once so the fonts/packages they use ship inside
# the app. Tectonic's package server can drop downloads; retry until warm.
# The warm cache persists in build/ so later builds skip the downloads.
for attempt in 1 2 3 4 5; do
  if (cd "$ROOT/backend" && CLUTCH_TECTONIC="$RES/bin/tectonic" TECTONIC_CACHE_DIR="$BUILD/tectonic-cache" \
      "$RES/runtime/bin/python3" test_templates.py >/dev/null 2>&1); then break; fi
  [ "$attempt" = 5 ] && { echo "Tectonic cache warm-up failed (network?)"; exit 1; }
  echo "   warm-up attempt $attempt hit a download glitch, retrying…"
done
rm -rf "$RES/tectonic-cache" && rsync -a --exclude '*.lock' "$BUILD/tectonic-cache/" "$RES/tectonic-cache/"

step "Embedding model"
EMB="$RES/embedding/all-MiniLM-L6-v2"
mkdir -p "$EMB"
if [ -d "$HOME/.cache/chroma/onnx_models/all-MiniLM-L6-v2/onnx" ]; then
  rsync -a "$HOME/.cache/chroma/onnx_models/all-MiniLM-L6-v2/onnx" "$EMB/"
else
  "$RES/runtime/bin/python3" -c "
from pathlib import Path
from chromadb.utils.embedding_functions.onnx_mini_lm_l6_v2 import ONNXMiniLM_L6_V2 as M
M.DOWNLOAD_PATH = Path('$EMB'); M()(['warm up'])"
  rm -f "$EMB/onnx.tar.gz"
fi

if [ "${SKIP_VERIFY:-0}" != 1 ]; then
  step "Verifying the bundled backend (isolated data dir, never your real library)"
  VERIFY_DATA="$(mktemp -d)"
  PORT=8765
  env -i HOME="$HOME" PATH=/usr/bin:/bin CLUTCH_DATA_DIR="$VERIFY_DATA" CLUTCH_MODELS_DIR="$HOME/Library/Application Support/Clutch/models" \
    CLUTCH_TECTONIC="$RES/bin/tectonic" CLUTCH_TECTONIC_SEED="$RES/tectonic-cache" TECTONIC_CACHE_DIR="$VERIFY_DATA/tectonic-cache" \
    CLUTCH_EMBEDDING_DIR="$EMB" PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 \
    bash -c "cd '$RES/app' && exec '$RES/runtime/bin/python3' -m uvicorn main:app --host 127.0.0.1 --port $PORT" \
    >"$VERIFY_DATA/backend.log" 2>&1 &
  SERVER=$!
  trap 'kill $SERVER 2>/dev/null || true' EXIT
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$PORT/api/v1/health" >/dev/null && break; sleep 1; done
  if ! CLUTCH_DATA_DIR="$VERIFY_DATA" "$RES/runtime/bin/python3" "$ROOT/scripts/smoke_test.py" --port "$PORT" --generate; then
    echo "Bundled backend failed verification — log: $VERIFY_DATA/backend.log"; exit 1
  fi
  kill $SERVER; wait $SERVER 2>/dev/null || true; trap - EXIT
  # The embedding model must have come from the bundle, not a download.
  [ ! -d "$VERIFY_DATA/.cache" ] || { echo "Something downloaded at runtime"; exit 1; }
fi

step "Signing (ad-hoc)"
# Apple Silicon refuses to run unsigned code, so every Mach-O inside the
# bundle gets signed before the app itself (which seals them in).
find "$RES" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0 |
  while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q 'Mach-O'; then codesign -f -s - "$f" 2>/dev/null; fi
  done
codesign -f -s - --options runtime "$APP"
codesign --verify --strict "$APP"

step "Packing Clutch.dmg"
STAGE="$BUILD/dmg"
rm -rf "$STAGE" "$BUILD/Clutch.dmg" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Clutch -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$BUILD/Clutch.dmg" -quiet
rm -rf "$STAGE"

echo
du -sh "$APP" "$BUILD/Clutch.dmg"
echo "Done: $BUILD/Clutch.dmg"
