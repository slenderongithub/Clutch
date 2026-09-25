# Project Title: Clutch (Local RAG Resume Architect)

## Project Overview
Clutch is a native macOS desktop application designed for AI/ML engineering students and professionals. It solves the problem of manually tailoring resumes to specific Job Descriptions (JDs). 

Instead of relying on generic cloud AI, Clutch acts as a "Personal Micro-RAG." It ingests a user's entire career history (Master Brag Document, old resumes, project readmes) into a local database. When a user pastes a JD, the app retrieves ONLY the relevant past experiences, rewrites the resume to highlight those specific skills, and compiles a pixel-perfect PDF using a local LaTeX engine.

## Core Features
1. **Dual-Engine Inference:** Users can toggle between a lightweight Cloud Mode (Gemini API) and a fully private Local Mode (downloadable ~5GB quantized LLM via MLX or Llama.cpp).
2. **Vector + Graph RAG:** Uses a Vector Database for semantic search, paired with a Neo4j Knowledge Graph to map relationships between Skills, Projects, and Companies.
3. **Graphify UI:** A visual node-based explorer allowing users to interactively view the "web" of their career history.
4. **Bulletproof Output:** Uses Jinja2 templating to inject LLM text into pre-built, tested LaTeX templates, which are then compiled locally via `pdflatex`.

## Developer Setup & Prerequisites
To compile and run this project, the host machine must have:
- **macOS & Xcode:** Latest version for Swift/SwiftUI compilation.
- **Python 3.10+:** For the RAG backend, text processing, and Jinja2 templating.
- **MacTeX (LaTeX):** Specifically `pdflatex` accessible in the system PATH.
- **Neo4j Community Edition:** Running locally for the GraphRAG features.

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
Optional. Set the Neo4j URI/user/password in Settings → Knowledge Graph (a GUI-launched backend can't see credentials exported in a terminal). Without Neo4j, retrieval falls back to vector search and the Knowledge Graph screen offers a sample graph.

### Resumes
Resumes are plain `.tex` files in `~/Library/Application Support/Clutch/Resumes`, auto-saved as you type.

### Checks
- `cd backend && .venv/bin/python test_local_model.py` — resumable download + checksum rejection, against a local fake server.
- `cd backend && .venv/bin/python test_parsing.py` — section-aware chunking + PDF artifact cleanup.
- `cd backend && .venv/bin/python test_rag.py` — evidence parsing (projects/roles/schools), completeness pass, resume voice.
- `cd backend && .venv/bin/python test_templates.py` — all six templates render every section and compile (needs MacTeX).
- `cd backend && NEO4J_PASSWORD=... .venv/bin/python test_graph_merge.py` — against a live Neo4j: shared entities across documents are stored once, removing documents restores the graph exactly (self-cleaning).
- `swiftc -parse-as-library scripts/check_chat_intent.swift Clutch/ChatIntent.swift -o /tmp/intentcheck && /tmp/intentcheck` — "make my resume" starts generation; "focus on my Go projects" doesn't.
- `swiftc -O -parse-as-library scripts/check_graph_layout.swift Clutch/ForceDirectedLayout.swift -o /tmp/layoutcheck && /tmp/layoutcheck` — graph layout never overlaps nodes.
- Debug builds accept `-ClutchRoute graph|engine|settings|resume`, `-ClutchDemoGraph YES`, `-ClutchSelectNode <id>`, `-ClutchSkipOnboarding YES`, `-ClutchAttach <file>`, `-ClutchSay "<message>"` to open straight to a state.

## Distribution Caveat
This is a student/indie project. The compiled `.dmg` will be ad-hoc signed but NOT notarized by Apple to save the $99 developer fee. 
*Users must bypass Gatekeeper to use the app by right-clicking the App and selecting "Open", or by running `xattr -cr /Applications/Clutch.app` in their terminal.*
