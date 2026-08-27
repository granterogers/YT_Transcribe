from __future__ import annotations

import re
import time
from html import unescape
from pathlib import Path
from typing import Callable, Iterable

from .models import Transcript, Video

_COOKIE_BROWSER: str | None = None
_COOKIE_FILE: str | None = None


def configure_cookies(browser: str | None, cookie_file: str | None = None) -> None:
    """Use the caller's local browser session when they explicitly opt in."""
    global _COOKIE_BROWSER, _COOKIE_FILE
    _COOKIE_BROWSER = browser
    _COOKIE_FILE = cookie_file


def _ydl(options: dict):
    import yt_dlp
    cookie_options = {"cookiesfrombrowser": (_COOKIE_BROWSER,)} if _COOKIE_BROWSER else {}
    if _COOKIE_FILE:
        cookie_options["cookiefile"] = _COOKIE_FILE
    return yt_dlp.YoutubeDL({"quiet": True, "no_warnings": True, "noplaylist": False, **cookie_options, **options})


def discover(url: str, limit: int | None) -> list[Video]:
    # A channel home page can include unavailable or nested shelf entries.  The
    # Videos tab is the predictable public-video listing, and flat extraction
    # means those entries are not individually resolved until processing.
    channel_url = url.rstrip("/")
    if not channel_url.endswith("/videos"):
        channel_url += "/videos"
    with _ydl({"extract_flat": True, "ignoreerrors": True, "skip_download": True,
               "playlistend": limit, "lazy_playlist": True}) as ydl:
        info = ydl.extract_info(channel_url, download=False)
    entries = list(info.get("entries") or [info])
    return [Video.from_info(entry, i) for i, entry in enumerate(entries) if entry and entry.get("id")]


def details(video: Video) -> Video:
    with _ydl({"skip_download": True}) as ydl:
        return Video.from_info(ydl.extract_info(video.url, download=False), video.position)


def get_captions(video: Video, workdir: Path, language: str | None) -> Transcript | None:
    workdir.mkdir(parents=True, exist_ok=True)
    # Never ask yt-dlp for every caption language: some videos expose many
    # translated tracks, which is slow and can trigger rate limits.  If no
    # preferred language is present, Whisper is the deliberate fallback.
    langs = [language] if language else ["en", "en-US", "en-GB"]
    options = {"skip_download": True, "writesubtitles": True, "writeautomaticsub": True, "subtitleslangs": langs,
               "subtitlesformat": "vtt", "ignoreerrors": True, "outtmpl": str(workdir / f"{video.video_id}.%(ext)s")}
    with _ydl(options) as ydl: ydl.download([video.url])
    candidates = sorted(workdir.glob(f"{video.video_id}*.vtt"))
    if not candidates: return None
    text, segments = parse_vtt(candidates[0].read_text(encoding="utf-8", errors="replace"))
    if len(text) < 20: return None
    return Transcript(text=text, method="YouTube captions", language=language or "en", segments=segments)


def parse_vtt(source: str) -> tuple[str, list[tuple[float, float, str]]]:
    blocks = re.split(r"\n\s*\n", source.replace("\r\n", "\n")); output=[]; segments=[]
    def stamp(value: str) -> float:
        values = [float(x) for x in value.strip().split(":")]
        return values[-1] + (values[-2] * 60 if len(values)>1 else 0) + (values[-3] * 3600 if len(values)>2 else 0)
    for block in blocks:
        lines = [x.strip() for x in block.splitlines() if x.strip()]
        timing = next((x for x in lines if "-->" in x), None)
        if not timing: continue
        raw = " ".join(lines[lines.index(timing)+1:]); clean = re.sub(r"<[^>]+>", "", raw).strip()
        clean = re.sub(r"^\s*(?:&gt;|>)+\s*", "", unescape(clean))
        clean = re.sub(r"\s+", " ", clean)
        appended = append_without_overlap(output, clean)
        if appended:
            start, end = timing.split("-->", 1); segments.append((stamp(start), stamp(end.split()[0]), appended))
    return " ".join(output), segments


def append_without_overlap(output: list[str], incoming: str) -> str:
    """Append only the new words from a rolling YouTube caption cue."""
    incoming_words = incoming.split()
    if not incoming_words:
        return ""
    previous_words = " ".join(output).split()
    def comparable(word: str) -> str:
        return re.sub(r"[^\w']", "", word).casefold()
    maximum = min(len(previous_words), len(incoming_words))
    overlap = 0
    for length in range(maximum, 0, -1):
        if [comparable(w) for w in previous_words[-length:]] == [comparable(w) for w in incoming_words[:length]]:
            overlap = length
            break
    new_words = incoming_words[overlap:]
    if not new_words:
        return ""
    result = " ".join(new_words)
    output.append(result)
    return result


def download_audio(video: Video, folder: Path) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    template = str(folder / f"{video.video_id}.%(ext)s")
    with _ydl({"format": "bestaudio/best", "outtmpl": template, "noplaylist": True, "ffmpeg_location": ffmpeg_executable(),
               "postprocessors": [{"key": "FFmpegExtractAudio", "preferredcodec": "mp3", "preferredquality": "192"}]}) as ydl:
        ydl.download([video.url])
    matches = list(folder.glob(f"{video.video_id}.*"))
    if not matches: raise RuntimeError("yt-dlp completed but no audio file was created")
    return max(matches, key=lambda p: p.stat().st_mtime)


def ffmpeg_executable() -> str:
    """Use a system FFmpeg when present, otherwise the package-supplied binary."""
    import shutil
    system = shutil.which("ffmpeg")
    if system:
        return system
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception as exc:
        raise RuntimeError("FFmpeg is required. Install imageio-ffmpeg or add FFmpeg to PATH.") from exc


class Whisper:
    def __init__(self, model_size: str, device: str, compute_type: str):
        self.model_size, self.device, self.compute_type, self.model = model_size, device, compute_type, None

    def transcribe(self, audio: Path, language: str | None) -> Transcript:
        if self.model is None:
            from faster_whisper import WhisperModel
            self.model = WhisperModel(self.model_size, device=self.device, compute_type=self.compute_type)
        segments, info = self.model.transcribe(str(audio), language=language, vad_filter=True)
        collected = [(s.start, s.end, s.text.strip()) for s in segments if s.text.strip()]
        if not collected: raise RuntimeError("Whisper returned an empty transcript")
        return Transcript("\n".join(s[2] for s in collected), "faster-whisper", getattr(info, "language", None), collected)


def choose_device(requested: str) -> tuple[str, str]:
    if requested in ("cpu", "cuda"): return requested, "int8" if requested == "cpu" else "float16"
    try:
        import ctranslate2
        if ctranslate2.get_cuda_device_count() > 0: return "cuda", "float16"
    except Exception: pass
    return "cpu", "int8"
