import time

from google import genai

import local_model
from models import GraphExtraction, ResumeContent

SYSTEM_PROMPT = """You are an expert resume writer. You turn a candidate's REAL career
evidence into a complete, polished, one-page resume tailored to a job description.

Hard rules:
1. Use ONLY facts in the EVIDENCE. Never invent employers, titles, dates, degrees,
   metrics, tools or skills. If the job asks for something the evidence lacks, leave it out.
2. Keep numbers exactly as written in the evidence (88.36%, 150+, 30+ FPS).
3. Output JSON matching the schema exactly.

Write a COMPLETE resume — fill every section the evidence supports:
- headline: the target role from the job description, e.g. "AI & Data Engineering — Analyst".
- summary: 2–3 sentences connecting the candidate's strongest evidence to this job.
  Resume voice — no "I", "my" or "me". Shape: "<Role> with hands-on experience in <area>;
  built <thing from evidence> that <result from evidence>." Every claim must be backed by an EVIDENCE bullet
  (don't claim "project management" or "led teams" unless the evidence says so).
- education: every institution in EDUCATION (degree, dates, location if given).
- experience: every role in EXPERIENCE, 2–4 bullets each.
- projects: the 3–5 projects most relevant to the job, 2–3 bullets each; tech = the
  project's own stack from the evidence.
- skills: 3–5 groups (e.g. "Languages", "AI/ML", "Backend & Data", "DevOps"),
  job-relevant groups and items first, only skills that appear in the evidence.
- leadership: every role in LEADERSHIP, 1–2 bullets each.
- certifications / achievements: if present in the evidence.

Bullets: start with a strong past-tense verb, one line to two lines (under 30 words),
emphasise what matters for THIS job using its vocabulary where truthful, and fix obvious
typos or missing spaces from PDF extraction.
User notes may change emphasis, order and tone — never add facts.
"""


def _resume_prompt(jd_text: str, evidence: str, instructions: str, graph_facts: list[str], jd_word_limit: int) -> str:
    jd_words = jd_text.split()
    jd = " ".join(jd_words[:jd_word_limit]) + (" …" if len(jd_words) > jd_word_limit else "")
    parts = [f"JOB DESCRIPTION:\n{jd}", f"EVIDENCE (the candidate's real history — the only source of facts):\n{evidence}"]
    if graph_facts:
        parts.append("RELATIONSHIPS FROM THE CANDIDATE'S KNOWLEDGE GRAPH:\n" + "\n".join(f"- {f}" for f in graph_facts))
    if instructions.strip():
        parts.append(f"USER NOTES: {instructions.strip()}")
    parts.append("Now write the complete resume JSON.")
    return "\n\n".join(parts)


def _is_transient(exc: Exception) -> bool:
    text = str(exc)
    return any(code in text for code in ("UNAVAILABLE", "RESOURCE_EXHAUSTED", "overloaded"))


def _gemini_generate(api_key: str, contents: str, system: str, schema, attempts: int = 3):
    """Gemini call with backoff on transient overload/rate-limit errors,
    which are common on the flash models at peak times."""
    client = genai.Client(api_key=api_key)
    for attempt in range(attempts):
        try:
            response = client.models.generate_content(
                model="gemini-3.6-flash",
                contents=contents,
                config={"system_instruction": system, "response_mime_type": "application/json", "response_schema": schema},
            )
            if response.parsed is None:
                raise ValueError(f"LLM did not return content matching the {schema.__name__} schema.")
            return response.parsed
        except Exception as exc:
            if attempt + 1 == attempts or not _is_transient(exc):
                raise
            time.sleep(2 * (attempt + 1) ** 2)  # 2s, 8s


def generate_resume_content(
    jd_text: str, evidence: str, api_key: str, instructions: str = "", graph_facts: list[str] | None = None
) -> ResumeContent:
    prompt = _resume_prompt(jd_text, evidence, instructions, graph_facts or [], jd_word_limit=1200)
    return _gemini_generate(api_key, prompt, SYSTEM_PROMPT, ResumeContent)


def generate_resume_content_local(
    jd_text: str, evidence: str, model_id: str | None, instructions: str = "", graph_facts: list[str] | None = None
) -> ResumeContent:
    # A small model's context is precious: trim the JD and cap graph facts.
    prompt = _resume_prompt(jd_text, evidence, instructions, (graph_facts or [])[:8], jd_word_limit=380)
    return local_model.generate_structured(model_id, SYSTEM_PROMPT, prompt, ResumeContent, max_tokens=2300)


GRAPH_SYSTEM_PROMPT = """You extract a career knowledge graph from raw resume/career-history text.

Identify entities of exactly three types:
- Skill (a technology, tool, or competency)
- Project (something built or delivered)
- Company (an employer or organization)

Identify relationships of exactly three types:
- USED_IN: a Skill was used in a Project
- WORKED_AT: connects a Skill or Project to the Company where it was used or built
- ACCOMPLISHED: connects a Company to a specific achievement, itself captured as a Project node

Rules:
1. Every node id must be a short, lowercase, hyphenated slug derived from its label (e.g. "python", "fleetwatch", "cloudscale-inc").
2. Every edge's source and target must reference a node id that appears in the nodes list — never reference an id that wasn't extracted as a node.
3. Only extract entities and relationships actually grounded in the text — do not invent skills, projects, or companies not present.
4. Output must match the given response schema exactly.
"""


def extract_career_graph(text: str, api_key: str) -> GraphExtraction:
    return _gemini_generate(api_key, f"Career history text:\n{text}", GRAPH_SYSTEM_PROMPT, GraphExtraction)
