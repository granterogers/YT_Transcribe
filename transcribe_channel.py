from __future__ import annotations

import argparse
import logging
import shutil
import sys
import tempfile
import time
from pathlib import Path

from channel_transcriber.database import Database
from channel_transcriber.models import Paths, Video
from channel_transcriber.output import combine, write_markdown
from channel_transcriber.run_lock import RunLock

SCRIPT_FOLDER = Path(__file__).resolve().parent
from channel_transcriber.youtube import Whisper, choose_device, configure_cookies, details, discover, download_audio, get_captions


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Resumable, caption-first YouTube channel transcription.")
    parser.add_argument("channel_url", nargs="?", help="YouTube channel/videos-page URL")
    parser.add_argument("--output-dir", help="Output folder (default: youtube_transcripts beside this script)")
    parser.add_argument("--model", default="small", choices=["tiny", "base", "small", "medium", "large-v3"])
    parser.add_argument("--language", default="en", help="Spoken/caption language (default: en).")
    parser.add_argument("--device", default="auto", choices=["auto", "cpu", "cuda"])
    parser.add_argument("--limit", type=int, help="Process at most this many discovered videos.")
    parser.add_argument("--include-shorts", action="store_true")
    parser.add_argument("--include-livestreams", action="store_true")
    parser.add_argument("--resume", action="store_true", help="Retained for clarity; reruns are safe by default.")
    parser.add_argument("--force", action="store_true", help="Reprocess completed videos.")
    parser.add_argument("--retry-failed", action="store_true")
    parser.add_argument("--retries", type=int, default=3)
    parser.add_argument("--delay", type=float, default=1.0, help="Seconds between videos (default: 1).")
    cookies = parser.add_mutually_exclusive_group()
    cookies.add_argument("--cookies-from-browser", nargs="?", const="chrome", choices=["chrome", "edge", "firefox", "brave", "opera", "vivaldi"],
                        help="Use a local signed-in browser session for legitimately accessible videos (default: chrome).")
    cookies.add_argument("--cookies-file", help="Netscape-format cookie file created from your own browser session.")
    parser.add_argument("--keep-audio", action="store_true")
    parser.add_argument("--timestamps", action=argparse.BooleanOptionalAction, default=True, help="Include readable timestamps (default: enabled).")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--combine", action="store_true", help="Create NotebookLM-oriented combined files, then exit.")
    parser.add_argument("--combine-size", type=int, default=45, help="Videos per combined source (default: 45).")
    parser.add_argument("--max-combined-chars", type=int, default=1_500_000)
    parser.add_argument("--log-level", default="INFO", choices=["DEBUG", "INFO", "WARNING", "ERROR"])
    return parser.parse_args()


def excluded(video: Video, include_shorts: bool, include_livestreams: bool) -> str | None:
    url = video.webpage_url or video.url
    if not include_shorts and ("/shorts/" in url or (video.duration is not None and video.duration <= 60)): return "short excluded"
    if not include_livestreams and video.live_status in {"is_live", "was_live", "post_live", "upcoming"}: return "livestream excluded"
    return None


def retry(action, attempts: int):
    last = None
    for number in range(1, attempts + 1):
        try: return action()
        except Exception as exc:
            last = exc
            if not is_transient(exc):
                raise
            if number < attempts:
                logging.warning("Temporary problem (%s/%s): %s. Retrying.", number, attempts, concise_error(exc))
                time.sleep(min(30, 2 ** (number - 1)))
    raise last  # type: ignore[misc]


def is_transient(error: Exception) -> bool:
    text = str(error).casefold()
    return any(marker in text for marker in ("http error 429", "http error 5", "timed out", "timeout", "connection reset", "temporarily unavailable"))


def concise_error(error: Exception) -> str:
    text = " ".join(str(error).replace("ERROR:", "").split())
    return text[:350] or type(error).__name__


def main() -> int:
    args = arguments()
    output_folder = Path(args.output_dir).resolve() if args.output_dir else SCRIPT_FOLDER / "youtube_transcripts"
    cookie_file = Path(args.cookies_file) if args.cookies_file else None
    if cookie_file and not cookie_file.is_absolute(): cookie_file = SCRIPT_FOLDER / cookie_file
    paths = Paths(output_folder); paths.create()
    configure_cookies(args.cookies_from_browser, str(cookie_file) if cookie_file else None)
    formatter = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    console = logging.StreamHandler(); console.setLevel(getattr(logging, args.log_level)); console.setFormatter(formatter)
    file_log = logging.FileHandler(paths.logs / "transcribe.log", encoding="utf-8"); file_log.setLevel(logging.DEBUG); file_log.setFormatter(formatter)
    logging.basicConfig(level=logging.DEBUG, handlers=[console, file_log])
    database = Database(paths.db_file)
    lock = RunLock(paths.database / ".transcribe.lock")
    try:
        lock.acquire()
        if args.combine:
            made = combine(paths, database.completed(), args.combine_size, args.max_combined_chars)
            print(f"Created {len(made)} combined NotebookLM source file(s) in {paths.combined}"); return 0
        if not args.channel_url:
            raise SystemExit("channel_url is required unless --combine is used.")
        videos = discover(args.channel_url, args.limit)
        print(f"Discovered {len(videos)} video(s).")
        for video in videos: database.upsert(video)
        if args.dry_run:
            for video in videos: print(f"[{video.position + 1}/{len(videos)}] {video.title} | {video.url}")
            database.export_csvs(paths.metadata); return 0
        device, compute = choose_device(args.device); whisper = Whisper(args.model, device, compute)
        logging.info("Whisper will use %s (%s); model loads only if a video needs transcription.", device, compute)
        if args.cookies_from_browser:
            logging.info("Using the local %s browser session for YouTube requests.", args.cookies_from_browser)
        elif args.cookies_file:
            logging.info("Using the supplied local cookie file for YouTube requests.")
        for index, discovered_video in enumerate(videos, 1):
            if not database.should_process(discovered_video.video_id, args.force, args.retry_failed): continue
            try:
                video = retry(lambda: details(discovered_video), args.retries)
                why = excluded(video, args.include_shorts, args.include_livestreams)
                if why:
                    database.skip(video.video_id, why)
                    logging.info("[%s/%s] Skipped %s: %s", index, len(videos), video.title, why); continue
                database.upsert(video); database.mark_running(video.video_id)
                logging.info("[%s/%s] %s", index, len(videos), video.title)
                with tempfile.TemporaryDirectory(prefix=f"yt_{video.video_id}_") as temp:
                    temp_path = Path(temp)
                    transcript = retry(lambda: get_captions(video, temp_path, args.language), args.retries)
                    if transcript is None:
                        logging.info("No usable caption track; transcribing locally with faster-whisper.")
                        audio = retry(lambda: download_audio(video, temp_path), args.retries)
                        transcript = retry(lambda: whisper.transcribe(audio, args.language), args.retries)
                        if args.keep_audio: shutil.copy2(audio, paths.audio / f"{video.video_id}{audio.suffix}")
                output = write_markdown(paths.transcripts, video, transcript, args.timestamps)
                database.finish(video.video_id, str(output), transcript.method, transcript.language)
                logging.info("Completed with %s", transcript.method)
            except Exception as exc:
                message = f"{type(exc).__name__}: {concise_error(exc)}"; database.fail(discovered_video.video_id, message)
                logging.error("[%s/%s] Failed: %s", index, len(videos), message)
                logging.debug("Full traceback for %s", discovered_video.video_id, exc_info=True)
            finally:
                database.export_csvs(paths.metadata)
            time.sleep(max(0, args.delay))
        counts = database.counts(); print(f"Finished. Completed: {counts.get('completed', 0)} | Failed: {counts.get('failed', 0)} | Skipped: {counts.get('skipped', 0)} | Pending: {counts.get('pending', 0)}")
        print(f"CSV files: {paths.metadata}; logs: {paths.logs}")
        return 0
    finally:
        lock.release()
        database.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nStopped safely. Run the same command again to continue.", file=sys.stderr)
        raise SystemExit(130)
