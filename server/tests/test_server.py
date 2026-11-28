import sys
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from productium_server.app import Settings, create_app  # noqa: E402

GOOD = "cs_good-key"


def upstream(request: httpx.Request) -> httpx.Response:
    assert request.url.path == "/v1/usage"
    return httpx.Response(200 if request.headers.get("x-api-key") == GOOD else 401, json={})


@pytest.fixture()
def client(tmp_path):
    s = Settings(data_dir=tmp_path, max_backup_bytes=1000, backups_kept=2)
    with TestClient(create_app(s, transport=httpx.MockTransport(upstream))) as c:
        yield c


G, M, K = "group-abcdefgh", "member-abcdefgh", "memberkey-abcdefgh"
POST = {"name": " Sam ", "usual": 70, "days": [{"d": "2026-11-27", "score": 140, "tracked": 88, "work": 200,
                                                 "met": 1, "missed": 0, "scroll": 30}]}


def test_leaderboard_rows(client):
    assert client.get(f"/v1/g/{G}").json() == {"members": []}
    assert client.put(f"/v1/g/{G}/m/{M}", json=POST).status_code == 401
    auth = {"Authorization": f"Bearer {K}"}
    assert client.put(f"/v1/g/{G}/m/{M}", json=POST, headers=auth).json() == {"ok": True}
    [m] = client.get(f"/v1/g/{G}").json()["members"]
    assert m["id"] == M and m["name"] == "Sam" and m["days"][0]["score"] == 100 and m["at"] > 0
    assert "key_hash" not in m and "keyHash" not in m
    other = {"Authorization": "Bearer someone-elses-key"}
    assert client.put(f"/v1/g/{G}/m/{M}", json=POST, headers=other).status_code == 403
    assert client.delete(f"/v1/g/{G}/m/{M}", headers=other).status_code == 403
    assert client.put(f"/v1/g/{G}/m/{M}", json={"name": "x", "days": [{"d": "bad"}]}, headers=auth).status_code == 400
    assert client.put(f"/v1/g/{G}/m/{M}", content=b"{", headers=auth).status_code == 400
    assert client.put(f"/v1/g/{G}/m/{M}", content=b"x" * 5000, headers=auth).status_code == 413
    assert client.get("/v1/g/short").status_code == 404
    assert client.delete(f"/v1/g/{G}/m/{M}", headers=auth).json() == {"ok": True}
    assert client.get(f"/v1/g/{G}").json() == {"members": []}


def test_group_full(client):
    from productium_server.board import Board
    Board.MAX_MEMBERS, old = 1, Board.MAX_MEMBERS
    try:
        assert client.put(f"/v1/g/{G}/m/{M}", json=POST, headers={"Authorization": f"Bearer {K}"}).status_code == 200
        r = client.put(f"/v1/g/{G}/m/member-2bcdefgh", json=POST, headers={"Authorization": "Bearer key-2bcdefgh"})
        assert r.status_code == 409
    finally:
        Board.MAX_MEMBERS = old


def test_backups(client):
    h = {"x-api-key": GOOD}
    assert client.get("/v1/backup", headers=h).status_code == 404
    assert client.put("/v1/backup", content=b"sealed", headers={"x-api-key": "cs_bad"}).status_code == 401
    assert client.put("/v1/backup", content=b"sealed").status_code == 401
    assert client.put("/v1/backup", content=b"x" * 1001, headers=h).status_code == 413
    assert client.put("/v1/backup", content=b"", headers=h).status_code == 400
    ats = [client.put("/v1/backup", content=f"v{i}".encode(), headers=h).json()["at"] for i in range(3)]
    assert ats == sorted(ats) and len(set(ats)) == 3
    r = client.get("/v1/backup", headers=h)
    assert r.content == b"v2" and r.headers["x-backup-at"] == str(ats[2])
    assert [b["at"] for b in client.get("/v1/backup/list", headers=h).json()["backups"]] == [ats[2], ats[1]]


def test_health(client):
    assert client.get("/health").json() == {"ok": True}
