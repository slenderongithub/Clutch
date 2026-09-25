"""The career knowledge graph, stored in a small SQLite file.

A career graph is tens of nodes, so an embedded database beats a server:
nothing to install or run, and it ships inside the app (sqlite3 is in the
Python standard library). Every node and edge records which documents
mention it (`sources`), so an entity named in two documents is stored once
and removing a document only removes what nothing else vouches for.
"""

import json
import re
import sqlite3
import threading

from models import GraphEdge, GraphNode
from paths import DATA_DIR

_DB_PATH = DATA_DIR / "graph.sqlite3"
_lock = threading.Lock()  # FastAPI runs sync endpoints on a thread pool


def _connect() -> sqlite3.Connection:
    connection = sqlite3.connect(_DB_PATH)
    connection.executescript(
        """
        CREATE TABLE IF NOT EXISTS nodes (
            id TEXT PRIMARY KEY, label TEXT NOT NULL, type TEXT NOT NULL, sources TEXT NOT NULL DEFAULT '[]');
        CREATE TABLE IF NOT EXISTS edges (
            source TEXT NOT NULL, target TEXT NOT NULL, relationship TEXT NOT NULL, sources TEXT NOT NULL DEFAULT '[]',
            PRIMARY KEY (source, target, relationship));
        """
    )
    return connection


def slug(label: str) -> str:
    """Canonical entity id: the same skill/project/company named in two
    documents ("Python", "python ") always lands on the same node."""
    text = re.sub(r"\([^)]*\)", " ", label.lower())  # "MCP (FastMCP)" → "mcp"
    text = text.replace(".", "").replace("'", "")        # "Node.js" → "nodejs"
    return re.sub(r"[^a-z0-9+#]+", "-", text).strip("-") or "entity"


def is_empty() -> bool:
    with _lock, _connect() as db:
        return db.execute("SELECT COUNT(*) FROM nodes").fetchone()[0] == 0


def clear() -> None:
    with _lock, _connect() as db:
        db.execute("DELETE FROM edges")
        db.execute("DELETE FROM nodes")


def _with_source(raw: str, doc_id: str) -> str:
    sources = json.loads(raw)
    return json.dumps(sources if doc_id in sources else sources + [doc_id])


def add_document_graph(doc_id: str, nodes: list[GraphNode], edges: list[GraphEdge]) -> None:
    """Merges one document's entities into the shared graph."""
    ids = {node.id: slug(node.label) for node in nodes}
    with _lock, _connect() as db:
        for node in nodes:
            key = ids[node.id]
            row = db.execute("SELECT sources FROM nodes WHERE id = ?", (key,)).fetchone()
            if row:  # first mention keeps its label/type
                db.execute("UPDATE nodes SET sources = ? WHERE id = ?", (_with_source(row[0], doc_id), key))
            else:
                db.execute("INSERT INTO nodes VALUES (?, ?, ?, ?)", (key, node.label.strip(), node.type, json.dumps([doc_id])))
        for edge in edges:
            source, target = ids.get(edge.source), ids.get(edge.target)
            if not source or not target or source == target:
                continue
            key = (source, target, edge.relationship)
            row = db.execute("SELECT sources FROM edges WHERE source = ? AND target = ? AND relationship = ?", key).fetchone()
            if row:
                db.execute("UPDATE edges SET sources = ? WHERE source = ? AND target = ? AND relationship = ?",
                           (_with_source(row[0], doc_id), *key))
            else:
                db.execute("INSERT INTO edges VALUES (?, ?, ?, ?)", (*key, json.dumps([doc_id])))


def remove_document_graph(doc_id: str) -> None:
    """Drops one document's contributions; shared entities survive as long
    as another document still mentions them."""
    with _lock, _connect() as db:
        for table, key_columns in (("edges", "source, target, relationship"), ("nodes", "id")):
            for row in db.execute(f"SELECT {key_columns}, sources FROM {table}").fetchall():
                *key, raw = row
                sources = json.loads(raw)
                if doc_id not in sources:
                    continue
                sources.remove(doc_id)
                where = " AND ".join(f"{column.strip()} = ?" for column in key_columns.split(","))
                if sources:
                    db.execute(f"UPDATE {table} SET sources = ? WHERE {where}", (json.dumps(sources), *key))
                else:
                    db.execute(f"DELETE FROM {table} WHERE {where}", key)
        # An edge never outlives either of its endpoints.
        db.execute("DELETE FROM edges WHERE source NOT IN (SELECT id FROM nodes) OR target NOT IN (SELECT id FROM nodes)")


def fetch_career_graph() -> tuple[list[GraphNode], list[GraphEdge]]:
    with _lock, _connect() as db:
        nodes = [GraphNode(id=i, label=label, type=kind) for i, label, kind in db.execute("SELECT id, label, type FROM nodes")]
        edges = [GraphEdge(source=s, target=t, relationship=r) for s, t, r in db.execute("SELECT source, target, relationship FROM edges")]
    return nodes, edges


def related_facts(jd_text: str, limit: int = 24) -> list[str]:
    """Graph half of the retrieval: every node whose label appears in the JD
    (whole-word, case-insensitive), expanded one hop, as readable facts like
    "Python —used in→ HawkEye"."""
    nodes, edges = fetch_career_graph()
    labels = {node.id: node.label for node in nodes}
    matched = {
        node.id
        for node in nodes
        if len(node.label) > 1 and re.search(rf"(?<!\w){re.escape(node.label)}(?!\w)", jd_text, re.IGNORECASE)
    }
    facts = [
        f"{labels[e.source]} —{e.relationship.replace('_', ' ').lower()}→ {labels[e.target]}"
        for e in edges
        if (e.source in matched or e.target in matched) and e.source in labels and e.target in labels
    ]
    return facts[:limit]
