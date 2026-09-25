"""On-device inference: GGUF model catalog, resumable background downloads
(HTTP Range + SHA256 verification), and llama.cpp generation constrained to
a Pydantic JSON schema so local output is exactly as structured as Gemini's.
"""

import atexit
import hashlib
import importlib.util
import logging
import os
import platform
import shutil
import subprocess
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import TypeVar

import httpx
from pydantic import BaseModel

logger = logging.getLogger(__name__)

from paths import DATA_DIR

MODELS_DIR = Path(os.environ.get("CLUTCH_MODELS_DIR", DATA_DIR / "models"))


@dataclass(frozen=True)
class ModelSpec:
    id: str
    name: str
    description: str
    repo: str
    filename: str
    size_bytes: int
    sha256: str  # pinned from Hugging Face's X-Linked-ETag (the LFS sha256)
    min_memory_gb: int  # below this it won't load comfortably (weights + 8k context)
    recommended_memory_gb: int  # at/above this it runs well alongside other apps
    chat_format: str | None = None  # None = use the chat template embedded in the GGUF

    @property
    def url(self) -> str:
        return f"https://huggingface.co/{self.repo}/resolve/main/{self.filename}"

    @property
    def path(self) -> Path:
        return MODELS_DIR / self.filename

    @property
    def partial_path(self) -> Path:
        return MODELS_DIR / f"{self.filename}.part"


# Best first — recommend() picks the first model that fits this Mac.
CATALOG: dict[str, ModelSpec] = {
    spec.id: spec
    for spec in (
        ModelSpec(
            id="ornith-1.5-9b-q4km",
            name="Ornith 1.5 9B",
            description="Strongest writer here (Qwen 3.5 based, MIT). Needs a 16 GB Mac.",
            repo="ornith-ai/Ornith-1.5-9B-GGUF",
            filename="Ornith-1.5-9B-Q4_K_M.gguf",
            size_bytes=5_780_090_816,
            sha256="70c112196e0b7023803c9762752e46d29e612a92c83f995bc3ba1ceb07e8fab6",
            min_memory_gb=12,
            recommended_memory_gb=16,
            chat_format="chatml",
        ),
        ModelSpec(
            id="ornith-1.5-9b-iq3m",
            name="Ornith 1.5 9B · 8 GB edition",
            description="The same 9B model, compressed (IQ3_M) to fit 8 GB MacBook Airs.",
            repo="bartowski/Ornith-1.5-9B-GGUF",
            filename="Ornith-1.5-9B-IQ3_M.gguf",
            size_bytes=4_722_533_248,
            sha256="23efb400479854570b7bc286eef3a205ee309332af92acaf8f6c877f1ce7dc5c",
            min_memory_gb=8,
            recommended_memory_gb=8,
            chat_format="chatml",
        ),
        ModelSpec(
            id="qwen3-4b-instruct-2507-q4km",
            name="Qwen3 4B Instruct 2507",
            description="Small, fast and much sharper than Qwen 2.5 at structured writing.",
            repo="bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF",
            filename="Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
            size_bytes=2_497_280_736,
            sha256="2fde00ce69dd4899c70d020845e2638353015bba0fdf161b3eb965f2bca4464e",
            min_memory_gb=6,
            recommended_memory_gb=8,
            chat_format="chatml",
        ),
        ModelSpec(
            id="gemma-3-4b-it-q4km",
            name="Gemma 3 4B",
            description="Google's small model — fluent, natural phrasing.",
            repo="bartowski/google_gemma-3-4b-it-GGUF",
            filename="google_gemma-3-4b-it-Q4_K_M.gguf",
            size_bytes=2_489_758_112,
            sha256="4996030242583a40aa151ff93f49ed787ac8c25e4120c3ae4588b2e2a7d1ae94",
            min_memory_gb=6,
            recommended_memory_gb=8,
        ),
        ModelSpec(
            id="phi-4-mini-instruct-q4km",
            name="Phi-4 mini",
            description="Microsoft's compact reasoning model.",
            repo="bartowski/microsoft_Phi-4-mini-instruct-GGUF",
            filename="microsoft_Phi-4-mini-instruct-Q4_K_M.gguf",
            size_bytes=2_491_874_688,
            sha256="01999f17c39cc3074afae5e9c539bc82d45f2dd7faa3917c66cbef76fce8c0c2",
            min_memory_gb=6,
            recommended_memory_gb=8,
        ),
        ModelSpec(
            id="qwen2.5-7b-instruct-q4km",
            name="Qwen 2.5 7B Instruct",
            description="Previous-generation 7B. Solid, but Ornith is stronger.",
            repo="bartowski/Qwen2.5-7B-Instruct-GGUF",
            filename="Qwen2.5-7B-Instruct-Q4_K_M.gguf",
            size_bytes=4_683_074_240,
            sha256="65b8fcd92af6b4fefa935c625d1ac27ea29dcb6ee14589c55a8f115ceaaa1423",
            min_memory_gb=12,
            recommended_memory_gb=16,
            chat_format="chatml",
        ),
        ModelSpec(
            id="llama3.1-8b-instruct-q4km",
            name="Llama 3.1 8B Instruct",
            description="Previous-generation 8B general writer.",
            repo="bartowski/Meta-Llama-3.1-8B-Instruct-GGUF",
            filename="Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf",
            size_bytes=4_920_739_232,
            sha256="7b064f5842bf9532c91456deda288a1b672397a54fa729aa665952863033557c",
            min_memory_gb=12,
            recommended_memory_gb=16,
        ),
        ModelSpec(
            id="llama3.2-3b-instruct-q4km",
            name="Llama 3.2 3B Instruct",
            description="Lightweight Meta model for tight memory.",
            repo="bartowski/Llama-3.2-3B-Instruct-GGUF",
            filename="Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            size_bytes=2_019_377_696,
            sha256="6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff",
            min_memory_gb=4,
            recommended_memory_gb=8,
        ),
        ModelSpec(
            id="qwen2.5-3b-instruct-q4km",
            name="Qwen 2.5 3B Instruct",
            description="Older and weakest here — only if nothing else fits.",
            repo="bartowski/Qwen2.5-3B-Instruct-GGUF",
            filename="Qwen2.5-3B-Instruct-Q4_K_M.gguf",
            size_bytes=1_929_903_264,
            sha256="9c9f56a391a3abbd5b89d0245bf6106081bcc3173119d4229235dd9d23253f94",
            min_memory_gb=6,
            recommended_memory_gb=8,
            chat_format="chatml",
        ),
    )
}


class DownloadCancelled(Exception):
    pass


class _Downloads:
    """Tracks the single in-flight download. One at a time keeps disk and
    bandwidth usage predictable for multi-GB files."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.active_id: str | None = None
        self.phase = "idle"  # idle | downloading | verifying
        self.downloaded = 0
        self.errors: dict[str, str] = {}
        self.cancel_event = threading.Event()


_downloads = _Downloads()


@dataclass(frozen=True)
class Device:
    chip: str
    memory_gb: float
    free_disk_bytes: int
    apple_silicon: bool


def device_specs() -> Device:
    try:
        chip = subprocess.run(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True, timeout=2).stdout.strip()
    except Exception:
        chip = ""
    memory = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    probe = MODELS_DIR
    while not probe.exists():  # models dir may not exist until first download
        probe = probe.parent
    return Device(
        chip=chip or platform.processor() or "Unknown chip",
        memory_gb=round(memory / 1024**3, 1),
        free_disk_bytes=shutil.disk_usage(probe).free,
        apple_silicon=platform.machine() == "arm64",
    )


def assess(spec: ModelSpec, device: Device, downloaded_bytes: int = 0, is_ready: bool = False) -> tuple[str, str]:
    """(fit, note) for running `spec` on `device`. fit is one of
    good | tight | too_big | no_disk."""
    if not is_ready:
        needed = spec.size_bytes - downloaded_bytes + (1 << 30)  # plus 1 GB headroom
        if device.free_disk_bytes < needed:
            return "no_disk", (
                f"Needs {needed / 1e9:.1f} GB free disk space — only {device.free_disk_bytes / 1e9:.1f} GB available."
            )
    if device.memory_gb < spec.min_memory_gb:
        return "too_big", f"Needs at least {spec.min_memory_gb} GB memory; this Mac has {device.memory_gb:g} GB."
    if not device.apple_silicon:
        return "tight", "Intel Mac: runs on the CPU without Metal, so generation will be slow."
    if device.memory_gb < spec.recommended_memory_gb:
        return "tight", f"Will run, but {device.memory_gb:g} GB memory is tight — close other apps while generating."
    return "good", f"Runs well on this Mac ({device.memory_gb:g} GB memory)."


def recommend(fits: dict[str, str]) -> str | None:
    """Best-quality model (catalog order) that fits well, else one that at
    least runs, else None."""
    for wanted in ("good", "tight"):
        for model_id, fit in fits.items():
            if fit == wanted:
                return model_id
    return None


def runtime_available() -> bool:
    return importlib.util.find_spec("llama_cpp") is not None


def _partial_bytes(spec: ModelSpec) -> int:
    return spec.partial_path.stat().st_size if spec.partial_path.exists() else 0


def status() -> dict:
    device = device_specs()
    with _downloads.lock:
        models = []
        for spec in CATALOG.values():
            is_active = _downloads.active_id == spec.id
            if spec.path.exists():
                state = "ready"
            elif is_active:
                state = _downloads.phase
            elif spec.id in _downloads.errors:
                state = "failed"
            elif spec.partial_path.exists():
                state = "paused"
            else:
                state = "not_downloaded"
            downloaded = _downloads.downloaded if is_active else (spec.size_bytes if state == "ready" else _partial_bytes(spec))
            fit, fit_note = assess(spec, device, downloaded, is_ready=state == "ready")
            models.append({
                "fit": fit,
                "fit_note": fit_note,
                "id": spec.id,
                "name": spec.name,
                "description": spec.description,
                "filename": spec.filename,
                "size_bytes": spec.size_bytes,
                "downloaded_bytes": downloaded,
                "state": state,
                "error": _downloads.errors.get(spec.id),
            })
        return {
            "runtime_available": runtime_available(),
            "models_dir": str(MODELS_DIR),
            "models": models,
            "recommended_id": recommend({m["id"]: m["fit"] for m in models}),
            "device": {
                "chip": device.chip,
                "memory_gb": device.memory_gb,
                "free_disk_bytes": device.free_disk_bytes,
                "apple_silicon": device.apple_silicon,
            },
        }


def start_download(model_id: str) -> None:
    spec = CATALOG.get(model_id)
    if spec is None:
        raise KeyError(model_id)
    if spec.path.exists():
        return
    fit, note = assess(spec, device_specs(), _partial_bytes(spec))
    if fit == "no_disk":
        raise RuntimeError(note)
    with _downloads.lock:
        if _downloads.active_id is not None:
            raise RuntimeError("Another model is already downloading.")
        _downloads.active_id = spec.id
        _downloads.phase = "downloading"
        _downloads.downloaded = _partial_bytes(spec)
        _downloads.errors.pop(spec.id, None)
        _downloads.cancel_event.clear()
    threading.Thread(target=_download_worker, args=(spec,), daemon=True).start()


def cancel_download() -> None:
    """Pauses the active download — the .part file is kept so the next
    start_download resumes from the same byte via a Range request."""
    _downloads.cancel_event.set()


def delete_model(model_id: str) -> None:
    spec = CATALOG.get(model_id)
    if spec is None:
        raise KeyError(model_id)
    with _downloads.lock:
        if _downloads.active_id == spec.id:
            raise RuntimeError("Pause the download before deleting it.")
        _downloads.errors.pop(spec.id, None)
    _unload_if(spec.path)
    spec.path.unlink(missing_ok=True)
    spec.partial_path.unlink(missing_ok=True)


def _download_worker(spec: ModelSpec) -> None:
    try:
        MODELS_DIR.mkdir(parents=True, exist_ok=True)
        _fetch(spec)
        with _downloads.lock:
            _downloads.phase = "verifying"
        if _sha256(spec.partial_path) != spec.sha256:
            spec.partial_path.unlink(missing_ok=True)
            raise ValueError("Checksum mismatch — the download was corrupted and has been discarded. Try again.")
        spec.partial_path.rename(spec.path)
    except DownloadCancelled:
        pass
    except Exception as exc:
        logger.exception("Model download failed: %s", spec.id)
        with _downloads.lock:
            _downloads.errors[spec.id] = str(exc)
    finally:
        with _downloads.lock:
            _downloads.active_id = None
            _downloads.phase = "idle"
            _downloads.downloaded = 0


def _fetch(spec: ModelSpec) -> None:
    offset = _partial_bytes(spec)
    if offset >= spec.size_bytes:
        return
    headers = {"Range": f"bytes={offset}-"} if offset else {}
    timeout = httpx.Timeout(30.0, read=60.0)
    with httpx.stream("GET", spec.url, headers=headers, follow_redirects=True, timeout=timeout) as response:
        response.raise_for_status()
        if offset and response.status_code != 206:
            offset = 0  # server ignored the Range header — restart cleanly
        with open(spec.partial_path, "ab" if offset else "wb") as file:
            downloaded = offset
            for chunk in response.iter_bytes(chunk_size=1 << 20):
                if _downloads.cancel_event.is_set():
                    raise DownloadCancelled
                file.write(chunk)
                downloaded += len(chunk)
                with _downloads.lock:
                    _downloads.downloaded = downloaded


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        while block := file.read(8 << 20):
            digest.update(block)
    return digest.hexdigest()


# ---------------------------------------------------------------- inference

T = TypeVar("T", bound=BaseModel)

_llm_lock = threading.Lock()
_loaded: tuple[Path, object] | None = None


def ready_model_id(preferred: str | None = None) -> str | None:
    if preferred and preferred in CATALOG and CATALOG[preferred].path.exists():
        return preferred
    return next((spec.id for spec in CATALOG.values() if spec.path.exists()), None)


def _unload_if(path: Path) -> None:
    global _loaded
    with _llm_lock:
        if _loaded and _loaded[0] == path:
            _loaded = None


class LocalModelError(RuntimeError):
    """A user-facing local-inference failure (message is shown as-is)."""


_N_CTX = 8192
# Live progress of the current local generation, polled by the app.
progress = {"active": False, "tokens": 0, "max_tokens": 0, "model": ""}


def _close_model() -> None:
    """Frees the model before interpreter teardown — letting Llama.__del__
    run during shutdown trips a Metal assertion in llama.cpp."""
    global _loaded
    if _loaded is not None:
        try:
            _loaded[1].close()
        except Exception:
            pass
        _loaded = None


atexit.register(_close_model)


def _load(path: Path, spec: ModelSpec):
    global _loaded
    if _loaded is None or _loaded[0] != path:
        from llama_cpp import Llama

        _loaded = None  # free the previous model before loading the next
        _loaded = (path, Llama(
            model_path=str(path),
            n_ctx=_N_CTX,
            n_gpu_layers=-1,
            n_batch=512,
            flash_attn=True,
            chat_format=spec.chat_format,
            verbose=False,
        ))
    return _loaded[1]


def generate_structured(model_id: str | None, system: str, user: str, schema: type[T], max_tokens: int = 2300) -> T:
    if not runtime_available():
        raise LocalModelError("The llama.cpp runtime isn't installed. Run backend/setup_backend.sh.")
    resolved = ready_model_id(model_id)
    if resolved is None:
        raise LocalModelError("No local model is downloaded yet. Download one in Engine Selector.")
    spec = CATALOG[resolved]

    # ponytail: one global lock serializes local generations — a laptop
    # only fits one model in memory anyway.
    with _llm_lock:
        try:
            llm = _load(spec.path, spec)
        except Exception as exc:
            raise LocalModelError(f"Couldn't load {spec.name}: {exc}. The Mac may be short on memory — close other apps or pick a smaller model.") from exc

        prompt_tokens = len(llm.tokenize((system + "\n" + user).encode(), add_bos=True)) + 64
        room = _N_CTX - prompt_tokens
        if room < 900:
            raise LocalModelError(
                f"The job description and evidence are too long for {spec.name}'s {_N_CTX}-token window. Shorten the JD and try again."
            )
        budget = min(max_tokens, room)

        progress.update(active=True, tokens=0, max_tokens=budget, model=spec.name)
        pieces: list[str] = []
        finish_reason = None
        try:
            for part in llm.create_chat_completion(
                messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
                response_format={"type": "json_object", "schema": schema.model_json_schema()},
                temperature=0.3,
                repeat_penalty=1.08,
                max_tokens=budget,
                stream=True,
            ):
                choice = part["choices"][0]
                pieces.append(choice["delta"].get("content") or "")
                progress["tokens"] += 1
                finish_reason = choice.get("finish_reason") or finish_reason
        finally:
            progress["active"] = False

    text = "".join(pieces)
    try:
        return schema.model_validate_json(text)
    except Exception as exc:
        if finish_reason == "length":
            raise LocalModelError(
                f"{spec.name} ran out of room before finishing ({budget} tokens). Try again, shorten your notes, or use a larger model."
            ) from exc
        raise LocalModelError(f"{spec.name} returned malformed output. Try again or switch models.") from exc
