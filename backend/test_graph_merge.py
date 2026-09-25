"""Self-check for per-document graph merging: `python test_graph_merge.py`.
Runs against a throwaway SQLite graph in a temp folder — never real data."""

import os
import tempfile

os.environ["CLUTCH_DATA_DIR"] = tempfile.mkdtemp(prefix="clutch_graph_test_")

import graph  # noqa: E402  (must import after setting CLUTCH_DATA_DIR)
from models import GraphEdge, GraphNode  # noqa: E402


def sources_of(node_id: str) -> list[str] | None:
    nodes, _ = graph.fetch_career_graph()
    with graph._connect() as db:
        row = db.execute("SELECT sources FROM nodes WHERE id = ?", (node_id,)).fetchone()
    return None if row is None else __import__("json").loads(row[0])


def demo():
    assert graph.is_empty()
    graph.add_document_graph("resume", [GraphNode(id="x", label="Docker", type="Skill")], [])
    before = graph.fetch_career_graph()

    # Same entities, spelled differently by two documents.
    graph.add_document_graph("a", [
        GraphNode(id="py", label="Python", type="Skill"),
        GraphNode(id="p1", label="Clutch Engine", type="Project"),
    ], [GraphEdge(source="py", target="p1", relationship="USED_IN")])
    graph.add_document_graph("b", [
        GraphNode(id="python-lang", label="python ", type="Skill"),
        GraphNode(id="eng", label="Clutch Engine.", type="Project"),
        GraphNode(id="d", label="Docker", type="Skill"),
    ], [GraphEdge(source="python-lang", target="eng", relationship="USED_IN")])

    nodes, edges = graph.fetch_career_graph()
    assert [n.id for n in nodes].count("python") == 1, "Python must be one node"
    assert sources_of("python") == ["a", "b"] and sources_of("clutch-engine") == ["a", "b"]
    assert len([e for e in edges if (e.source, e.target) == ("python", "clutch-engine")]) == 1, "shared edge stored once"
    assert sources_of("docker") == ["resume", "b"], "an existing entity gains the new document"
    assert "Python —used in→ Clutch Engine" in graph.related_facts("Senior Python developer")

    graph.remove_document_graph("a")
    assert sources_of("clutch-engine") == ["b"], "b still vouches for the project"
    graph.remove_document_graph("b")
    assert graph.fetch_career_graph() == before, "removing both documents restores the graph exactly"

    graph.clear()
    assert graph.is_empty()
    print("graph merge self-check passed")


if __name__ == "__main__":
    demo()
