#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

python3 -m venv .venv
.venv/bin/pip install --upgrade pip
# llama-cpp-python compiles llama.cpp with Metal on Apple Silicon (a few minutes).
.venv/bin/pip install -r requirements.txt

echo "Backend virtualenv ready. Clutch launches it automatically;"
echo "to run it by hand: cd backend && .venv/bin/uvicorn main:app --port 8000"
echo "Local models are NOT downloaded here — pick one in the app's Engine Selector."
echo "For LaTeX, scripts/make_dmg.sh downloads Tectonic into build/bin (the app uses it automatically)."
