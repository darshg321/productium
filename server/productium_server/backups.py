"""Encrypted backups, newest `keep` per device. Files are `<ms since 1970>.bin` in a folder named by the sha256 of
the device's key; their contents are opaque (the app seals them with AES-GCM before sending)."""
from __future__ import annotations

import os
import re
import threading
import time
from pathlib import Path

NAME = re.compile(r"^(\d+)\.bin$")
OWNER = re.compile(r"^[0-9a-f]{64}$")


class BackupStore:
    def __init__(self, root: Path, keep: int = 6):
        self.root, self.keep = root, keep
        self._lock = threading.Lock()
        root.mkdir(parents=True, exist_ok=True, mode=0o700)

    def _dir(self, owner: str) -> Path:
        if not OWNER.match(owner):
            raise ValueError("bad owner")
        return self.root / owner

    def _files(self, owner: str) -> list[tuple[int, Path]]:
        d = self._dir(owner)
        if not d.is_dir():
            return []
        found = [(int(m.group(1)), p) for p in d.iterdir() if (m := NAME.match(p.name))]
        return sorted(found, reverse=True)

    def put(self, owner: str, data: bytes) -> int:
        d = self._dir(owner)
        with self._lock:
            d.mkdir(exist_ok=True, mode=0o700)
            newest = self._files(owner)
            at = max(int(time.time() * 1000), (newest[0][0] + 1) if newest else 0)
            tmp = d / f".{at}.tmp"
            tmp.write_bytes(data)
            os.chmod(tmp, 0o600)
            tmp.replace(d / f"{at}.bin")
            for _, old in self._files(owner)[self.keep:]:
                old.unlink(missing_ok=True)
        return at

    def newest(self, owner: str) -> tuple[int, bytes] | None:
        files = self._files(owner)
        return (files[0][0], files[0][1].read_bytes()) if files else None

    def list(self, owner: str) -> list[dict]:
        return [{"at": at, "bytes": p.stat().st_size} for at, p in self._files(owner)]
