from __future__ import annotations

import csv
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from .models import Video


def now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


class Database:
    def __init__(self, path: Path):
        self.connection = sqlite3.connect(path)
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA journal_mode=WAL")
        self._migrate()

    def close(self) -> None:
        self.connection.close()

    def _migrate(self) -> None:
        self.connection.execute("""
            CREATE TABLE IF NOT EXISTS videos (
                video_id TEXT PRIMARY KEY, title TEXT NOT NULL, url TEXT NOT NULL,
                upload_date TEXT, duration INTEGER, channel TEXT, position INTEGER,
                live_status TEXT, status TEXT NOT NULL DEFAULT 'pending', method TEXT,
                transcript_path TEXT, detected_language TEXT, attempts INTEGER NOT NULL DEFAULT 0,
                error_message TEXT, discovered_at TEXT NOT NULL, processed_at TEXT, updated_at TEXT NOT NULL
            )
        """)
        self.connection.execute("CREATE INDEX IF NOT EXISTS ix_videos_status ON videos(status)")
        self.connection.commit()

    def upsert(self, video: Video, status: str = "pending", error: str | None = None) -> None:
        stamp = now()
        self.connection.execute("""
            INSERT INTO videos(video_id,title,url,upload_date,duration,channel,position,live_status,status,error_message,discovered_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(video_id) DO UPDATE SET title=excluded.title,url=excluded.url,
              upload_date=COALESCE(excluded.upload_date,videos.upload_date), duration=COALESCE(excluded.duration,videos.duration),
              channel=COALESCE(excluded.channel,videos.channel), position=COALESCE(excluded.position,videos.position),
              live_status=COALESCE(excluded.live_status,videos.live_status), updated_at=excluded.updated_at
        """, (video.video_id, video.title, video.url, video.upload_date, video.duration, video.channel,
              video.position, video.live_status, status, error, stamp, stamp))
        self.connection.commit()

    def row(self, video_id: str) -> sqlite3.Row | None:
        return self.connection.execute("SELECT * FROM videos WHERE video_id=?", (video_id,)).fetchone()

    def should_process(self, video_id: str, force: bool, retry_failed: bool) -> bool:
        row = self.row(video_id)
        if not row or force: return True
        return row["status"] != "completed" and (row["status"] != "failed" or retry_failed)

    def mark_running(self, video_id: str) -> None:
        self.connection.execute("UPDATE videos SET status='running',attempts=attempts+1,error_message=NULL,updated_at=? WHERE video_id=?", (now(), video_id))
        self.connection.commit()

    def finish(self, video_id: str, transcript_path: str, method: str, language: str | None) -> None:
        self.connection.execute("UPDATE videos SET status='completed',method=?,transcript_path=?,detected_language=?,processed_at=?,updated_at=? WHERE video_id=?", (method, transcript_path, language, now(), now(), video_id))
        self.connection.commit()

    def fail(self, video_id: str, message: str) -> None:
        self.connection.execute("UPDATE videos SET status='failed',error_message=?,processed_at=?,updated_at=? WHERE video_id=?", (message[:4000], now(), now(), video_id))
        self.connection.commit()

    def skip(self, video_id: str, reason: str) -> None:
        self.connection.execute("UPDATE videos SET status='skipped',error_message=?,updated_at=? WHERE video_id=?", (reason, now(), video_id))
        self.connection.commit()

    def counts(self) -> dict[str, int]:
        rows = self.connection.execute("SELECT status,COUNT(*) AS total FROM videos GROUP BY status").fetchall()
        return {r["status"]: r["total"] for r in rows}

    def completed(self) -> list[sqlite3.Row]:
        return self.connection.execute("SELECT * FROM videos WHERE status='completed' AND transcript_path IS NOT NULL ORDER BY COALESCE(position, 999999999), video_id").fetchall()

    def export_csvs(self, folder: Path) -> None:
        rows = self.connection.execute("SELECT * FROM videos ORDER BY COALESCE(position,999999999),video_id").fetchall()
        fields = list(rows[0].keys()) if rows else ["video_id", "title", "url", "status"]
        for name, selected in (("processing_log.csv", rows), ("videos.csv", rows), ("failed_videos.csv", [r for r in rows if r["status"] == "failed"])):
            with (folder / name).open("w", newline="", encoding="utf-8-sig") as handle:
                writer = csv.DictWriter(handle, fieldnames=fields)
                writer.writeheader(); writer.writerows(map(dict, selected))
