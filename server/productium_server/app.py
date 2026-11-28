"""Productium server: the app's one address on the internet (https://productium.duckdns.org).

Caddy on the Pi sends these paths here (127.0.0.1:8790) and every other /v1/* and /health to claude-server
(127.0.0.1:8787), which stays bound to localhost:

  GET    /v1/g/:group                 the group's members (leaderboard, same API as the old Cloudflare Worker)
  PUT    /v1/g/:group/m/:member       your row; `Authorization: Bearer <member key>` (the first write sets it)
  DELETE /v1/g/:group/m/:member       leave the group
  PUT    /v1/backup                   an encrypted backup (the app encrypts; the server never sees the data)
  GET    /v1/backup                   the newest one
  GET    /v1/backup/list              [{at, bytes}], newest first
  GET    /health                      liveness (only reachable on the Pi)

Backups are keyed by the device's claude-server key (`x-api-key`), checked against claude-server's /v1/usage.
"""
from __future__ import annotations

import hashlib
import json
import os
import time
from dataclasses import dataclass, field
from pathlib import Path

import httpx
from fastapi import FastAPI, Header, Request, Response
from fastapi.responses import JSONResponse

from .backups import BackupStore
from .board import Board, clean, ID


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default)


@dataclass
class Settings:
    data_dir: Path = field(default_factory=lambda: Path(_env("PRODUCTIUM_SERVER_DATA", "/var/lib/productium-server")))
    upstream: str = field(default_factory=lambda: _env("PRODUCTIUM_SERVER_UPSTREAM", "http://127.0.0.1:8787"))
    max_backup_bytes: int = field(default_factory=lambda: int(_env("PRODUCTIUM_SERVER_MAX_BACKUP", str(40 << 20))))
    backups_kept: int = field(default_factory=lambda: int(_env("PRODUCTIUM_SERVER_BACKUPS_KEPT", "6")))


def json_response(body, status: int = 200) -> JSONResponse:
    return JSONResponse(body, status_code=status, headers={"cache-control": "no-store"})


def create_app(settings: Settings | None = None, transport: httpx.AsyncBaseTransport | None = None) -> FastAPI:
    s = settings or Settings()
    s.data_dir.mkdir(parents=True, exist_ok=True)
    board = Board(s.data_dir / "board.db")
    backups = BackupStore(s.data_dir / "backups", keep=s.backups_kept)
    upstream = httpx.AsyncClient(base_url=s.upstream, transport=transport, timeout=10)
    valid: dict[str, float] = {}

    app = FastAPI(title="productium-server", docs_url=None, redoc_url=None, openapi_url=None)

    @app.get("/health")
    async def health():
        return {"ok": True}

    # ----- leaderboard -----

    @app.get("/v1/g/{group}")
    async def group(group: str):
        if not ID.match(group):
            return json_response({"error": "not found"}, 404)
        return json_response({"members": board.members(group)})

    @app.api_route("/v1/g/{group}/m/{member}", methods=["PUT", "DELETE", "GET", "POST"])
    async def member(group: str, member: str, request: Request):
        if not ID.match(group) or not ID.match(member):
            return json_response({"error": "not found"}, 404)
        auth = request.headers.get("authorization", "")
        auth = auth[7:].strip() if auth.lower().startswith("bearer ") else auth.strip()
        if not ID.match(auth):
            return json_response({"error": "missing key"}, 401)
        digest = hashlib.sha256(auth.encode()).hexdigest()
        owner = board.owner(group, member)
        if owner and owner != digest:
            return json_response({"error": "not your row"}, 403)
        if request.method == "DELETE":
            board.delete(group, member)
            return json_response({"ok": True})
        if request.method != "PUT":
            return json_response({"error": "method"}, 405)
        raw = await request.body()
        if len(raw) > Board.MAX_BODY:
            return json_response({"error": "too big"}, 413)
        try:
            post = clean(json.loads(raw))
        except ValueError:
            return json_response({"error": "bad json"}, 400)
        if not post:
            return json_response({"error": "bad post"}, 400)
        if not owner and board.count(group) >= Board.MAX_MEMBERS:
            return json_response({"error": "group full"}, 409)
        board.put(group, member, digest, post)
        return json_response({"ok": True})

    # ----- backups -----

    async def device(key: str | None) -> str | None:
        """sha256 of a claude-server key that claude-server accepts (cached 10 min)."""
        if not key or len(key) > 200:
            return None
        digest = hashlib.sha256(key.encode()).hexdigest()
        if valid.get(digest, 0) > time.time():
            return digest
        try:
            r = await upstream.get("/v1/usage", headers={"x-api-key": key})
        except httpx.HTTPError:
            return None
        if r.status_code != 200:
            return None
        valid[digest] = time.time() + 600
        return digest

    @app.put("/v1/backup")
    async def put_backup(request: Request, x_api_key: str | None = Header(default=None)):
        owner = await device(x_api_key)
        if not owner:
            return json_response({"error": "invalid or missing API key"}, 401)
        declared = int(request.headers.get("content-length") or 0)
        if declared > s.max_backup_bytes:
            return json_response({"error": "too big"}, 413)
        data = bytearray()
        async for chunk in request.stream():
            data += chunk
            if len(data) > s.max_backup_bytes:
                return json_response({"error": "too big"}, 413)
        if not data:
            return json_response({"error": "empty"}, 400)
        at = backups.put(owner, bytes(data))
        return json_response({"ok": True, "at": at, "bytes": len(data)})

    @app.get("/v1/backup")
    async def get_backup(x_api_key: str | None = Header(default=None)):
        owner = await device(x_api_key)
        if not owner:
            return json_response({"error": "invalid or missing API key"}, 401)
        newest = backups.newest(owner)
        if not newest:
            return json_response({"error": "no backup"}, 404)
        at, data = newest
        return Response(data, media_type="application/octet-stream",
                        headers={"x-backup-at": str(at), "cache-control": "no-store"})

    @app.get("/v1/backup/list")
    async def list_backups(x_api_key: str | None = Header(default=None)):
        owner = await device(x_api_key)
        if not owner:
            return json_response({"error": "invalid or missing API key"}, 401)
        return json_response({"backups": backups.list(owner)})

    return app


def main() -> None:
    import uvicorn
    uvicorn.run(create_app(), host=_env("PRODUCTIUM_SERVER_HOST", "127.0.0.1"),
                port=int(_env("PRODUCTIUM_SERVER_PORT", "8790")), proxy_headers=True, log_level="warning")
