"""Self-check for section-aware chunking: run `python test_parsing.py`."""

from parsing import chunk_sections

# Whitespace-flattened, the way pypdf hands a resume over.
RESUME = (
    "Jane Doe jane@example.com | github.com/jane "
    "Education State University B.S. Computer Science 2020 – 2024 "
    "Experience Software Intern 2023 Acme Corp ∙ Built a billing API in Go ∙ Cut p99 latency by 40% "
    "Projects Lumen – Photo Search[Python, CLIP]2024 ∙ Indexed 1M photos with CLIP embeddings "
    "∙ Shipped a React UI Orbit – Satellite Tracker[Rust]2023 ∙ Tracked 5k satellites in real time "
    "Leadership Treasurer 2022 – 2023 Robotics Club ∙ Managed a $20k budget Captain 2024 Chess Team ∙ Led the team to regionals "
    "Technical Skills Languages:Go, Python, Rust Tools:Docker, Git"
)


def demo():
    chunks = chunk_sections(RESUME)
    categories = [category for category, _ in chunks]

    assert chunks[0] == ("profile", "Jane Doe jane@example.com | github.com/jane"), chunks[0]
    assert categories.count("education") == 1
    assert categories.count("skill") == 1, "skills stay one chunk"

    # Every bullet carries the heading of the entry it belongs to — including
    # headings PDF extraction glued onto the end of the previous bullet.
    by_text = {text.split(" — ")[1]: text for category, text in chunks if " — " in text}
    assert by_text["Indexed 1M photos with CLIP embeddings"].startswith("Projects: Lumen")
    assert by_text["Shipped a React UI"].startswith("Projects: Lumen")
    assert by_text["Tracked 5k satellites in real time"].startswith("Projects: Orbit")
    assert by_text["Managed a $20k budget"].startswith("Leadership: Treasurer")
    assert by_text["Led the team to regionals"].startswith("Leadership: Captain 2024 Chess Team")
    assert all(category == "project" for category, text in chunks if text.startswith("Projects:"))
    assert all(category == "experience" for category, text in chunks if text.startswith(("Experience:", "Leadership:")))

    # No recognizable headers → plain word windows, nothing dropped.
    assert chunk_sections("just some notes about my work") == [("experience", "just some notes about my work")]
    from parsing import clean_extracted
    assert clean_extracted("V ellore Institute of T echnology") == "Vellore Institute of Technology"
    assert clean_extracted("Achieved88.36% peak, driving30%growth, F orensics2026") == "Achieved 88.36% peak, driving 30% growth, Forensics 2026"
    assert clean_extracted("A great YOLOv11 and Python3 model, I am") == "A great YOLOv11 and Python3 model, I am"
    print("section chunking self-check passed")


if __name__ == "__main__":
    demo()
