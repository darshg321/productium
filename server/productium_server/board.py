"""The leaderboard's rows (one SQLite table). Same rules as the Cloudflare Worker it replaces: a group is a random
id anyone with the invite can read; each member writes only their own row (the first write sets its key, stored as
SHA-256); rows expire 60 days after their last write."""
from __future__ import annotations

import json
import re
import sqlite3
import threading
import time
from pathlib import Path

ID = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
DAY = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _int(v, lo: int, hi: int) -> int | None:
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v or v in (float("inf"), float("-inf")):
        return None
    return max(lo, min(hi, round(v)))


def clean(p) -> dict | None:
    """Only known fields, clamped; None when the body isn't a valid post."""
    if not isinstance(p, dict) or not isinstance(p.get("name"), str) or not isinstance(p.get("days"), list):
        return None
    name = p["name"].strip()[:40]
    if not name:
        return None
    days = []
    for d in p["days"][-Board.MAX_DAYS:]:
        if not isinstance(d, dict) or not isinstance(d.get("d"), str) or not DAY.match(d["d"]):
            return None
        row = {"d": d["d"], "score": _int(d.get("score"), 0, 100), "tracked": _int(d.get("tracked"), 0, 100),
               "work": _int(d.get("work"), 0, 1440), "met": _int(d.get("met"), 0, 50),
               "missed": _int(d.get("missed"), 0, 50), "scroll": _int(d.get("scroll"), 0, 1440)}
        if any(v is None for v in row.values()):
            return None
        days.append(row)
    usual = None if p.get("usual") is None else _int(p.get("usual"), 0, 100)
    return {"name": name, "usual": usual, "days": days}


class Board:
    MAX_DAYS, MAX_MEMBERS, MAX_BODY, TTL = 8, 50, 4096, 60 * 86400

    def __init__(self, path: Path):
        self._lock = threading.Lock()
        self._db = sqlite3.connect(str(path), check_same_thread=False)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("""CREATE TABLE IF NOT EXISTS members (
            grp TEXT NOT NULL, member TEXT NOT NULL, key_hash TEXT NOT NULL, row TEXT NOT NULL,
            expires REAL NOT NULL, PRIMARY KEY (grp, member))""")
        self._db.commit()

    def _prune(self) -> None:
        self._db.execute("DELETE FROM members WHERE expires < ?", (time.time(),))

    def members(self, group: str) -> list[dict]:
        with self._lock:
            self._prune()
            rows = self._db.execute("SELECT member, row FROM members WHERE grp=? ORDER BY member LIMIT ?",
                                    (group, self.MAX_MEMBERS)).fetchall()
        return [{"id": m, **json.loads(r)} for m, r in rows]

    def owner(self, group: str, member: str) -> str | None:
        with self._lock:
            self._prune()
            row = self._db.execute("SELECT key_hash FROM members WHERE grp=? AND member=?", (group, member)).fetchone()
        return row[0] if row else None

    def count(self, group: str) -> int:
        with self._lock:
            return self._db.execute("SELECT COUNT(*) FROM members WHERE grp=? AND expires >= ?",
                                    (group, time.time())).fetchone()[0]

    def put(self, group: str, member: str, key_hash: str, post: dict) -> None:
        row = {**post, "at": int(time.time() * 1000)}
        with self._lock:
            self._db.execute("INSERT OR REPLACE INTO members VALUES (?,?,?,?,?)",
                             (group, member, key_hash, json.dumps(row), time.time() + self.TTL))
            self._db.commit()

    def delete(self, group: str, member: str) -> None:
        with self._lock:
            self._db.execute("DELETE FROM members WHERE grp=? AND member=?", (group, member))
            self._db.commit()
