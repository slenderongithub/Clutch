import logging
from typing import Literal

from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from pydantic import BaseModel

import database
import graph
import graph_extract
import latex
import llm
import local_model
import parsing
import rag
from models import (
    CompileRequest,
    GenerationResponse,
    GraphConfig,
    GraphResponse,
    JobDescriptionPayload,
    RetrievalResponse,
    RetrieveRequest,
)

logger = logging.getLogger(__name__)
_MAX_UPLOAD_BYTES = 25 * 1024 * 1024  # career documents are KBs; this only stops abuse
router = APIRouter(prefix="/api/v1")


@router.get("/health")
def health() -> dict:
    # "app" lets the Mac app tell its own backend apart from anything else
    # that happens to be listening on the port.
    return {"ok": True, "app": "clutch"}


@router.post("/ingest", response_model=GenerationResponse)
async def ingest_documents(
    files: list[UploadFile] = File(...),
    mode: Literal["add", "replace"] = Form("add"),
    gemini_api_key: str | None = Form(None),
    inference_mode: str = Form("cloud"),
    local_model_id: str | None = Form(None),
) -> GenerationResponse:
    """Ingests several career documents at once.

    mode="add" keeps the library and adds these (a file whose name is
    already in the library replaces its older version); mode="replace"
    wipes the vector store AND the graph first. In the graph, entities are
    merged across documents by name, so "Python" from two files is one node.
    """
    parsed: list[tuple[str, str]] = []
    problems: list[str] = []
    for upload in files:
        content = await upload.read(_MAX_UPLOAD_BYTES + 1)
        name = upload.filename or "document"
        if len(content) > _MAX_UPLOAD_BYTES:
            problems.append(f"{name}: larger than 25 MB")
            continue
        try:
            text = parsing.extract_text(name, content) if content else ""
        except ValueError as exc:
            problems.append(f"{name}: {exc}")
            continue
        if not text.strip():
            problems.append(f"{name}: no readable text")
            continue
        parsed.append((name, text))
    if not parsed:
        raise HTTPException(status_code=422, detail="Nothing to ingest. " + "; ".join(problems))

    graph_up = graph.is_available()
    if mode == "replace":
        database.clear()
        if graph_up:
            graph.clear()

    # The graph is built by parsing each document's sections (always works,
    # any engine); Gemini, when configured, adds relationships on top.
    enrich_with_gemini = graph_up and inference_mode == "cloud" and bool(gemini_api_key)
    summaries: list[str] = []
    total_chunks = 0
    for name, text in parsed:
        doc_id, count = database.add_document(name, text)
        total_chunks += count
        summary = f"{name}: {count} chunks"
        if graph_up:
            graph.remove_document_graph(doc_id)  # re-adding a file replaces its old entities
            nodes, edges = graph_extract.extract(parsing.chunk_sections(text))
            graph.add_document_graph(doc_id, nodes, edges)
            summary += f", {len(nodes)} graph entities"
            if enrich_with_gemini:
                try:
                    extraction = llm.extract_career_graph(text, gemini_api_key)
                    graph.add_document_graph(doc_id, extraction.nodes, extraction.edges)
                except Exception:
                    logger.exception("Gemini graph enrichment failed for %s", name)
        summaries.append(summary)

    message = ("Replaced the library with " if mode == "replace" else "Added ") + "; ".join(summaries) + "."
    if not graph_up:
        message += " (Knowledge graph offline — connect Neo4j in Settings to see these in the graph.)"
    if problems:
        message += " Skipped: " + "; ".join(problems) + "."
    return GenerationResponse(success=True, message=message, chunk_count=total_chunks)


@router.get("/documents")
def list_documents() -> list[dict]:
    return database.list_documents()


class DocumentRequest(BaseModel):
    doc_id: str


@router.post("/documents/delete")
def delete_document(payload: DocumentRequest) -> list[dict]:
    try:
        database.remove_document(payload.doc_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if graph.is_available():
        graph.remove_document_graph(payload.doc_id)
    return database.list_documents()


@router.get("/graph", response_model=GraphResponse)
def get_career_graph() -> GraphResponse:
    if not graph.is_available():
        return GraphResponse(available=False, reason=graph.last_error)
    nodes, edges = graph.fetch_career_graph()
    return GraphResponse(available=True, nodes=nodes, edges=edges)


@router.post("/graph/config", response_model=GraphResponse)
def configure_graph(config: GraphConfig) -> GraphResponse:
    """Points the backend at the user's Neo4j (sent by the app on launch
    and whenever the Settings change). Reports whether it connected."""
    connected = graph.configure(config.uri, config.user, config.password)
    if connected:
        # Entities from before per-document tracking belong to the migrated
        # upload (no-op once everything has an owner).
        graph.adopt_unowned()
        graph.normalize_ids()
    return GraphResponse(available=connected, reason=graph.last_error)


@router.post("/retrieve", response_model=RetrievalResponse)
def retrieve(payload: RetrieveRequest) -> RetrievalResponse:
    """The retrieval step on its own, so the UI can show what matched
    before (and while) the LLM writes."""
    graph_available = graph.is_available()
    return RetrievalResponse(
        chunks=rag.deduplicate(database.search(payload.jd_text, n_results=12))[:8],
        graph_facts=graph.related_facts(payload.jd_text) if graph_available else [],
        graph_available=graph_available,
    )


@router.post("/generate", response_model=GenerationResponse)
def generate_resume(payload: JobDescriptionPayload) -> GenerationResponse:
    if database.is_empty():
        raise HTTPException(status_code=400, detail="Your career library is empty. Add your resume or brag document in Settings first.")

    local = payload.inference_mode == "local"
    evidence = rag.gather(payload.jd_text, rag.LOCAL_BUDGET_WORDS if local else rag.CLOUD_BUDGET_WORDS)
    graph_facts = graph.related_facts(payload.jd_text)
    try:
        if local:
            content = llm.generate_resume_content_local(
                payload.jd_text, evidence.text, payload.local_model_id, payload.user_instructions, graph_facts
            )
        else:
            if not payload.gemini_api_key:
                raise HTTPException(status_code=400, detail="Add your Gemini API key in Engine Selector first.")
            content = llm.generate_resume_content(
                payload.jd_text, evidence.text, payload.gemini_api_key, payload.user_instructions, graph_facts
            )
    except HTTPException:
        raise
    except local_model.LocalModelError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except Exception as exc:
        logger.exception("Resume generation failed")
        detail = _friendly_gemini_error(exc) if not local else f"The local model failed: {exc}"
        raise HTTPException(status_code=502, detail=detail) from exc

    content = rag.complete(content, evidence)
    # Name and contact details come from the parsed profile, never the LLM.
    name, contact = rag.contact_from_profile(evidence.profile)
    if name:
        content.full_name = name
    tex_source = latex.fit_one_page(payload.template_id, content, contact)
    return GenerationResponse(success=True, message="Resume generated.", tex_source=tex_source)


@router.get("/generate/progress")
def generation_progress() -> dict:
    """Tokens written so far by the local model (the app polls this)."""
    return dict(local_model.progress)


@router.post("/graph/rebuild", response_model=GraphResponse)
def rebuild_graph() -> GraphResponse:
    """Rebuilds the whole graph from every document in the library."""
    if not graph.is_available():
        return GraphResponse(available=False, reason=graph.last_error)
    graph.clear()
    for doc in database.list_documents():
        text = database.source_text(doc["id"])
        if text:
            nodes, edges = graph_extract.extract(parsing.chunk_sections(text))
            graph.add_document_graph(doc["id"], nodes, edges)
    nodes, edges = graph.fetch_career_graph()
    return GraphResponse(available=True, nodes=nodes, edges=edges)


def _friendly_gemini_error(exc: Exception) -> str:
    """Maps Gemini API failures to plain language. Matches the API's status
    names, not bare numbers: resume text itself can contain "429"."""
    text = str(exc)
    if "UNAVAILABLE" in text or "overloaded" in text.lower():
        return "Gemini is overloaded right now (Google's side). Clutch retried 3 times — try again in a minute, or switch to Local in Engine Selector."
    if "RESOURCE_EXHAUSTED" in text:
        return "Gemini rate limit or quota reached for this API key. Wait a minute and try again."
    if "API_KEY_INVALID" in text or "API key not valid" in text or "PERMISSION_DENIED" in text:
        return "Gemini rejected the API key. Check it in Engine Selector."
    return f"Gemini failed: {text[:300]}"


@router.post("/compile_only", response_model=GenerationResponse)
def compile_only(payload: CompileRequest) -> GenerationResponse:
    """Compiles whatever .tex the IDE currently has open — no LLM involved."""
    try:
        pdf_path = latex.compile_tex_to_pdf(payload.tex_source)
    except RuntimeError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    return GenerationResponse(success=True, message="PDF compiled.", pdf_path=pdf_path)


# ------------------------------------------------------------ local models


class ModelRequest(BaseModel):
    model_id: str


@router.get("/local/status")
def local_status() -> dict:
    return local_model.status()


@router.post("/local/download")
def local_download(payload: ModelRequest) -> dict:
    try:
        local_model.start_download(payload.model_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=f"Unknown model: {payload.model_id}") from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return local_model.status()


@router.post("/local/cancel")
def local_cancel() -> dict:
    local_model.cancel_download()
    return local_model.status()


@router.post("/local/delete")
def local_delete(payload: ModelRequest) -> dict:
    try:
        local_model.delete_model(payload.model_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=f"Unknown model: {payload.model_id}") from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return local_model.status()
