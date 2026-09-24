import logging
import os
import re

from neo4j import GraphDatabase

from models import GraphEdge, GraphNode

logger = logging.getLogger(__name__)

# Env vars seed the connection; the app can override it at runtime via
# configure() (Settings → Knowledge Graph), since a GUI-launched backend
# doesn't inherit credentials exported in a terminal.
_config = {
    "uri": os.environ.get("NEO4J_URI", "bolt://localhost:7687"),
    "user": os.environ.get("NEO4J_USER", "neo4j"),
    "password": os.environ.get("NEO4J_PASSWORD", ""),
}
last_error: str | None = None


def _make_driver():
    # Short timeout so a missing/offline Neo4j fails fast instead of stalling
    # a request — the graph is optional enrichment, never a hard dependency.
    return GraphDatabase.driver(_config["uri"], auth=(_config["user"], _config["password"]), connection_timeout=3.0)


_driver = _make_driver()

_EDGE_TYPES = ("USED_IN", "WORKED_AT", "ACCOMPLISHED")
# Owner of entities created before per-document tracking (sources = null).
LEGACY_DOC_ID = "earlier-upload"


def configure(uri: str, user: str, password: str) -> bool:
    global _driver
    _config.update(uri=uri or _config["uri"], user=user or "neo4j", password=password)
    old, _driver = _driver, _make_driver()
    old.close()
    return is_available()


def is_available() -> bool:
    global last_error
    try:
        _driver.verify_connectivity()
        last_error = None
        return True
    except Exception as exc:
        text = str(exc)
        if "Unauthorized" in text or "authentication" in text.lower():
            last_error = "Neo4j rejected the username or password."
        else:
            last_error = f"Neo4j isn't reachable at {_config['uri']}."
        logger.warning("Neo4j is not reachable: %s", exc)
        return False


def slug(label: str) -> str:
    """Canonical entity id: the same skill/project/company named in two
    documents ("Python", "python ") always lands on the same node."""
    text = re.sub(r"\([^)]*\)", " ", label.lower())  # "MCP (FastMCP)" → "mcp"
    text = text.replace(".", "").replace("'", "")        # "Node.js" → "nodejs"
    return re.sub(r"[^a-z0-9+#]+", "-", text).strip("-") or "entity"


def normalize_ids() -> None:
    """Re-keys nodes whose id isn't slug(label) (older LLM-chosen ids), merging
    into an existing node with that id if there is one, so future documents
    mentioning the same entity always land on it."""
    with _driver.session() as session:
        rows = session.run("MATCH (n:Entity) RETURN n.id AS id, n.label AS label").data()
        for row in rows:
            target = slug(row["label"] or row["id"])
            if target == row["id"]:
                continue
            exists = session.run("MATCH (n:Entity {id: $id}) RETURN count(n) AS c", id=target).single()["c"]
            if not exists:
                session.run("MATCH (n:Entity {id: $old}) SET n.id = $new", old=row["id"], new=target)
                continue
            for edge_type in _EDGE_TYPES:  # literal tuple — safe to interpolate
                session.run(
                    f"MATCH (old:Entity {{id: $old}})-[r:{edge_type}]->(b) MATCH (keep:Entity {{id: $new}}) "
                    f"WHERE b <> keep MERGE (keep)-[k:{edge_type}]->(b) "
                    f"SET k.sources = coalesce(k.sources, []) + [s IN coalesce(r.sources, []) WHERE NOT s IN coalesce(k.sources, [])]",
                    old=row["id"], new=target,
                )
                session.run(
                    f"MATCH (a)-[r:{edge_type}]->(old:Entity {{id: $old}}) MATCH (keep:Entity {{id: $new}}) "
                    f"WHERE a <> keep MERGE (a)-[k:{edge_type}]->(keep) "
                    f"SET k.sources = coalesce(k.sources, []) + [s IN coalesce(r.sources, []) WHERE NOT s IN coalesce(k.sources, [])]",
                    old=row["id"], new=target,
                )
            session.run(
                "MATCH (old:Entity {id: $old}), (keep:Entity {id: $new}) "
                "SET keep.sources = coalesce(keep.sources, []) + [s IN coalesce(old.sources, []) WHERE NOT s IN coalesce(keep.sources, [])] "
                "DETACH DELETE old",
                old=row["id"], new=target,
            )


def clear() -> None:
    with _driver.session() as session:
        session.run("MATCH (n:Entity) DETACH DELETE n")


def add_document_graph(doc_id: str, nodes: list[GraphNode], edges: list[GraphEdge]) -> None:
    """Merges one document's entities into the shared graph. Every node and
    edge records which documents mention it (`sources`), so entities shared
    across documents are stored once, and removing a document removes only
    what nothing else still vouches for."""
    ids = {node.id: slug(node.label) for node in nodes}
    canonical = {}
    for node in nodes:
        canonical.setdefault(ids[node.id], node)  # first mention wins label/type

    with _driver.session() as session:
        session.run(
            "UNWIND $nodes AS node "
            "MERGE (n:Entity {id: node.id}) "
            "ON CREATE SET n.label = node.label, n.type = node.type, n.sources = [] "
            # A pre-tracking node (null sources) keeps its original owner, so
            # removing this document later can never orphan it.
            "SET n.sources = CASE WHEN $doc IN coalesce(n.sources, [$legacy]) THEN n.sources "
            "ELSE coalesce(n.sources, [$legacy]) + $doc END",
            nodes=[{"id": key, "label": node.label.strip(), "type": node.type} for key, node in canonical.items()],
            doc=doc_id,
            legacy=LEGACY_DOC_ID,
        )
        # Relationship types can't be parameterized in Cypher, so each of
        # the 3 fixed types gets its own query. _EDGE_TYPES is a hardcoded
        # literal tuple, not user input — no Cypher-injection risk.
        for edge_type in _EDGE_TYPES:
            matching = [
                {"source": ids[edge.source], "target": ids[edge.target]}
                for edge in edges
                if edge.relationship == edge_type and edge.source in ids and edge.target in ids
                and ids[edge.source] != ids[edge.target]
            ]
            if not matching:
                continue
            session.run(
                f"UNWIND $edges AS edge "
                f"MATCH (a:Entity {{id: edge.source}}) "
                f"MATCH (b:Entity {{id: edge.target}}) "
                f"MERGE (a)-[r:{edge_type}]->(b) "
                f"ON CREATE SET r.sources = [] "
                f"SET r.sources = CASE WHEN $doc IN coalesce(r.sources, [$legacy]) THEN r.sources "
                f"ELSE coalesce(r.sources, [$legacy]) + $doc END",
                edges=matching,
                doc=doc_id,
                legacy=LEGACY_DOC_ID,
            )


def remove_document_graph(doc_id: str) -> None:
    """Drops one document's contributions; shared entities survive as long
    as another document still mentions them."""
    with _driver.session() as session:
        session.run(
            "MATCH ()-[r]->() WHERE $doc IN r.sources "
            "SET r.sources = [s IN r.sources WHERE s <> $doc] "
            "WITH r WHERE size(r.sources) = 0 DELETE r",
            doc=doc_id,
        )
        session.run(
            "MATCH (n:Entity) WHERE $doc IN n.sources "
            "SET n.sources = [s IN n.sources WHERE s <> $doc] "
            "WITH n WHERE size(n.sources) = 0 DETACH DELETE n",
            doc=doc_id,
        )


def adopt_unowned(doc_id: str = LEGACY_DOC_ID) -> None:
    """Migration: entities created before provenance tracking belong to the
    one document that existed then."""
    with _driver.session() as session:
        session.run("MATCH (n:Entity) WHERE n.sources IS NULL SET n.sources = [$doc]", doc=doc_id)
        session.run("MATCH ()-[r]->() WHERE r.sources IS NULL SET r.sources = [$doc]", doc=doc_id)


def fetch_career_graph() -> tuple[list[GraphNode], list[GraphEdge]]:
    with _driver.session() as session:
        node_records = session.run("MATCH (n:Entity) RETURN n.id AS id, n.label AS label, n.type AS type")
        nodes = [GraphNode(id=r["id"], label=r["label"], type=r["type"]) for r in node_records]

        edge_records = session.run(
            "MATCH (a:Entity)-[r]->(b:Entity) RETURN a.id AS source, b.id AS target, type(r) AS relationship"
        )
        edges = [
            GraphEdge(source=r["source"], target=r["target"], relationship=r["relationship"])
            for r in edge_records
        ]

    return nodes, edges


def related_facts(jd_text: str, limit: int = 24) -> list[str]:
    """Graph half of the retrieval: every node whose label appears in the JD
    (whole-word, case-insensitive), expanded one hop, as readable facts like
    "Python —used in→ HawkEye". Empty when Neo4j is offline."""
    if not is_available():
        return []
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
