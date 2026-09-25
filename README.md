# Project Title: Clutch (Local RAG Resume Architect)

## Project Overview
Clutch is a native macOS desktop application designed for AI/ML engineering students and professionals. It solves the problem of manually tailoring resumes to specific Job Descriptions (JDs). 

Instead of relying on generic cloud AI, Clutch acts as a "Personal Micro-RAG." It ingests a user's entire career history (Master Brag Document, old resumes, project readmes) into a local database. When a user pastes a JD, the app retrieves ONLY the relevant past experiences, rewrites the resume to highlight those specific skills, and compiles a pixel-perfect PDF using a local LaTeX engine.

## Core Features
1. **Dual-Engine Inference:** Users can toggle between a lightweight Cloud Mode (Gemini API) and a fully private Local Mode (downloadable ~5GB quantized LLM via MLX or Llama.cpp).
2. **Vector + Graph RAG:** Uses a Vector Database for semantic search, paired with a Knowledge Graph (an embedded SQLite file) mapping relationships between Skills, Projects, and Companies.
3. **Graphify UI:** A visual node-based explorer allowing users to interactively view the "web" of their career history.
4. **Bulletproof Output:** Uses Jinja2 templating to inject LLM text into pre-built, tested LaTeX templates, which are then compiled locally by a bundled LaTeX engine (Tectonic).

## Installing (users)
Download `Clutch.dmg`, drag Clutch to Applications. That's it — Python, the LaTeX engine, fonts and the search model all ship inside the app (Apple Silicon, macOS 14+). The only optional download is a local language model, picked in Engine Selector.

## Building the DMG
`scripts/make_dmg.sh` → `build/Clutch.dmg`. It builds the Release app, embeds a standalone Python with the backend and its dependencies (llama.cpp compiled for any Apple Silicon Mac), adds Tectonic with a pre-filled package cache and the embedding model, prunes unused packages, **verifies the bundled backend with the smoke test** (in an isolated data folder), ad-hoc signs every binary, and packs the DMG.

## Developer Setup & Prerequisites
- **macOS & Xcode:** Latest version for Swift/SwiftUI compilation.
- **Python 3.10+:** For the RAG backend (`backend/setup_backend.sh`).
- **LaTeX:** none to install — `make_dmg.sh` (or the Tectonic download in `build/bin/`) provides it; a MacTeX `pdflatex` on PATH is used as a fallback.

## Running It
1. `backend/setup_backend.sh` — creates `backend/.venv` and installs everything, including the llama.cpp runtime (compiled with Metal). No model weights are downloaded.
2. Open `Clutch.xcodeproj` and run. The app starts the backend itself (`uvicorn` on `localhost:8000`) and stops it on quit; if one is already running it's reused. Logs: `~/Library/Logs/Clutch/backend.log`.
3. On every launch Clutch asks which engine to use (Cloud or Local) for the session.

### Local models
Engine Selector → Local lists the GGUF catalog (Ornith 1.5 9B and its 8 GB edition, Qwen3 4B, Gemma 3 4B, Phi-4 mini, Llama 3.2 3B and older Qwen 2.5 / Llama 3.1), checks this Mac's chip, memory and free disk, marks each model as a good fit / tight / too big / not enough disk, and recommends the best one that fits. Downloads run in the background, can be paused/resumed (HTTP Range), and are SHA-256 verified before use. Models live in `~/Library/Application Support/Clutch/models`. Generation uses llama.cpp with output constrained to the same JSON schema as the Gemini route.

### How generation works
1. Every chunk in the library is ranked against the JD; duplicates across documents merge; bullets regroup under their project/role; headings are parsed into labelled fields (project · tech · dates, role · organization · dates, one line per school).
2. Whole entries fill an engine-sized budget (small for local models, generous for Gemini) — education, skills and contact details always included.
3. The model writes JSON constrained to a bounded schema (llama.cpp grammar locally), so it can't loop or run away.
4. A completeness pass restores anything skipped (≥3–4 projects, every role) and repairs mangled fields; name and contact come from the parsed profile, never the model.
5. The LaTeX is compiled and page-counted; spacing tightens, then least-relevant bullets trim, until it fits one page.

### Career documents
Settings → Career Documents holds everything Clutch may use about you. Drop several files at once, then **Add to Library** (keeps what's there; a same-named file replaces its old version) or **Replace Library** (starts over). Each graph entity records which documents mention it, so shared skills are one node and removing a document only removes what nothing else vouches for.

### Knowledge graph
Built automatically from your documents (projects, the tech they used, where you worked) into `~/Library/Application Support/Clutch/graph.sqlite3` — nothing to install. Settings → Knowledge Graph → Rebuild from Documents regenerates it.

### Security
The backend only listens on localhost, and every API call must carry a random token written to `~/Library/Application Support/Clutch/backend-<port>.token` (owner-only), so web pages in your browser can't drive it. The Gemini key lives in the Keychain. LaTeX runs with shell escape disabled. Nothing is sent anywhere unless you choose Gemini (Cloud) mode.

### Resumes
Resumes are plain `.tex` files in `~/Library/Application Support/Clutch/Resumes`, auto-saved as you type.

### Checks
- `cd backend && .venv/bin/python test_local_model.py` — resumable download + checksum rejection, against a local fake server.
- `cd backend && .venv/bin/python test_parsing.py` — section-aware chunking + PDF artifact cleanup.
- `cd backend && .venv/bin/python test_rag.py` — evidence parsing (projects/roles/schools), completeness pass, resume voice.
- `cd backend && .venv/bin/python test_templates.py` — all six templates render every section and compile (Tectonic or pdflatex).
- `cd backend && .venv/bin/python test_graph_merge.py` — shared entities across documents are stored once; removing documents restores the graph exactly (throwaway database).
- `backend/.venv/bin/python scripts/smoke_test.py [--generate]` — end-to-end against the running backend, token and all.
- `swiftc -parse-as-library scripts/check_chat_intent.swift Clutch/ChatIntent.swift -o /tmp/intentcheck && /tmp/intentcheck` — "make my resume" starts generation; "focus on my Go projects" doesn't.
- `swiftc -O -parse-as-library scripts/check_graph_layout.swift Clutch/ForceDirectedLayout.swift -o /tmp/layoutcheck && /tmp/layoutcheck` — graph layout never overlaps nodes.
- Debug builds accept `-ClutchRoute graph|engine|settings|resume`, `-ClutchDemoGraph YES`, `-ClutchSelectNode <id>`, `-ClutchSkipOnboarding YES`, `-ClutchAttach <file>`, `-ClutchSay "<message>"` to open straight to a state.

## Distribution Caveat
This is a student/indie project. The compiled `.dmg` will be ad-hoc signed but NOT notarized by Apple to save the $99 developer fee. 
*On first launch macOS will refuse to open it: go to System Settings → Privacy & Security → "Open Anyway" (or run `xattr -cr /Applications/Clutch.app`). A $99/yr Developer ID + notarization removes this step.*
