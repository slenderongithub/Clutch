"""Self-check for evidence parsing and the completeness pass: `python test_rag.py`."""

import rag
from models import ExperienceEntry, ProjectEntry, ResumeContent


def demo():
    assert rag.parse_project("amux – Coding CLI|Go, TypeScript (Bun), SQLite2026") == ("amux", "Coding CLI", ["Go", "TypeScript (Bun)", "SQLite"], "2026")
    assert rag.parse_project("Lumen – Photo Search[Python, CLIP]2024") == ("Lumen", "Photo Search", ["Python", "CLIP"], "2024")
    assert rag.parse_role("Marketing Lead 2024 – 2025 Microsoft Student Chapter, VIT-AP University") == (
        "Marketing Lead", "Microsoft Student Chapter, VIT-AP University", "2024 – 2025")
    assert rag.parse_role("Intern, Lab 2026 Forensics University (NFSU), CampusUnder Dr. Saha")[1] == "Forensics University (NFSU), Campus"
    schools = rag.parse_education("State University B.Tech in CSE|Expected 2027 Sep 2023 – Present City School CBSE Class XII 2019 – 2021")
    assert [(s.institution, s.degree, s.dates, s.details) for s in schools] == [
        ("State University", "B.Tech in CSE", "Sep 2023 – Present", "Expected 2027"),
        ("City School", "CBSE Class XII", "2019 – 2021", ""),
    ], schools

    # A small model returns one mangled project and forgets a role.
    entries = [
        rag.Entry("Projects", "", ["Built A"], 0.9, "Alpha", "Search", ["Rust"], "2025"),
        rag.Entry("Projects", "", ["Built B"], 0.8, "Beta", "Tool", ["Go"], "2024"),
        rag.Entry("Projects", "", ["Built C"], 0.7, "Gamma", "App", [], "2023"),
        rag.Entry("Experience", "", ["Did X"], 0.9, "Research Intern", "Acme Labs", [], "2026"),
        rag.Entry("Leadership", "", ["Led Y"], 0.5, "Vice President", "Chess Club", [], "2025"),
    ]
    evidence = rag.Evidence(text="", profile="", chunks=[], entries=entries)
    content = ResumeContent(
        full_name="X",
        projects=[ProjectEntry(name="Alpha – Search", tech=[], dates="", bullets=["Shipped A"])],
        leadership=[ExperienceEntry(title="Vice President", dates="2025 Chess Club, somewhere long")],
    )
    done = rag.complete(content, evidence)
    assert [p.name for p in done.projects] == ["Alpha", "Beta", "Gamma"], done.projects
    assert done.projects[0].tech == ["Rust"] and done.projects[0].dates == "2025"
    assert done.projects[0].bullets == ["Shipped A"], "the model's tailored bullets are kept"
    assert [e.title for e in done.experience] == ["Research Intern"] and done.experience[0].organization == "Acme Labs"
    assert done.leadership[0].dates == "2025" and done.leadership[0].organization == "Chess Club"

    name, contact = rag.contact_from_profile("Jane Doe 555-010-0199|jane@x.com |linkedin.com/in/jane |github.com/jane")
    assert name == "Jane Doe" and [c[0] for c in contact] == ["jane@x.com", "555-010-0199", "linkedin.com/in/jane", "github.com/jane"], contact
    assert rag.resume_voice("Strong in AI, I have successfully built X. My work with Y shows my range.") == \
        "Strong in AI; built X. Work with Y shows range."
    assert rag.resume_voice("I built pipelines.") == "Built pipelines."
    assert rag.resume_voice("Engineer with experience in FL; built HawkEye.") == "Engineer with experience in FL; built HawkEye."
    skills = rag.Evidence(text="", profile="", chunks=[], entries=[
        rag.Entry("Skills", "Languages:Python, Java, C/C++, SQL, Go AI/ML & NLP:PyTorch, spaCy")])
    empty = rag.complete(ResumeContent(full_name="X"), skills)
    assert empty.skills and {"Python", "C/C++", "PyTorch", "spaCy"} <= set(empty.skills[0].items), empty.skills
    print("rag self-check passed")


if __name__ == "__main__":
    demo()
