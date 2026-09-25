import io
import re
from pathlib import Path

from pypdf import PdfReader


def extract_text(filename: str, content: bytes) -> str:
    """Extracts plain text from an uploaded career-history document."""
    suffix = Path(filename).suffix.lower()

    if suffix == ".pdf":
        return _extract_pdf_text(content)
    if suffix in (".txt", ".md"):
        return content.decode("utf-8", errors="ignore")
    raise ValueError(f"Unsupported file type: {suffix or '(none)'}. Use .pdf, .txt, or .md.")


def _extract_pdf_text(content: bytes) -> str:
    reader = PdfReader(io.BytesIO(content))
    pages: list[str] = []
    for page in reader.pages:
        # A single corrupt or scanned (image-only) page shouldn't take
        # down ingestion of the rest of the document — pypdf can't OCR,
        # so a page like that just contributes no text.
        try:
            text = page.extract_text() or ""
        except Exception:
            text = ""
        text = clean_extracted(_strip_page_number_artifacts(text.strip()))
        if text:
            pages.append(text)
    return "\n\n".join(pages)


# pypdf splits kerned capitals off their word ("V ellore", "T echnology")
# and glues text across bold/regular runs ("Achieved88.36%", "driving30%growth").
_KERNING_SPLIT = re.compile(r"\b([B-HJ-Z]) ([a-z]{2,})")  # never "A"/"I" — real words
_WORD_THEN_NUMBER = re.compile(r"(?<=[a-z]{3})(?=\d{2,})")  # "driving30" (not "YOLOv11"/"Python3")
_PERCENT_THEN_WORD = re.compile(r"(?<=%)(?=[A-Za-z])")
_YEAR_THEN_WORD = re.compile(r"(?<=\b(?:19|20)\d{2})(?=[A-Z][a-z])")  # "Expected 2027Sep 2023"


def clean_extracted(text: str) -> str:
    text = _KERNING_SPLIT.sub(r"\1\2", text)
    text = _WORD_THEN_NUMBER.sub(" ", text)
    text = _YEAR_THEN_WORD.sub(" ", text)
    return _PERCENT_THEN_WORD.sub(" ", text)


def _strip_page_number_artifacts(text: str) -> str:
    """pypdf has no layout awareness, so a footer page number often gets
    captured as an ordinary leading/trailing token in the page's text —
    strip it when it's an isolated standalone digit."""
    words = text.split()
    if words and words[-1].isdigit():
        words = words[:-1]
    if words and words[0].isdigit():
        words = words[1:]
    return " ".join(words)


def chunk_text(text: str, max_words: int = 150, overlap_words: int = 20) -> list[str]:
    """Splits text into overlapping fixed-size word windows.

    PDF text extraction routinely loses real paragraph structure
    (multi-column resumes especially — blank lines get lost or
    scrambled), so chunking by word count rather than by detected
    paragraph breaks is the more robust choice: it doesn't depend on the
    extractor having preserved structure correctly. The overlap keeps a
    sentence or bullet from being severed exactly at a chunk boundary and
    losing its context.
    """
    words = text.split()
    if not words:
        return []

    chunks: list[str] = []
    step = max_words - overlap_words
    for start in range(0, len(words), step):
        chunk_words = words[start : start + max_words]
        if not chunk_words:
            break
        chunks.append(" ".join(chunk_words))
        if start + max_words >= len(words):
            break
    return chunks


# Resume/brag-doc section headers → retrieval category. Longest first so
# "Technical Skills" wins over "Skills" at the same spot.
_SECTIONS = {
    "Professional Experience": "experience", "Work Experience": "experience", "Experience": "experience",
    "Employment": "experience", "Leadership": "experience", "Volunteering": "experience",
    "Activities": "experience",
    "Selected Projects": "project", "Personal Projects": "project", "Projects": "project", "Publications": "project",
    "Technical Skills": "skill", "Skills": "skill", "Certifications": "skill",
    "Education": "education",
    "Achievements": "achievement", "Awards": "achievement", "Honors": "achievement",
    "Summary": "profile", "Profile": "profile", "About": "profile",
}
_HEADER_RE = re.compile(
    r"(?<![\w&])(" + "|".join(re.escape(h) for h in sorted(_SECTIONS, key=len, reverse=True)) + r")(?![\w])"
)
_BULLET_RE = re.compile(r"\s*[∙•▪●◦]\s*|\n\s*[-*]\s+")
# Entry headings that PDF extraction glues onto the end of the previous
# bullet: a project ("Name – description [stack]2026", single-token name)
# or a role ("Vice President 2025 Northeast Cultural Club").
_TRAILING_HEADING_RES = (
    re.compile(r"^(.*\S)\s+(\S+\s[–—]\s[^∙]{3,160}?(?:\]|\d{4}))\s*$"),
    re.compile(r"^(.*?\S)\s+((?:[A-Z]\S*\s){0,3}[A-Z]\S*\s\d{4}(?:\s[–—-]\s(?:\d{4}|Present))?\s[A-Z][^∙]{3,80})$"),
)


def chunk_sections(text: str, max_words: int = 110) -> list[tuple[str, str]]:
    """Splits a resume-like document into (category, chunk) pairs: one chunk
    per bullet / skill group, tagged with the section it came from and
    prefixed with its entry heading (project or role) for context.

    Works on whitespace-flattened text, since PDF extraction usually loses
    line structure. Falls back to plain word windows (category
    "experience") when no section headers are found.
    """
    flat = " ".join(text.split())
    matches, taken = [], set()
    for match in _HEADER_RE.finditer(flat):
        category = _SECTIONS[match.group(1)]
        if match.group(1) in taken:
            continue  # only a header's first occurrence starts a section
        taken.add(match.group(1))
        matches.append(match)
    if not matches:
        return [("experience", chunk) for chunk in chunk_text(text)]

    chunks: list[tuple[str, str]] = []
    preamble = flat[: matches[0].start()].strip()
    if preamble:
        chunks.append(("profile", preamble))

    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(flat)
        header = match.group(1)
        category = _SECTIONS[header]
        body = flat[match.end() : end].strip()
        if not body:
            continue
        for item in _section_items(body, category):
            for piece in _cap_words(item, max_words):
                chunks.append((category, f"{header}: {piece}"))
    return chunks


def _section_items(body: str, category: str) -> list[str]:
    if category in ("skill", "education"):
        return [body]  # short, list-like sections retrieve best whole
    parts = [part.strip() for part in _BULLET_RE.split(body) if part.strip()]
    if len(parts) <= 1:
        return parts
    items: list[str] = []
    heading = parts[0]
    for part in parts[1:]:
        trailing = next((m for m in (r.match(part) for r in _TRAILING_HEADING_RES) if m), None)
        bullet, next_heading = (trailing.group(1), trailing.group(2)) if trailing else (part, None)
        items.append(f"{heading} — {bullet}")
        if next_heading:
            heading = next_heading
    return items


def _cap_words(text: str, max_words: int) -> list[str]:
    words = text.split()
    return [" ".join(words[i : i + max_words]) for i in range(0, len(words), max_words)] or []
