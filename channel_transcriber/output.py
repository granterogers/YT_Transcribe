from __future__ import annotations

import re
from pathlib import Path
from .models import Transcript, Video


def safe_name(value: str) -> str:
    value = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "", value).strip().rstrip(".")
    return (value[:120] or "untitled")


def duration(seconds: int | None) -> str:
    if seconds is None: return "Unknown"
    hours, remainder = divmod(int(seconds), 3600); minutes, secs = divmod(remainder, 60)
    return f"{hours}:{minutes:02}:{secs:02}" if hours else f"{minutes}:{secs:02}"


def write_transcript(folder: Path, video: Video, transcript: Transcript, timestamps: bool) -> Path:
    path = folder / f"{safe_name(video.title)}.txt"
    # A title is the friendly default filename. Preserve distinct transcripts
    # if the channel happens to publish two videos with the same title.
    if path.exists():
        path = folder / f"{safe_name(video.title)} - {video.video_id}.txt"
    lines = [video.title, "", f"Channel: {video.channel or 'Unknown'}", f"Video ID: {video.video_id}",
             f"URL: {video.url}", f"Published: {video.upload_date or 'Unknown'}", f"Duration: {duration(video.duration)}",
             f"Transcription method: {transcript.method}", f"Language: {transcript.language or 'Auto-detected/unknown'}", "", "--- Transcript ---", ""]
    if timestamps and transcript.segments:
        lines.extend(format_timestamped(transcript.segments, speakers=transcript.speakers))
    else:
        lines.extend(paragraphs(transcript.text))
    path.write_text("\n".join(lines).strip() + "\n", encoding="utf-8")
    return path


def clock(seconds: float) -> str:
    hours, remainder = divmod(int(seconds), 3600); minutes, secs = divmod(remainder, 60)
    return f"{hours}:{minutes:02}:{secs:02}" if hours else f"{minutes:02}:{secs:02}"


def format_timestamped(segments: list[tuple[float, float, str]], interval: int = 30, speakers: list[str] | None = None) -> list[str]:
    """Make roughly 30-second, human-readable timestamped paragraphs.

    With `speakers` (one label per segment, e.g. from diarization), a chunk also
    breaks on a speaker change so each block is a single person's turn.
    """
    result: list[str] = []; chunk: list[str] = []; started: float | None = None; speaker: str | None = None
    for i, (start, _end, text) in enumerate(segments):
        current_speaker = speakers[i] if speakers else None
        if started is None: started = start; speaker = current_speaker
        if chunk and (start - started >= interval or current_speaker != speaker):
            label = f"[{clock(started)}] {speaker}:" if speaker else f"[{clock(started)}]"
            result.extend([label, " ".join(chunk), ""])
            chunk = []; started = start; speaker = current_speaker
        chunk.append(text)
    if chunk and started is not None:
        label = f"[{clock(started)}] {speaker}:" if speaker else f"[{clock(started)}]"
        result.extend([label, " ".join(chunk)])
    return result


def paragraphs(text: str, maximum: int = 850) -> list[str]:
    sentences = re.split(r"(?<=[.!?])\s+", text.strip())
    result: list[str] = []; chunk: list[str] = []; size = 0
    for sentence in sentences:
        if chunk and size + len(sentence) + 1 > maximum:
            result.extend([" ".join(chunk), ""]); chunk = []; size = 0
        chunk.append(sentence); size += len(sentence) + 1
    if chunk: result.append(" ".join(chunk))
    return result


def combine(paths: Path, rows: list, per_file: int, max_chars: int) -> list[Path]:
    for old in paths.combined.glob("videos_*.txt"): old.unlink()
    created: list[Path] = []; batch: list[tuple[object, str]] = []; size = 0
    def flush() -> None:
        nonlocal batch, size
        if not batch: return
        first, last = batch[0][0], batch[-1][0]
        text = "\n\n---\n\n".join(item[1] for item in batch) + "\n"
        target = paths.combined / f"videos_{int(first['position'] or 0)+1:03d}-{int(last['position'] or 0)+1:03d}.txt"
        target.write_text(text, encoding="utf-8"); created.append(target); batch=[]; size=0
    for row in rows:
        content = Path(row["transcript_path"]).read_text(encoding="utf-8")
        section = f"VIDEO {int(row['position'] or 0)+1} — {row['title']}\n\n" + content
        if batch and (len(batch) >= per_file or size + len(section) > max_chars): flush()
        batch.append((row, section)); size += len(section)
    flush(); return created
