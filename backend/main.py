import os
import secrets
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

import database
from api import router

database.migrate_if_needed()

# Every API call must carry this token. The backend listens on localhost,
# but any web page open in the user's browser can still send it simple
# cross-site POSTs (a multipart form to /ingest could poison or wipe the
# career library). A custom header can't be sent cross-site without a CORS
# preflight — which this server never grants — and web pages can't read the
# token file, so they can't forge it.
TOKEN = os.environ.get("CLUTCH_TOKEN") or secrets.token_urlsafe(32)
TOKEN_DIR = Path(os.environ.get("CLUTCH_TOKEN_DIR", Path.home() / "Library" / "Application Support" / "Clutch"))
_token_written = False


def _publish_token(port: int) -> None:
    """Written on the first request actually served — a process that lost
    the race for its port never serves one, so it can't clobber the live
    server's token — and per port, so two backends never collide."""
    path = TOKEN_DIR / f"backend-{port}.token"
    TOKEN_DIR.mkdir(parents=True, exist_ok=True)
    path.touch(mode=0o600, exist_ok=True)
    path.chmod(0o600)  # readable by this user only
    path.write_text(TOKEN)


app = FastAPI(title="Clutch Backend", docs_url=None, redoc_url=None, openapi_url=None)


@app.middleware("http")
async def require_token(request: Request, call_next):
    global _token_written
    if not _token_written:
        _publish_token(request.scope["server"][1])
        _token_written = True
    # /health stays open so the app can find its backend; it reveals nothing.
    if request.url.path != "/api/v1/health" and not secrets.compare_digest(
        request.headers.get("X-Clutch-Token", ""), TOKEN
    ):
        return JSONResponse({"detail": "Unauthorized"}, status_code=401)
    return await call_next(request)


app.include_router(router)
