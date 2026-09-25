"""Builds a career graph straight from section-aware chunks — no LLM.

Resumes state the structure explicitly ("HawkEye – Drone-Based Anomaly
Detection [Python, YOLOv11, FastAPI]", "Marketing Lead 2024 – 2025 Microsoft
Student Chapter, VIT-AP University"), so parsing it is fast, free, works
offline and in Local mode, and gives the same answer every time. An LLM
extraction (cloud) can still be merged on top for extra relationships.
"""

import re

from models import GraphEdge, GraphNode

_PROJECT_NAME = re.compile(r"^(.+?)\s[–—]\s")
_BRACKETS = re.compile(r"\[([^\]]+)\]")
_PIPE_STACK = re.compile(r"\|\s*([^|]+?)\s*(?:\d{4}|$)")
_ORG_AFTER_DATES = re.compile(r"\b(?:19|20)\d{2}(?:\s*[–—-]\s*(?:(?:19|20)\d{2}|Present))?\s+([A-Z][^,]{2,80})")
_SKILL_GROUP = re.compile(r"([A-Za-z][\w/&+.\- ]{1,40}):\s*")


def _split_chunk(text: str) -> tuple[str, str, str]:
    section, _, rest = text.partition(": ")
    heading, _, bullet = rest.partition(" — ")
    return section, heading.strip(), bullet.strip()


def _items(text: str) -> list[str]:
    return [item.strip(" .;") for item in re.split(r",|;", text) if 1 < len(item.strip(" .;")) <= 40]


def _mentions(skill: str, text: str) -> bool:
    # Short names ("Go", "C", "R") must match case-sensitively as whole words,
    # or "go" in ordinary prose would link everything to the Go language.
    flags = 0 if len(skill) <= 3 else re.IGNORECASE
    return re.search(rf"(?<![\w+#]){re.escape(skill)}(?![\w+#])", text, flags) is not None


def extract(chunks: list[tuple[str, str]]) -> tuple[list[GraphNode], list[GraphEdge]]:
    """chunks: (category, text) pairs from parsing.chunk_sections."""
    vocabulary: set[str] = set()
    for category, text in chunks:
        if category == "skill":
            body = text.partition(": ")[2]
            for group in _SKILL_GROUP.split(body)[2::2]:  # values after each "Label:"
                vocabulary.update(_items(group))

    projects: dict[str, set[str]] = {}  # name → skills
    companies: dict[str, set[str]] = {}
    for category, text in chunks:
        section, heading, bullet = _split_chunk(text)
        if category == "project":
            match = _PROJECT_NAME.match(heading)
            name = (match.group(1) if match else heading.split("|")[0].split("[")[0]).strip()
            if not name or len(name) > 50:
                continue
            stack = projects.setdefault(name, set())
            stacks = _BRACKETS.findall(heading) or _PIPE_STACK.findall(heading)
            for group in stacks:
                stack.update(_items(group))
            stack.update(skill for skill in vocabulary if _mentions(skill, bullet))
        elif category == "experience":
            org_match = _ORG_AFTER_DATES.search(heading)
            if not org_match:
                continue
            org = re.split(r"\s(?:Under|under)\s|\(", org_match.group(1))[0].strip()
            if 2 < len(org) <= 60:
                companies.setdefault(org, set()).update(s for s in vocabulary if _mentions(s, bullet))

    nodes: dict[str, GraphNode] = {}
    edges: list[GraphEdge] = []

    def node(label: str, kind: str) -> str:
        key = label.lower()
        nodes.setdefault(key, GraphNode(id=key, label=label, type=kind))
        return key

    for name, skills in projects.items():
        project = node(name, "Project")
        for skill in sorted(skills):
            edges.append(GraphEdge(source=node(skill, "Skill"), target=project, relationship="USED_IN"))
    for org, skills in companies.items():
        company = node(org, "Company")
        for skill in sorted(skills):
            edges.append(GraphEdge(source=node(skill, "Skill"), target=company, relationship="WORKED_AT"))
    return list(nodes.values()), edges
