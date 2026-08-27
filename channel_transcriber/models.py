from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class Video:
    video_id: str
    title: str
    url: str
    upload_date: str | None = None
    duration: int | None = None
    channel: str | None = None
    position: int | None = None
    live_status: str | None = None
    webpage_url: str | None = None

    @classmethod
    def from_info(cls, info: dict[str, Any], position: int | None = None) -> "Video":
        video_id = str(info.get("id") or "")
        if not video_id:
            raise ValueError("yt-dlp returned an entry without a video ID")
        url = info.get("webpage_url") or info.get("url")
        if not url or not str(url).startswith("http"):
            url = f"https://www.youtube.com/watch?v={video_id}"
        return cls(
            video_id=video_id,
            title=str(info.get("title") or video_id),
            url=str(url),
            upload_date=info.get("upload_date"),
            duration=info.get("duration"),
            channel=info.get("channel") or info.get("uploader"),
            position=position,
            live_status=info.get("live_status"),
            webpage_url=info.get("webpage_url"),
        )


@dataclass
class Transcript:
    text: str
    method: str
    language: str | None = None
    segments: list[tuple[float, float, str]] | None = None


@dataclass(frozen=True)
class Paths:
    root: Path

    @property
    def transcripts(self) -> Path: return self.root / "transcripts"
    @property
    def metadata(self) -> Path: return self.root / "metadata"
    @property
    def logs(self) -> Path: return self.root / "logs"
    @property
    def audio(self) -> Path: return self.root / "audio"
    @property
    def database(self) -> Path: return self.root / "database"
    @property
    def combined(self) -> Path: return self.root / "combined"
    @property
    def db_file(self) -> Path: return self.database / "transcripts.sqlite3"

    def create(self) -> None:
        for folder in (self.transcripts, self.metadata, self.logs, self.audio, self.database, self.combined):
            folder.mkdir(parents=True, exist_ok=True)
