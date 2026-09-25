"""Where Clutch keeps user data. Never inside the app bundle: a shipped
Clutch.app is read-only and replaced wholesale on every update."""

import os
from pathlib import Path

DATA_DIR = Path(os.environ.get("CLUTCH_DATA_DIR", Path.home() / "Library" / "Application Support" / "Clutch"))
DATA_DIR.mkdir(parents=True, exist_ok=True)
