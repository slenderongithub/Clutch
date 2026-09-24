"""Self-check for per-document graph merging against a live Neo4j:
`NEO4J_PASSWORD=... python test_graph_merge.py`. Writes two throwaway test
documents, verifies shared entities are stored once, removes them, and
verifies the graph is exactly as it was. Skips if Neo4j isn't reachable."""

import graph
from models import GraphEdge, GraphNode


def snapshot():
    with graph._driver.session() as session:
        nodes = session.run("MATCH (n:Entity) RETURN n.id AS id, n.sources AS s ORDER BY id").data()
        edges = session.run(
            "MATCH (a)-[r]->(b) RETURN a.id AS a, type(r) AS t, b.id AS b, r.sources AS s ORDER BY a, t, b"
        ).data()
    return nodes, edges


def sources_of(node_id):
    with graph._driver.session() as session:
        rows = session.run("MATCH (n:Entity {id: $id}) RETURN n.sources AS s", id=node_id).data()
    return rows


def demo():
    if not graph.is_available():
        print("skipped: Neo4j not reachable")
        return
    graph.normalize_ids()
    before = snapshot()
    with graph._driver.session() as session:  # a pre-tracking entity (null sources)
        session.run("CREATE (:Entity {id: 'clutch-selftest-legacy', label: 'Clutch Selftest Legacy', type: 'Skill'})")
    a, b = "clutch-selftest-a", "clutch-selftest-b"
    try:
        # Same entities, spelled differently by two "documents".
        graph.add_document_graph(a, [
            GraphNode(id="py", label="Python", type="Skill"),
            GraphNode(id="p1", label="Clutch Selftest Engine", type="Project"),
        ], [GraphEdge(source="py", target="p1", relationship="USED_IN")])
        graph.add_document_graph(a, [GraphNode(id="x", label="Clutch Selftest Legacy", type="Skill")], [])
        graph.add_document_graph(b, [
            GraphNode(id="python-lang", label="python ", type="Skill"),
            GraphNode(id="eng", label="Clutch Selftest Engine.", type="Project"),
        ], [GraphEdge(source="python-lang", target="eng", relationship="USED_IN")])

        python_rows = sources_of("python")
        assert len(python_rows) == 1, "Python must be one node"
        assert {a, b} <= set(python_rows[0]["s"]), python_rows
        project_rows = sources_of("clutch-selftest-engine")
        assert len(project_rows) == 1 and set(project_rows[0]["s"]) == {a, b}, project_rows
        with graph._driver.session() as session:
            edge_count = session.run(
                "MATCH (:Entity {id:'python'})-[r:USED_IN]->(:Entity {id:'clutch-selftest-engine'}) RETURN count(r) AS c"
            ).single()["c"]
        assert edge_count == 1, "the shared edge must be stored once"

        graph.remove_document_graph(a)
        assert sources_of("clutch-selftest-engine")[0]["s"] == [b], "b still vouches for the project"
    finally:
        graph.remove_document_graph(a)
        graph.remove_document_graph(b)
        legacy = sources_of("clutch-selftest-legacy")
        with graph._driver.session() as session:
            session.run("MATCH (n:Entity {id: 'clutch-selftest-legacy'}) DETACH DELETE n")

    assert legacy == [{"s": [graph.LEGACY_DOC_ID]}], f"a pre-tracking node must survive, owned by the legacy doc: {legacy}"

    assert snapshot() == before, "removing both documents must restore the graph exactly"
    print("graph merge self-check passed")


if __name__ == "__main__":
    import os

    graph.configure("bolt://localhost:7687", "neo4j", os.environ.get("NEO4J_PASSWORD", ""))
    demo()
