from __future__ import annotations

import os
from pathlib import Path


class RunLock:
    """An atomic per-archive lock that prevents concurrent writes."""
    def __init__(self, path: Path):
        self.path = path
        self.acquired = False

    def acquire(self) -> None:
        try:
            fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError as exc:
            raise RuntimeError(
                f"Another run appears active for this output folder ({self.path}). "
                "Wait for it to finish. If it was interrupted, remove only this lock file after confirming no run is active."
            ) from exc
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(str(os.getpid()))
        self.acquired = True

    def release(self) -> None:
        if self.acquired:
            self.path.unlink(missing_ok=True)
            self.acquired = False
