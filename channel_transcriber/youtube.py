from __future__ import annotations

import logging
import re
import time
from html import unescape
from pathlib import Path
from typing import Callable, Iterable

from .models import Transcript, Video


def _clock(seconds: float) -> str:
    hours, remainder = divmod(int(seconds), 3600); minutes, secs = divmod(remainder, 60)
    return f"{hours}:{minutes:02}:{secs:02}" if hours else f"{minutes:02}:{secs:02}"

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
    # YouTube's "n challenge" and PO Token requirements block extraction
    # without a working JS runtime; Node is the one reliably present locally.
    return yt_dlp.YoutubeDL({"quiet": True, "no_warnings": True, "noplaylist": False,
                              "js_runtimes": {"node": {}}, **cookie_options, **options})


_CHANNEL_TABS = ("videos", "shorts", "streams")


def discover(url: str, limit: int | None) -> list[Video]:
    if "vimeo.com" in url:
        return discover_vimeo(url, limit)
    return discover_youtube(url, limit)


def discover_vimeo(url: str, limit: int | None) -> list[Video]:
    from .vimeo_api import is_folder_url, list_folder_videos
    if is_folder_url(url):
        # yt-dlp has no extractor for Vimeo "folders" at all -- it falls
        # through and misreads the folder ID as a video ID. Vimeo's own
        # REST API is the only way to enumerate one.
        return list_folder_videos(url, limit)
    # A showcase/album/channel is already a single flat listing, unlike
    # YouTube's split videos/shorts/streams tabs. ignoreerrors is
    # deliberately left off: a listing-level failure (e.g. not logged in)
    # should raise so the real cause reaches the caller, not a silent None.
    with _ydl({"extract_flat": True, "skip_download": True,
               "playlistend": limit, "lazy_playlist": True}) as ydl:
        info = ydl.extract_info(url, download=False)
    entries = list(info.get("entries") or [info])
    videos = [Video.from_info(entry, i) for i, entry in enumerate(entries) if entry and entry.get("id")]
    return videos[:limit] if limit else videos


def discover_youtube(url: str, limit: int | None) -> list[Video]:
    # Regular uploads, Shorts, and livestream VODs live in three separate
    # channel tabs; a channel URL naming one of them still needs the others
    # stripped off so all three can be queried and merged (deduped by ID).
    base_url = url.rstrip("/")
    for tab in _CHANNEL_TABS:
        suffix = f"/{tab}"
        if base_url.endswith(suffix):
            base_url = base_url[: -len(suffix)]
            break
    found: dict[str, Video] = {}
    for tab in _CHANNEL_TABS:
        if limit and len(found) >= limit:
            break
        try:
            with _ydl({"extract_flat": True, "ignoreerrors": True, "skip_download": True,
                       "playlistend": limit, "lazy_playlist": True}) as ydl:
                info = ydl.extract_info(f"{base_url}/{tab}", download=False)
        except Exception:
            continue  # Some channels do not have a Shorts or Live tab at all.
        for entry in list(info.get("entries") or [info]):
            if entry and entry.get("id") and entry["id"] not in found:
                found[entry["id"]] = Video.from_info(entry, len(found))
    videos = list(found.values())
    return videos[:limit] if limit else videos


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


def _register_cuda_dll_dirs() -> None:
    """pip-installed nvidia-cublas-cu12/nvidia-cudnn-cu12 aren't auto-registered
    with Windows' DLL search path the way PyTorch's bundled copies are;
    ctranslate2 needs their bin/ directories added explicitly before first use.

    This must go on PATH, not just os.add_dll_directory(): ctranslate2's actual
    GPU work sometimes runs in a relaunched child process (observed via this
    venv's own python.exe launcher on this machine), and add_dll_directory()
    only affects the current process -- PATH is what a child process inherits.
    """
    import os
    import sys
    if sys.platform != "win32":
        return
    try:
        import importlib.util
        spec = importlib.util.find_spec("nvidia")
        base = Path(spec.submodule_search_locations[0])
    except Exception:
        return
    bin_dirs = [str(d) for d in base.glob("*/bin")]
    for bin_dir in bin_dirs:
        if hasattr(os, "add_dll_directory"):
            try: os.add_dll_directory(bin_dir)
            except Exception: pass
    existing = os.environ.get("PATH", "")
    new_dirs = [d for d in bin_dirs if d not in existing]
    if new_dirs:
        os.environ["PATH"] = os.pathsep.join(new_dirs + [existing])


class Whisper:
    def __init__(self, model_size: str, device: str, compute_type: str):
        self.model_size, self.device, self.compute_type, self.model = model_size, device, compute_type, None

    def transcribe(self, audio: Path, language: str | None) -> Transcript:
        if self.model is None:
            if self.device == "cuda":
                _register_cuda_dll_dirs()
            from faster_whisper import WhisperModel
            self.model = WhisperModel(self.model_size, device=self.device, compute_type=self.compute_type)
        segments, info = self.model.transcribe(str(audio), language=language, vad_filter=True)
        total = getattr(info, "duration", None)
        collected: list[tuple[float, float, str]] = []
        last_report = 0.0
        for s in segments:
            if s.text.strip(): collected.append((s.start, s.end, s.text.strip()))
            # faster-whisper's `segments` is a lazy generator: this loop IS the
            # transcription work, so it's the only place progress can be shown.
            if total and s.end - last_report >= 30:
                logging.info("  ... transcribing %s / %s", _clock(s.end), _clock(total))
                last_report = s.end
        if not collected: raise RuntimeError("Whisper returned an empty transcript")
        return Transcript("\n".join(s[2] for s in collected), "faster-whisper", getattr(info, "language", None), collected)


def choose_device(requested: str) -> tuple[str, str]:
    if requested in ("cpu", "cuda"): return requested, "int8" if requested == "cpu" else "float16"
    try:
        import ctranslate2
        if ctranslate2.get_cuda_device_count() > 0: return "cuda", "float16"
    except Exception: pass
    return "cpu", "int8"
