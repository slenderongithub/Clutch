"""Self-check: every template renders every section and compiles with
pdflatex. Run `python test_templates.py` (needs MacTeX)."""

from pathlib import Path

import latex
from models import EducationEntry, ExperienceEntry, ProjectEntry, ResumeContent, SkillGroup

SAMPLE = ResumeContent(
    full_name="Jane Doe",
    headline="AI & Data Engineer — Analyst",
    summary="Engineer who ships ML systems end to end; cut p99 latency 40% → 12 ms & owns CI/CD ≥ 99.9% uptime 🚀.",
    education=[EducationEntry(institution="State University", degree="B.S. Computer Science", dates="2020 – 2024",
                              location="Austin, TX", details="GPA 3.9/4.0 · Dean's list")],
    experience=[ExperienceEntry(title="Research Intern, Very Long Title About Federated Learning Systems at Scale",
                                organization="Acme Labs", dates="May 2023 – Aug 2023", location="Remote",
                                bullets=["Built a C# & C++ pipeline handling 10k req/s with 99.9% uptime",
                                         "Cut costs by $2,000/month using spot instances_and caching #infra"])],
    projects=[ProjectEntry(name="LeafScan", tech=["Python", "PyTorch", "Docker"], dates="2025",
                           bullets=["Trained a ResNet-50 reaching 0.761 Macro-F1", "Served a REST API ~50 ms p95"]),
              ProjectEntry(name="Orbit", tech=[], dates="", bullets=[])],
    skills=[SkillGroup(category="Languages", items=["Python", "Go", "C/C++"]), SkillGroup(category="AI/ML", items=["PyTorch", "SBERT"])],
    leadership=[ExperienceEntry(title="Vice President", organization="Robotics Club", dates="2024", bullets=["Grew membership to 40+"])],
    certifications=["AWS Cloud Practitioner"],
    achievements=["Winner, Hack@State 2023"],
)
CONTACT = [("jane@example.com", "mailto:jane@example.com"), ("+1 555 0100", None), ("github.com/jane", "https://github.com/jane")]


def demo():
    templates = sorted(p.name.removesuffix(".tex.jinja") for p in Path("templates").glob("[!_]*.tex.jinja"))
    assert len(templates) == 6, templates
    for template in templates:
        tex = latex.render_resume_tex(template, SAMPLE, CONTACT)
        for must in ("Projects", "LeafScan", "Leadership", "Vice President", "AWS Cloud Practitioner",
                     "Winner, Hack@State", "State University", r"\href{https://github.com/jane}", "Languages"):
            assert must in tex, f"{template}: missing {must!r}"
        pdf = latex.compile_tex_to_pdf(tex)  # raises with the pdflatex log on failure
        assert Path(pdf).stat().st_size > 5_000, template
        print(f"  {template}: ok")
    print("template self-check passed")


if __name__ == "__main__":
    demo()
