import subprocess
import tempfile
from pathlib import Path

import jinja2

from models import ResumeContent

TEMPLATES_DIR = Path(__file__).parent / "templates"

# LaTeX's own \, {, } collide with Jinja2's default {{ }}/{% %} delimiters,
# so the LaTeX-safe delimiters below are the standard workaround
# (documented in Jinja2's own docs for exactly this combination).
_latex_jinja_env = jinja2.Environment(
    block_start_string=r"\BLOCK{",
    block_end_string="}",
    variable_start_string=r"\VAR{",
    variable_end_string="}",
    comment_start_string=r"\#{",
    comment_end_string="}",
    trim_blocks=True,
    lstrip_blocks=True,
    autoescape=False,
    loader=jinja2.FileSystemLoader(str(TEMPLATES_DIR)),
)

# Single-pass character map: escaping this way (rather than chained
# .replace() calls) avoids re-escaping the backslash a .replace() for "\"
# would just have inserted for an earlier character.
_LATEX_ESCAPES = {
    "\\": r"\textbackslash{}",
    "&": r"\&",
    "%": r"\%",
    "$": r"\$",
    "#": r"\#",
    "_": r"\_",
    "{": r"\{",
    "}": r"\}",
    "~": r"\textasciitilde{}",
    "^": r"\textasciicircum{}",
}


# Typography models like to emit but pdflatex's utf8 inputenc can't typeset.
_UNICODE_FIXES = {
    "→": r"$\rightarrow$", "←": r"$\leftarrow$", "≥": r"$\geq$", "≤": r"$\leq$", "×": r"$\times$",
    "≈": r"$\approx$", "•": r"\textbullet{}", "∙": r"\textbullet{}", "·": r"\textperiodcentered{}",
    "…": r"\ldots{}", "\u00a0": " ", "\u200b": "",
}
# Latin-1 plus the dashes/quotes T1 fonts handle natively; anything else is dropped.
_SAFE_EXTRA = set("–—‘’“”€")


def escape_latex(text: str) -> str:
    out = []
    for char in str(text):
        if char in _LATEX_ESCAPES:
            out.append(_LATEX_ESCAPES[char])
        elif char in _UNICODE_FIXES:
            out.append(_UNICODE_FIXES[char])
        elif ord(char) < 256 or char in _SAFE_EXTRA:
            out.append(char)
    return "".join(out)


def contact_part(text: str, url: str | None) -> str:
    """One contact item, linked when it has a URL (hyperref needs % and # escaped)."""
    if not url:
        return escape_latex(text)
    safe_url = url.replace("\\", "").replace("%", r"\%").replace("#", r"\#").replace("{", "").replace("}", "")
    return rf"\href{{{safe_url}}}{{{escape_latex(text)}}}"


_latex_jinja_env.filters["latex_escape"] = escape_latex


_DEFAULT_TEMPLATE = "jakes_resume"


def render_resume_tex(template_id: str, content: ResumeContent, contact: list[tuple[str, str | None]] | None = None) -> str:
    template_name = f"{template_id}.tex.jinja"
    try:
        template = _latex_jinja_env.get_template(template_name)
    except jinja2.TemplateNotFound:
        template = _latex_jinja_env.get_template(f"{_DEFAULT_TEMPLATE}.tex.jinja")

    return template.render(
        **content.model_dump(),
        contact_parts=[contact_part(text, url) for text, url in (contact or [])],
    )


def compile_tex_to_pdf(tex_source: str) -> str:
    """Compiles tex_source with pdflatex and returns the absolute path to
    the resulting PDF.

    Uses tempfile.mkdtemp() rather than TemporaryDirectory() deliberately:
    the latter deletes its directory (PDF included) the moment this
    function returns, but the caller needs the PDF to still be on disk
    afterward so its path can be handed back to Swift. Every call gets its
    own fresh directory, so the fixed "resume.tex"/"resume.pdf" basenames
    inside it never collide across compiles.
    """
    workdir = Path(tempfile.mkdtemp(prefix="clutch_resume_"))
    tex_path = workdir / "resume.tex"
    tex_path.write_text(tex_source)

    try:
        for _ in range(2):  # a second pass resolves any cross-references
            result = subprocess.run(
                [
                    "pdflatex",
                    "-interaction=nonstopmode",
                    "-no-shell-escape",  # a .tex file must never run commands
                    "-halt-on-error",
                    "-output-directory",
                    str(workdir),
                    tex_path.name,
                ],
                cwd=workdir,
                capture_output=True,
                text=True,
                timeout=60,
            )
    except FileNotFoundError as exc:
        raise RuntimeError(
            "pdflatex is not installed or not on PATH. Install MacTeX and try again."
        ) from exc
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("pdflatex timed out while compiling.") from exc

    pdf_path = workdir / "resume.pdf"
    if not pdf_path.exists():
        log_path = workdir / "resume.log"
        log_tail = log_path.read_text(errors="ignore")[-2000:] if log_path.exists() else result.stdout[-2000:]
        raise RuntimeError(f"pdflatex failed to produce a PDF:\n{log_tail}")

    for junk_ext in (".aux", ".log", ".out"):
        (workdir / f"resume{junk_ext}").unlink(missing_ok=True)

    return str(pdf_path.resolve())


def page_count(pdf_path: str) -> int:
    from pypdf import PdfReader

    return len(PdfReader(pdf_path).pages)


# Density knobs injected before \begin{document}; they work on every
# template (all use titlesec + enumitem).
_COMPACT = [
    "",
    r"\linespread{0.96}\setlist{itemsep=0pt,topsep=1pt,parsep=0pt}\titlespacing*{\section}{0pt}{6pt}{3pt}",
    r"\linespread{0.93}\setlist{itemsep=0pt,topsep=0pt,parsep=0pt}\titlespacing*{\section}{0pt}{4pt}{2pt}"
    r"\addtolength{\textheight}{0.35in}\addtolength{\topmargin}{-0.2in}\AtBeginDocument{\small}",
    r"\linespread{0.9}\setlist{itemsep=0pt,topsep=0pt,parsep=0pt}\titlespacing*{\section}{0pt}{3pt}{1pt}"
    r"\addtolength{\textheight}{0.6in}\addtolength{\topmargin}{-0.35in}\AtBeginDocument{\fontsize{9}{10.6}\selectfont}",
]


def _with_density(tex: str, level: int) -> str:
    return tex.replace(r"\begin{document}", _COMPACT[level] + "\n\\begin{document}", 1) if level else tex


def fit_one_page(template_id: str, content: ResumeContent, contact: list[tuple[str, str | None]]) -> str:
    """Renders, compiles and counts pages. While it spills past one page it
    first tightens spacing, then trims the least relevant bullets, and only
    as a last resort drops a project (never below three). Content arrives
    ordered most relevant first."""
    trims = [
        lambda c: [setattr(p, "bullets", p.bullets[:2]) for p in c.projects],
        lambda c: [setattr(r, "bullets", r.bullets[:1]) for r in c.leadership],
        lambda c: [setattr(e, "bullets", e.bullets[:3]) for e in c.experience],
        lambda c: [setattr(p, "bullets", p.bullets[:1]) for p in c.projects[2:]],
        lambda c: setattr(c, "summary", c.summary.split(". ")[0].rstrip(".") + "." if c.summary else ""),
        lambda c: len(c.projects) > 3 and c.projects.pop(),
        lambda c: len(c.projects) > 3 and c.projects.pop(),
    ]
    content = content.model_copy(deep=True)
    steps = [(level, None) for level in range(len(_COMPACT))] + [(len(_COMPACT) - 1, trim) for trim in trims]
    tex = render_resume_tex(template_id, content, contact)
    for level, trim in steps:
        if trim:
            trim(content)
        tex = _with_density(render_resume_tex(template_id, content, contact), level)
        try:
            if page_count(compile_tex_to_pdf(tex)) <= 1:
                return tex
        except RuntimeError:
            return tex  # compile problems surface in the editor, with the log
    return tex
