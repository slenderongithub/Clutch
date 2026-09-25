import logging
import os
import re
import time
from pathlib import Path

import chromadb

import parsing
from models import RetrievedChunk

logger = logging.getLogger(__name__)

from paths import DATA_DIR

_CHROMA_PATH = DATA_DIR / "library"
_OLD_CHROMA_PATH = Path(__file__).parent / ".chroma"  # pre-bundling dev location
_SOURCES_DIR = _CHROMA_PATH / "sources"  # raw text per document, for re-chunking
_LEGACY_SOURCE = _CHROMA_PATH / "source.txt"
_COLLECTION_NAME = "career_history"
# 1 = blind 150-word windows all tagged "experience"
# 2 = section-aware chunks, single document
# 3 = section-aware chunks tagged with the document they came from
# 4 = same, re-chunked after PDF-artifact cleanup ("V ellore" → "Vellore")
_SCHEMA = 4
LEGACY_DOC_ID = "earlier-upload"
# Telemetry off: Chroma sends anonymous usage events by default, and
# Clutch promises nothing leaves the Mac.
if os.environ.get("CLUTCH_EMBEDDING_DIR"):
    # The shipped app bundles the embedding model so nothing downloads on
    # first use (Chroma would otherwise fetch it into ~/.cache).
    from chromadb.utils.embedding_functions.onnx_mini_lm_l6_v2 import ONNXMiniLM_L6_V2

    ONNXMiniLM_L6_V2.DOWNLOAD_PATH = Path(os.environ["CLUTCH_EMBEDDING_DIR"])

if not _CHROMA_PATH.exists() and _OLD_CHROMA_PATH.exists():
    import shutil

    shutil.copytree(_OLD_CHROMA_PATH, _CHROMA_PATH)  # one-time move out of the source tree
_client = chromadb.PersistentClient(path=str(_CHROMA_PATH), settings=chromadb.Settings(anonymized_telemetry=False))


def _collection():
    return _client.get_or_create_collection(_COLLECTION_NAME)


def doc_id_for(name: str) -> str:
    """Stable id from the file name, so re-adding an updated "resume.pdf"
    replaces the old version instead of duplicating it."""
    return re.sub(r"[^a-z0-9]+", "-", Path(name).stem.lower()).strip("-") or "document"


def add_document(name: str, text: str, doc_id: str | None = None) -> tuple[str, int]:
    """Adds (or re-adds) one document's section-aware chunks."""
    doc_id = doc_id or doc_id_for(name)
    remove_document(doc_id)
    chunks = parsing.chunk_sections(text)
    if not chunks:
        return doc_id, 0

    _SOURCES_DIR.mkdir(parents=True, exist_ok=True)
    (_SOURCES_DIR / f"{doc_id}.txt").write_text(text)
    added_at = time.time()
    _collection().add(
        ids=[f"{doc_id}::{i}" for i in range(len(chunks))],
        documents=[chunk for _, chunk in chunks],
        metadatas=[
            {"category": category, "schema": _SCHEMA, "doc_id": doc_id, "doc_name": name, "added_at": added_at}
            for category, _ in chunks
        ],
    )
    return doc_id, len(chunks)


_DOC_ID = re.compile(r"[a-z0-9-]{1,100}")


def valid_doc_id(doc_id: str) -> str:
    """Doc ids name files under sources/ — reject anything that could escape it."""
    if not _DOC_ID.fullmatch(doc_id):
        raise ValueError(f"Invalid document id: {doc_id!r}")
    return doc_id


def remove_document(doc_id: str) -> None:
    valid_doc_id(doc_id)
    _collection().delete(where={"doc_id": doc_id})
    (_SOURCES_DIR / f"{doc_id}.txt").unlink(missing_ok=True)


def clear() -> None:
    try:
        _client.delete_collection(_COLLECTION_NAME)
    except Exception:
        pass  # didn't exist yet
    for path in _SOURCES_DIR.glob("*.txt"):
        path.unlink()


def list_documents() -> list[dict]:
    documents: dict[str, dict] = {}
    for metadata in _collection().get(include=["metadatas"])["metadatas"]:
        doc = documents.setdefault(metadata.get("doc_id", "?"), {
            "id": metadata.get("doc_id", "?"),
            "name": metadata.get("doc_name", "Untitled"),
            "added_at": metadata.get("added_at", 0),
            "chunk_count": 0,
            "categories": {},
        })
        doc["chunk_count"] += 1
        category = metadata.get("category", "experience")
        doc["categories"][category] = doc["categories"].get(category, 0) + 1
    return sorted(documents.values(), key=lambda doc: doc["added_at"])


def migrate_if_needed() -> str | None:
    """Upgrades older collections in place. Returns the doc id the existing
    data was filed under (so the graph can adopt it too), or None if
    nothing needed migrating.

    Schema-1 chunks were overlapping 150-word windows (20-word overlap), so
    their text is recoverable exactly: first chunk + each later chunk minus
    its first 20 words.
    """
    collection = _collection()
    existing = collection.get()
    if not existing["ids"] or all((m or {}).get("schema") == _SCHEMA for m in existing["metadatas"]):
        return None

    # Schema 3 → 4: every document's raw text was kept, so just re-chunk it.
    if all((m or {}).get("doc_id") for m in existing["metadatas"]):
        for doc in list_documents():
            source = _SOURCES_DIR / f"{doc['id']}.txt"
            if source.exists():
                add_document(doc["name"], parsing.clean_extracted(source.read_text()), doc_id=doc["id"])
        logger.info("Re-chunked %d documents with PDF cleanup.", len(list_documents()))
        return None

    if _LEGACY_SOURCE.exists():
        text = _LEGACY_SOURCE.read_text()
    else:
        ordered = sorted(
            (pair for pair in zip(existing["ids"], existing["documents"]) if pair[0].startswith("doc-")),
            key=lambda pair: int(pair[0].split("-")[1]),
        )
        words: list[str] = []
        for index, (_, document) in enumerate(ordered):
            words += document.split() if index == 0 else document.split()[20:]
        text = " ".join(words)

    clear()
    if text.strip():
        _, count = add_document("Earlier upload", text, doc_id=LEGACY_DOC_ID)
        logger.info("Migrated career history into document '%s' (%d chunks).", LEGACY_DOC_ID, count)
    _LEGACY_SOURCE.unlink(missing_ok=True)
    return LEGACY_DOC_ID


def is_empty() -> bool:
    return _collection().count() == 0


def search(jd_text: str, n_results: int = 8) -> list[RetrievedChunk]:
    """Semantic search over the candidate's career history for chunks
    relevant to the given job description, best match first. Profile
    (name/contact) chunks are excluded — they're always included separately."""
    collection = _collection()
    searchable = collection.count() - len(collection.get(where={"category": "profile"})["ids"])
    if searchable <= 0:
        return []
    results = collection.query(
        query_texts=[jd_text],
        n_results=min(n_results, searchable),
        where={"category": {"$ne": "profile"}},
    )

    documents = results["documents"][0] if results["documents"] else []
    metadatas = results["metadatas"][0] if results["metadatas"] else []
    distances = results["distances"][0] if results.get("distances") else [1.0] * len(documents)
    return [
        RetrievedChunk(
            text=document,
            category=(metadata or {}).get("category", "experience"),
            source=(metadata or {}).get("doc_name", ""),
            score=round(max(0.0, min(1.0, 1 - distance / 2)), 3),
        )
        for document, metadata, distance in zip(documents, metadatas, distances)
    ]


def source_text(doc_id: str) -> str:
    path = _SOURCES_DIR / f"{valid_doc_id(doc_id)}.txt"
    return path.read_text() if path.exists() else ""


def profile_text() -> str:
    """The name/contact line — the longest profile chunk across documents."""
    profiles = _collection().get(where={"category": "profile"})["documents"]
    return max(profiles, key=len) if profiles else ""


def all_chunks() -> list[tuple[str, str, str]]:
    """(doc_id, category, text) for every chunk — graph building uses this."""
    got = _collection().get(include=["documents", "metadatas"])
    return [(m.get("doc_id", ""), m.get("category", "experience"), d) for d, m in zip(got["documents"], got["metadatas"])]
