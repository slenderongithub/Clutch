"""Self-check for resumable model downloads: run `python test_local_model.py`.
Serves a fake "model" from a local Range-capable HTTP server — nothing real
is downloaded."""

import hashlib
import http.server
import os
import tempfile
import threading
import time
from dataclasses import replace
from pathlib import Path

os.environ["CLUTCH_MODELS_DIR"] = tempfile.mkdtemp(prefix="clutch_models_test_")

import local_model  # noqa: E402  (must import after setting CLUTCH_MODELS_DIR)

PAYLOAD = os.urandom(3 * (1 << 20) + 123)
seen_ranges: list[str | None] = []


class RangeHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requested = self.headers.get("Range")
        seen_ranges.append(requested)
        start = int(requested.split("=")[1].rstrip("-")) if requested else 0
        body = PAYLOAD[start:]
        self.send_response(206 if requested else 200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def wait_idle():
    for _ in range(200):
        if local_model._downloads.active_id is None:
            return
        time.sleep(0.05)
    raise AssertionError("download never finished")


def demo():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), RangeHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"

    spec = replace(
        next(iter(local_model.CATALOG.values())),
        id="fake",
        filename="fake.gguf",
        size_bytes=len(PAYLOAD),
        sha256=hashlib.sha256(PAYLOAD).hexdigest(),
    )
    type(spec).url = property(lambda s: f"{base}/{s.filename}")  # point at the local server
    local_model.CATALOG = {"fake": spec}

    # Simulate a previous, interrupted download: the first 1 MiB is on disk.
    Path(local_model.MODELS_DIR).mkdir(parents=True, exist_ok=True)
    spec.partial_path.write_bytes(PAYLOAD[: 1 << 20])
    assert local_model.status()["models"][0]["state"] == "paused"

    local_model.start_download("fake")
    wait_idle()
    assert seen_ranges[-1] == f"bytes={1 << 20}-", seen_ranges
    assert spec.path.read_bytes() == PAYLOAD
    assert local_model.status()["models"][0]["state"] == "ready"

    # A corrupted download must be discarded, not marked ready.
    local_model.delete_model("fake")
    local_model.CATALOG = {"fake": replace(spec, sha256="0" * 64)}
    local_model.start_download("fake")
    wait_idle()
    model = local_model.status()["models"][0]
    assert model["state"] == "failed" and "Checksum" in model["error"], model
    assert not spec.path.exists() and not spec.partial_path.exists()

    server.shutdown()

    # Device fit: an 8 GB M2 with little disk space gets only the small model.
    catalog = {
        "big": replace(spec, id="big", size_bytes=4_700_000_000, min_memory_gb=12, recommended_memory_gb=16),
        "small": replace(spec, id="small", size_bytes=1_900_000_000, min_memory_gb=6, recommended_memory_gb=8),
    }
    m2_8gb_lowdisk = local_model.Device("Apple M2", 8.0, 4_500_000_000, True)
    fits = {k: local_model.assess(v, m2_8gb_lowdisk)[0] for k, v in catalog.items()}
    assert fits == {"big": "no_disk", "small": "good"}, fits
    assert local_model.recommend(fits) == "small"
    m3_32gb = local_model.Device("Apple M3 Max", 32.0, 500_000_000_000, True)
    fits = {k: local_model.assess(v, m3_32gb)[0] for k, v in catalog.items()}
    assert local_model.recommend(fits) == "big", fits
    m1_8gb = local_model.Device("Apple M1", 8.0, 500_000_000_000, True)
    assert local_model.assess(catalog["big"], m1_8gb)[0] == "too_big"
    intel = local_model.Device("Intel Core i7", 16.0, 500_000_000_000, False)
    assert local_model.assess(catalog["big"], intel)[0] == "tight"
    assert local_model.assess(catalog["big"], m2_8gb_lowdisk, is_ready=True)[0] == "too_big", "downloaded models skip the disk check"
    assert local_model.recommend({"big": "too_big", "small": "no_disk"}) is None

    print("local_model download self-check passed")


if __name__ == "__main__":
    demo()
