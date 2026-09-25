from typing import Annotated, Literal

from pydantic import BaseModel, Field


class JobDescriptionPayload(BaseModel):
    jd_text: str
    inference_mode: Literal["cloud", "local"]
    template_id: str = "jakes_resume"
    gemini_api_key: str | None = None
    local_model_id: str | None = None
    # Extra direction typed in chat ("emphasize ML work") — style only,
    # never a license to add facts.
    user_instructions: str = ""


class RetrieveRequest(BaseModel):
    jd_text: str


class CompileRequest(BaseModel):
    """What the IDE's Compile PDF button sends — the LLM is skipped entirely."""

    tex_source: str


class RetrievedChunk(BaseModel):
    text: str
    category: str
    source: str = ""  # which ingested document it came from
    score: float  # 0..1, higher = more relevant (1 - cosine/L2 distance, clamped)


class RetrievalResponse(BaseModel):
    """What the live Context Retrieval panel shows while a resume generates."""

    chunks: list[RetrievedChunk] = []
    graph_facts: list[str] = []
    graph_available: bool = False


# The LLM fills exactly this shape — nothing else reaches the LaTeX
# template. Length caps are part of the JSON schema, so llama.cpp's grammar
# enforces them while sampling: a small model can't loop forever on bullets.
Bullet = Annotated[str, Field(max_length=260)]
Short = Annotated[str, Field(max_length=120)]


class ExperienceEntry(BaseModel):
    title: Short
    organization: Short = ""
    dates: Short = ""
    location: Short = ""
    bullets: list[Bullet] = Field(default=[], max_length=5)


class ProjectEntry(BaseModel):
    name: Short
    tech: list[Short] = Field(default=[], max_length=8)
    dates: Short = ""
    bullets: list[Bullet] = Field(default=[], max_length=4)


class EducationEntry(BaseModel):
    institution: Short
    degree: Short = ""
    dates: Short = ""
    location: Short = ""
    details: Bullet = ""


class SkillGroup(BaseModel):
    category: Short
    items: list[Short] = Field(default=[], max_length=14)


class ResumeContent(BaseModel):
    full_name: Short
    headline: Short = ""
    summary: Annotated[str, Field(max_length=420)] = ""
    education: list[EducationEntry] = Field(default=[], max_length=3)
    experience: list[ExperienceEntry] = Field(default=[], max_length=4)
    projects: list[ProjectEntry] = Field(default=[], max_length=5)
    skills: list[SkillGroup] = Field(default=[], max_length=6)
    leadership: list[ExperienceEntry] = Field(default=[], max_length=3)
    certifications: list[Short] = Field(default=[], max_length=5)
    achievements: list[Bullet] = Field(default=[], max_length=4)


class GenerationResponse(BaseModel):
    success: bool
    message: str
    tex_source: str | None = None
    pdf_path: str | None = None
    chunk_count: int | None = None


class GraphNode(BaseModel):
    id: str
    label: str
    type: Literal["Skill", "Project", "Company"]


class GraphEdge(BaseModel):
    source: str
    target: str
    relationship: Literal["USED_IN", "WORKED_AT", "ACCOMPLISHED"]


class GraphExtraction(BaseModel):
    """The LLM's structured output when extracting a career graph from text."""

    nodes: list[GraphNode] = []
    edges: list[GraphEdge] = []


class GraphResponse(BaseModel):
    """available=False means the graph couldn't be read — never a 500, so the
    Swift client can render a clear empty state instead of an error."""

    available: bool
    reason: str | None = None
    nodes: list[GraphNode] = []
    edges: list[GraphEdge] = []
