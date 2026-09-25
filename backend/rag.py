"""Turns the career library into the evidence an LLM writes a resume from,
and guarantees the result is complete.

Why not plain top-k retrieval: a resume needs *whole* entries (a project
with all its bullets, every role, education, contact details), and a career
library is small — a few documents, dozens of chunks. So every chunk is
ranked against the JD, near-duplicates across documents (two versions of the
same resume) are merged, bullets are grouped back under their project/role,
and whole entries are added in relevance order until the engine's word
budget is used. Education, skills and contact details are always included.

Entry headings are parsed into labelled fields (project name / tech / dates,
role / organization / dates, one line per school) so even a small local
model reads facts, not PDF soup. After generation, `complete()` tops up
whatever the model skipped and repairs fields it mangled — the model tailors,
the code guarantees completeness.
"""

import re
from dataclasses import dataclass, field

import database
from models import EducationEntry, ExperienceEntry, ProjectEntry, ResumeContent, RetrievedChunk, SkillGroup

# Evidence size per engine. A 3–9B local model with an 8k context window
# needs room for the JD, instructions and ~1.5k tokens of output.
LOCAL_BUDGET_WORDS = 1300
CLOUD_BUDGET_WORDS = 6000

_SECTION_ORDER = ["Experience", "Projects", "Leadership", "Education", "Skills", "Certifications", "Achievements"]
_ALWAYS = {"Education", "Skills", "Certifications"}

_MONTH = r"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?"
_DATE = rf"(?:{_MONTH}\s+)?(?:19|20)\d{{2}}"
_RANGE = re.compile(rf"{_DATE}(?:\s*[–—-]\s*(?:{_DATE}|Present|Current|Now))?", re.I)
_REAL_RANGE = re.compile(rf"{_DATE}\s*[–—-]\s*(?:{_DATE}|Present|Current|Now)", re.I)
_DEGREE = re.compile(
    r"\b(B\.?\s?Tech|B\.?\s?E\b|B\.?S\.?c?\b|B\.?A\.?\b|M\.?\s?Tech|M\.?S\.?c?\b|MBA|Ph\.?D|Bachelor|Master|Diploma|"
    r"CBSE|ICSE|Class\s+[XIV]+|High School|HSC|SSC)"
)


@dataclass
class Entry:
    section: str
    heading: str
    bullets: list[str] = field(default_factory=list)
    score: float = 0.0
    # Parsed fields (projects: name/subtitle/tech; roles: title/org; both: dates)
    name: str = ""
    subtitle: str = ""
    tech: list[str] = field(default_factory=list)
    dates: str = ""

    @property
    def key(self) -> str:
        return _norm(self.name or self.heading)[:60]


@dataclass
class Evidence:
    text: str
    profile: str
    chunks: list[RetrievedChunk]  # ranked, deduplicated — what the panel shows
    entries: list[Entry] = field(default_factory=list)
    education: list[EducationEntry] = field(default_factory=list)


def _norm(text: str) -> str:
    return " ".join(re.findall(r"[a-z0-9]+", text.lower()))


def _words(text: str) -> set[str]:
    return set(re.findall(r"[a-z0-9]+", text.lower()))


def _similar(a: str, b: str, threshold: float = 0.8) -> bool:
    wa, wb = _words(a), _words(b)
    return bool(wa and wb) and len(wa & wb) / len(wa | wb) >= threshold


def _canonical_section(section: str) -> str:
    lowered = section.lower()
    for name, keys in (
        ("Projects", ("project", "publication")),
        ("Leadership", ("leadership", "volunteer", "activit")),
        ("Education", ("education",)),
        ("Skills", ("skill",)),
        ("Certifications", ("certification",)),
        ("Achievements", ("achievement", "award", "honor")),
    ):
        if any(key in lowered for key in keys):
            return name
    return "Experience"


def _split(chunk_text: str) -> tuple[str, str, str | None]:
    """"Projects: HawkEye – Drone… — Built X" → ("Projects", "HawkEye – Drone…", "Built X")."""
    section, _, rest = chunk_text.partition(": ")
    if not rest:
        return "Experience", chunk_text, None
    heading, sep, bullet = rest.partition(" — ")
    return _canonical_section(section), heading.strip(), (bullet.strip() if sep else None)


def _items(text: str) -> list[str]:
    return [item.strip(" .;|") for item in re.split(r",(?![^()]*\))", text) if item.strip(" .;|")]


def parse_project(heading: str) -> tuple[str, str, list[str], str]:
    """"amux – Concurrent CLI|Go, TypeScript (Bun), SQLite2026" →
    ("amux", "Concurrent CLI", ["Go", "TypeScript (Bun)", "SQLite"], "2026")."""
    rest = heading
    dates = ""
    trailing = re.search(rf"({_RANGE.pattern})\s*$", rest, re.I)
    if trailing:
        dates, rest = trailing.group(1).strip(), rest[: trailing.start()]
    tech: list[str] = []
    bracket = re.search(r"\[([^\]]+)\]", rest)
    if bracket:
        tech, rest = _items(bracket.group(1)), rest[: bracket.start()] + rest[bracket.end() :]
    elif "|" in rest:
        rest, _, stack = rest.partition("|")
        tech = _items(stack)
    parts = re.split(r"\s[–—]\s", rest, maxsplit=1)
    name = parts[0].strip(" |,")
    subtitle = parts[1].strip(" |,") if len(parts) > 1 else ""
    return name, subtitle, tech, dates


def parse_role(heading: str) -> tuple[str, str, str]:
    """"Marketing Lead 2024 – 2025 Microsoft Student Chapter, VIT-AP University"
    → ("Marketing Lead", "Microsoft Student Chapter, VIT-AP University", "2024 – 2025")."""
    match = _RANGE.search(heading)
    if not match:
        return heading.strip(), "", ""
    title = heading[: match.start()].strip(" ,|")
    org = re.split(r"\s?Under\s+(?:Dr|Prof)\b|\s\|\s", heading[match.end() :], maxsplit=1)[0].strip(" ,|")
    return title or heading.strip(), org, match.group(0).strip()


def parse_education(text: str) -> list[EducationEntry]:
    """Splits an education blob into one entry per school at each date range."""
    entries: list[EducationEntry] = []
    start = 0
    for match in _REAL_RANGE.finditer(text):
        piece = text[start : match.start()].strip(" |,;")
        start = match.end()
        details = ""
        expected = re.search(r"\|?\s*(Expected\s+(?:19|20)\d{2})\s*$", piece, re.I)
        if expected:
            details, piece = expected.group(1), piece[: expected.start()].strip(" |,")
        degree_match = _DEGREE.search(piece)
        institution = piece[: degree_match.start()].strip(" ,|") if degree_match else piece
        degree = piece[degree_match.start() :].strip(" ,|") if degree_match else ""
        if institution or degree:
            entries.append(EducationEntry(
                institution=(institution or degree)[:120], degree=degree[:120] if institution else "",
                dates=match.group(0).strip(), details=details,
            ))
    return entries


def deduplicate(chunks: list[RetrievedChunk]) -> list[RetrievedChunk]:
    """Drops chunks nearly identical to a better-ranked one (input is ranked)."""
    kept: list[RetrievedChunk] = []
    for chunk in chunks:
        if not any(_similar(chunk.text, other.text) for other in kept):
            kept.append(chunk)
    return kept


def _entry_key(section: str, heading: str) -> str:
    # Projects are identified by their name ("LeafScan – …" → "leafscan"), so
    # two resume versions describing the same project merge into one entry.
    if section == "Projects":
        return section + ":" + _norm(parse_project(heading)[0])
    return section + ":" + " ".join(_norm(heading).split()[:8])


def gather(jd_text: str, budget_words: int) -> Evidence:
    ranked = deduplicate(database.search(jd_text, n_results=10_000))
    profile = database.profile_text()

    entries: dict[str, Entry] = {}
    for chunk in ranked:
        section, heading, bullet = _split(chunk.text)
        key = _entry_key(section, heading)
        entry = entries.setdefault(key, Entry(section, heading, score=chunk.score))
        entry.score = max(entry.score, chunk.score)
        if len(heading) > len(entry.heading):
            entry.heading = heading  # keep the most descriptive version
        if bullet and not any(_similar(bullet, existing) for existing in entry.bullets):
            entry.bullets.append(bullet)

    education: list[EducationEntry] = []
    for entry in entries.values():
        if entry.section == "Projects":
            entry.name, entry.subtitle, entry.tech, entry.dates = parse_project(entry.heading)
        elif entry.section in ("Experience", "Leadership"):
            entry.name, entry.subtitle, entry.dates = parse_role(entry.heading)
        elif entry.section == "Education":
            education += parse_education(entry.heading)

    def cost(entry: Entry) -> int:
        return len(entry.heading.split()) + sum(len(b.split()) for b in entry.bullets)

    chosen = [e for e in entries.values() if e.section in _ALWAYS]
    used = sum(cost(e) for e in chosen)
    for entry in sorted((e for e in entries.values() if e.section not in _ALWAYS), key=lambda e: -e.score):
        if used + cost(entry) > budget_words and chosen:
            # Out of room for the whole entry: keep its best bullet so the
            # model still knows it exists.
            entry.bullets = entry.bullets[:1]
            if used + cost(entry) > budget_words:
                continue
        chosen.append(entry)
        used += cost(entry)

    lines: list[str] = []
    for section in _SECTION_ORDER:
        section_entries = sorted((e for e in chosen if e.section == section), key=lambda e: -e.score)
        if not section_entries:
            continue
        lines.append(f"## {section.upper()}" + (" (most relevant to the job first)" if section in ("Experience", "Projects") else ""))
        if section == "Education" and education:
            lines += [f"* SCHOOL: {e.institution} | DEGREE: {e.degree} | DATES: {e.dates}" + (f" | NOTE: {e.details}" if e.details else "") for e in education]
        else:
            for entry in section_entries:
                if section == "Projects":
                    lines.append(f"* PROJECT: {entry.name} | WHAT: {entry.subtitle} | TECH: {', '.join(entry.tech)} | DATES: {entry.dates}")
                elif section in ("Experience", "Leadership"):
                    lines.append(f"* ROLE: {entry.name} | ORGANIZATION: {entry.subtitle} | DATES: {entry.dates}")
                else:
                    lines.append(f"* {entry.heading}")
                lines.extend(f"  - {bullet}" for bullet in entry.bullets)
        lines.append("")
    return Evidence(
        text="\n".join(lines).strip(), profile=profile, chunks=ranked,
        entries=chosen, education=education,
    )


def _looks_like_dates(text: str) -> bool:
    return not text or _RANGE.fullmatch(text.strip()) is not None or len(text) <= 20


def _match(title: str, candidates: list[Entry]) -> Entry | None:
    words = _words(title)
    best, best_score = None, 0.0
    for entry in candidates:
        other = _words(entry.name or entry.heading)
        if words and other:
            score = len(words & other) / min(len(words), len(other))
            if score > best_score:
                best, best_score = entry, score
    return best if best_score >= 0.5 else None


def complete(content: ResumeContent, evidence: Evidence, min_projects: int = 4) -> ResumeContent:
    """Fills what the model skipped and repairs fields it mangled, using only
    parsed evidence (so nothing is invented)."""
    projects = sorted((e for e in evidence.entries if e.section == "Projects"), key=lambda e: -e.score)
    for project in content.projects:
        source = _match(project.name.split(" – ")[0], projects)
        if not source:
            continue
        project.name = source.name[:120]
        project.tech = project.tech or source.tech[:8]
        if not _looks_like_dates(project.dates) or not project.dates:
            project.dates = source.dates
        project.bullets = project.bullets or source.bullets[:3]
    have = {_norm(p.name) for p in content.projects}
    for source in projects:
        if len(content.projects) >= min(min_projects, 5):
            break
        if _norm(source.name) not in have:
            content.projects.append(ProjectEntry(name=source.name[:120], tech=source.tech[:8], dates=source.dates, bullets=source.bullets[:3]))

    for section, entries in (("Experience", content.experience), ("Leadership", content.leadership)):
        sources = [e for e in evidence.entries if e.section == section]
        matched = set()
        for role in entries:
            source = _match(role.title, sources)
            if not source:
                continue
            matched.add(id(source))
            role.organization = role.organization or source.subtitle[:120]
            if not role.dates or not _looks_like_dates(role.dates):
                role.dates = source.dates
            role.bullets = role.bullets or source.bullets[:3]
        limit = 4 if section == "Experience" else 3
        for source in sorted(sources, key=lambda e: -e.score):
            if id(source) not in matched and len(entries) < limit:
                entries.append(ExperienceEntry(title=source.name[:120], organization=source.subtitle[:120],
                                               dates=source.dates, bullets=source.bullets[:3]))

    if not content.skills:
        content.skills = skills_fallback(evidence)
    content.summary = resume_voice(content.summary)
    # Education is facts, not prose: the parsed version is more reliable.
    if evidence.education:
        content.education = evidence.education[:3]
    return content


def skills_fallback(evidence: Evidence) -> list[SkillGroup]:
    """Flat skill list straight from the evidence, for when a model returns
    none. "Languages:Python, Go AI/ML:PyTorch" → Python, Go AI/ML… is
    ambiguous once flattened, so labels are dropped: only the text after
    each ":" and between commas is kept.
    ponytail: loses group labels; the model's own grouping is used whenever
    it produces one."""
    items: list[str] = []
    for entry in evidence.entries:
        if entry.section != "Skills":
            continue
        for part in re.split(r",(?![^()]*\))", entry.heading):
            value = part.rsplit(":", 1)[-1].strip(" .;")
            if 1 < len(value) <= 40 and value.lower() not in {i.lower() for i in items}:
                items.append(value)
    return [SkillGroup(category="Technical Skills" if i == 0 else "More", items=items[i : i + 14])
            for i in range(0, min(len(items), 28), 14)]


def resume_voice(text: str) -> str:
    """Strips first-person phrasing small models slip into despite the prompt
    ("…, I have built X" → "…; built X").
    ponytail: phrase-level regex, not a grammar rewrite — covers the common
    "I have / I am / my" constructions, not every sentence shape."""
    text = re.sub(r",?\s*\b(?:I have|I've|I am|I'm|I)\s+(?:successfully\s+)?", "; ", text)
    text = re.sub(r"\b[Mm]y\s+", "", text)
    text = re.sub(r"\s+me\b", "", text)
    text = re.sub(r"^[;,\s]+", "", text)
    text = re.sub(r"\s+(?=[;,.])", "", text)
    text = re.sub(r"\.\s*;\s*", ". ", text)
    text = re.sub(r"([.!?]\s+)([a-z])", lambda m: m.group(1) + m.group(2).upper(), text)
    return text[:1].upper() + text[1:] if text else text


_EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")
_PHONE = re.compile(r"(?<!\w)\+?\d[\d\s().-]{7,}\d(?!\w)")
_URL = re.compile(r"(?:https?://)?(?:www\.)?((?:linkedin\.com|github\.com|gitlab\.com|[\w-]+\.(?:dev|io|me|com|in|org))/?[\w\-./#?=%]*)", re.I)


def contact_from_profile(profile: str) -> tuple[str, list[tuple[str, str | None]]]:
    """Name and contact items (display text, link or None) parsed straight
    from the profile chunk — never left to the LLM, which can mangle them."""
    if not profile:
        return "", []
    first = re.split(r"[\d|@+]|https?://", profile, maxsplit=1)[0]
    name = " ".join(first.split()[:4]).strip(" ,|")

    parts: list[tuple[str, str | None]] = []
    for email in _EMAIL.findall(profile)[:1]:
        parts.append((email, f"mailto:{email}"))
    stripped = _EMAIL.sub(" ", profile)
    for phone in _PHONE.findall(stripped)[:1]:
        parts.append((phone.strip(), None))
    seen = set()
    for match in _URL.finditer(stripped):
        url = match.group(1).rstrip("/.,|")
        host = url.split("/")[0].lower()
        if host in seen or ("/" not in url and host.count(".") < 1):
            continue
        seen.add(host)
        parts.append((url, "https://" + url))
    return name, parts
