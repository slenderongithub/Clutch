# System Architecture & Engineering Blueprint

This document defines the strict architectural boundaries of the Clutch application. The application operates on a decoupled Frontend/Backend model, even though both run locally on the user's macOS machine.

## 1. The Frontend (macOS Native UI)
- **Framework:** Swift and SwiftUI.
- **Role:** Handles all UI/UX, file selection, user settings, dual-mode toggling, and displaying the Neo4j Knowledge Graph visualizer (via Swift-compatible graphing libraries or embedded WebViews).
- **Communication:** The Swift app spawns a background Python process on launch. It communicates with this Python backend via HTTP requests (local FastAPI) or standard input/output (stdout).

## 2. The Python AI Backend
- **Role:** The brain of the operation. Handles parsing PDFs/Docs, creating embeddings, searching databases, formatting prompts, and compiling LaTeX.
- **The Pipeline:**
    1. **Ingestion:** Parses user's "Master Brag Document".
    2. **Embedding & Graphing:** Sends data to a local Vector DB (Chroma/FAISS) and local Neo4j Graph DB.
    3. **Retrieval:** Analyzes the pasted JD, queries the Vector DB for semantic matches, and queries Neo4j for relational matches (e.g., "Find all projects where Python was used").
    4. **Synthesis:** Sends the retrieved context + JD to the Inference Engine.
    5. **Compilation:** Takes the LLM output (JSON or structured text), injects it into a `.tex` template using `Jinja2`, and triggers a `subprocess` call to `pdflatex`.

## 3. The Dual-Inference Engine (The Router)
The backend must support a dynamic router based on user preference:
- **Cloud Route:** Uses the `google-genai` SDK to process the RAG payload. Fast, requires an API key, lightweight.
- **Local Route:** `backend/local_model.py` — a background download manager (Range-header resume, SHA256 verification against hashes pinned from Hugging Face) for a small GGUF catalog, and llama.cpp inference (`llama-cpp-python`, Metal) whose output is grammar-constrained to the same Pydantic schema as the cloud route. Status is polled by the app via `/api/v1/local/*`.

## Critical Engineering Caveats (DO NOT IGNORE)
1. **The LaTeX Fragility Problem:** The LLM must NEVER be asked to write raw LaTeX from scratch. It will fail. The LLM must only output JSON or plain text strings. A Python script using `Jinja2` will safely escape special characters (like `&`, `%`, `$`) and inject them into a hardcoded `.tex` template.
2. **The 5GB Download Problem:** The local model download cannot block the main thread. It must run asynchronously with a progress callback sent to the Swift frontend to update a progress bar.
3. **Anti-Hallucination:** The system prompt must strictly enforce: "If a required skill from the JD is NOT found in the retrieved database, DO NOT invent it. Omit it entirely."
