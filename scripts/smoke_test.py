"""End-to-end smoke test against a running Clutch backend, the way the app
talks to it (token header included). Uses a throwaway document and cleans up.

    backend/.venv/bin/python scripts/smoke_test.py [--port 8000] [--generate]

--generate also runs a full local-model generation (~1 minute).
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

PORT = int(sys.argv[sys.argv.index("--port") + 1]) if "--port" in sys.argv else 8000
BASE = f"http://127.0.0.1:{PORT}/api/v1"
DATA_DIR = Path(os.environ.get("CLUTCH_DATA_DIR", Path.home() / "Library/Application Support/Clutch"))
TOKEN = (DATA_DIR / f"backend-{PORT}.token").read_text().strip()
PROBE = "clutch-smoke-probe"
results: list[tuple[str, bool, str]] = []


def call(path, body=None, token=True, multipart=None, timeout=60):
    headers = {"X-Clutch-Token": TOKEN} if token else {}
    data = None
    if multipart:
        boundary = uuid.uuid4().hex
        parts = []
        for name, value in multipart:
            if isinstance(value, tuple):
                filename, content = value
                parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
                             f"Content-Type: text/plain\r\n\r\n{content}\r\n")
            else:
                parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n')
        data = ("".join(parts) + f"--{boundary}--\r\n").encode()
        headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(BASE + path, data=data, headers=headers, method="POST" if data else "GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.loads(response.read() or b"null")
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read() or b"null")


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print(f"{'✓' if ok else '✗'} {name}" + (f" — {detail}" if detail else ""))


def main():
    status, body = call("/health", token=False)
    check("health is open and identifies Clutch", status == 200 and body.get("app") == "clutch")
    check("API rejects calls without the token", call("/documents", token=False)[0] == 401)

    status, docs = call("/documents")
    check("list documents", status == 200, f"{len(docs)} in library")
    before = {d["id"] for d in docs}

    probe = ("Probe Person probe@example.com\nEducation\nProbe University B.S. Computer Science 2019 – 2023\n"
             "Projects\nOrbitDB – Toy database[Rust, SQLite]2024 ∙ Built an LSM tree in Rust\n"
             "Experience\nIntern 2023 Probe Corp ∙ Shipped a Kotlin app\nTechnical Skills\nLanguages: Rust, Kotlin\n")
    status, body = call("/ingest", multipart=[("mode", "add"), ("files", (f"{PROBE}.txt", probe))])
    check("ingest (add mode) a document", status == 200, body.get("message", "")[:90] if status == 200 else str(body))
    status, docs = call("/documents")
    added = [d for d in docs if d["id"] == PROBE]
    check("document listed with categories", added and {"project", "experience", "skill"} <= set(added[0]["categories"]),
          str(added[0]["categories"]) if added else "missing")
    check("add mode kept the existing library", before <= {d["id"] for d in docs})

    status, body = call("/retrieve", {"jd_text": "Rust database engineer"})
    top = body["chunks"][0] if status == 200 and body["chunks"] else {}
    check("retrieval ranks the relevant chunk first", "OrbitDB" in top.get("text", ""), f"{top.get('score')} [{top.get('category')}]")

    status, graph = call("/graph")
    if status == 200 and graph.get("available"):
        labels = {n["label"] for n in graph["nodes"]}
        check("graph built from the document (no LLM)", {"OrbitDB", "Rust"} <= labels)
    else:
        check("graph (Neo4j offline — skipped)", True, graph.get("reason", ""))

    status, local = call("/local/status")
    ready = [m["name"] for m in local.get("models", []) if m["state"] == "ready"]
    if "--generate" in sys.argv and ready:
        jd = "Analyst, AI & Data: build Python data pipelines, cloud migration, AI agents, Docker, stakeholder communication."
        started = time.time()
        status, body = call("/generate", {"jd_text": jd, "inference_mode": "local", "template_id": "jakes_resume",
                                          "user_instructions": "keep every section"}, timeout=900)
        tex = body.get("tex_source", "") if status == 200 else ""
        sections = [s for s in ("Education", "Experience", "Projects", "Skills") if f"\\section{{{s}" in tex]
        check("local generation → complete resume", len(sections) == 4, f"{time.time() - started:.0f}s, sections: {sections}"
              if status == 200 else str(body)[:200])
        if tex:
            status, body = call("/compile_only", {"tex_source": tex})
            check("generated resume compiles", status == 200)

    status, body = call("/documents/delete", {"doc_id": "../escape-attempt"})
    check("path traversal rejected", status == 400)
    status, docs = call("/documents/delete", {"doc_id": PROBE})
    check("delete document", status == 200 and PROBE not in {d["id"] for d in docs})
    status, graph = call("/graph")
    if status == 200 and graph.get("available"):
        check("its graph entities are gone", "OrbitDB" not in {n["label"] for n in graph["nodes"]})

    tex = r"\documentclass{article}\begin{document}Hello \immediate\write18{touch /tmp/clutch_pwned}\end{document}"
    status, body = call("/compile_only", {"tex_source": tex})
    check("compile works and shell escape is disabled", status == 200 and not Path("/tmp/clutch_pwned").exists())

    status, local = call("/local/status")
    ready = [m["name"] for m in local.get("models", []) if m["state"] == "ready"]
    check("local model status + device fit", status == 200 and "device" in local,
          f"{local['device']['chip']}, {local['device']['memory_gb']} GB · ready: {ready or 'none'} · recommended: {local.get('recommended_id')}")
    check("progress endpoint", call("/generate/progress")[0] == 200)

    failed = [name for name, ok, _ in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} passed" + (f" — FAILED: {failed}" if failed else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
