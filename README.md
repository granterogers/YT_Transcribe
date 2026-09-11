# YT Transcribe

YT Transcribe turns a public YouTube channel into a resumable archive of readable Markdown transcripts. It uses English YouTube captions first, then local `faster-whisper` only when captions are unavailable.

The intended workflow is simple: **channel → Markdown transcripts → NotebookLM or another AI knowledge base.**

## Fast start

Open Command Prompt or PowerShell in the folder containing `transcribe_channel.py`:

```cmd
python -m venv .venv
.venv\Scripts\activate
python -m pip install --upgrade pip
pip install -r requirements.txt
```

Put an authorised Netscape-format YouTube cookie file, for example `youtube-cookies.txt`, beside `transcribe_channel.py`, then run a small test:

```cmd
python transcribe_channel.py "https://www.youtube.com/@CHANNEL/videos" --limit 3 --cookies-file "youtube-cookies.txt"
```

When the test transcripts look right, run the channel:

```cmd
python transcribe_channel.py "https://www.youtube.com/@CHANNEL/videos" --cookies-file "youtube-cookies.txt" --retries 1
```

All generated data is written beside the script under `youtube_transcripts/`.

## Repository layout

```text
YT_Transcribe/
├── transcribe_channel.py       CLI entry point and orchestration
├── requirements.txt            Python dependencies
├── channel_transcriber/
│   ├── database.py             SQLite state and CSV exports
│   ├── models.py               shared data objects and output paths
│   ├── output.py               Markdown, timestamps, combining
│   ├── run_lock.py             single-run protection
│   └── youtube.py              yt-dlp, captions, audio, Whisper
└── youtube_transcripts/        generated and ignored by Git
```

Do not copy only `transcribe_channel.py`: `channel_transcriber/` must remain alongside it.

## Output

```text
youtube_transcripts/
├── transcripts/                Video title.md files
├── metadata/
│   ├── processing_log.csv      complete worked/failed/skipped list
│   ├── videos.csv              compatibility copy of the full log
│   └── failed_videos.csv       failures only
├── database/transcripts.sqlite3
├── logs/transcribe.log         detailed diagnostics
├── combined/                   NotebookLM-oriented sources
└── audio/                      only used with --keep-audio
```

Each transcript has title, channel, ID, URL, publish date, duration, method and language. The body is formatted as readable paragraphs with a timestamp heading about every 30 seconds, for example `**[04:30]**`. Use `--no-timestamps` only when plain paragraphs are preferred.

## Cookies and multiple YouTube accounts

Videos that play in a signed-in browser can reject an unsigned command-line request. Use a cookie file only for an account that is legitimately allowed to watch the video.

For multiple Google accounts, create a dedicated Edge profile for the one account this job should use. Sign into only that account, verify its YouTube avatar, then export only `youtube.com` cookies in **Netscape** format with a reputable local-only cookie exporter. Save the resulting file beside the script and use:

```cmd
python transcribe_channel.py "CHANNEL_URL" --cookies-file "espavo_cookies.txt" --retry-failed --retries 1
```

Cookie files are authentication material. Never commit, email, upload, paste into chat, or keep them in a shared cloud folder. Export a fresh file when YouTube reports `The page needs to be reloaded` or the session expires. `.gitignore` excludes common cookie-file names.

`--cookies-from-browser edge` can read a local browser session directly. It is convenient on a normal PC but may fail in managed, sandboxed, or remote environments. An explicitly exported cookie file is more portable.

## Vimeo folders

Passing a Vimeo folder (or showcase) URL instead of a YouTube channel URL works the same way — the platform is detected automatically from the URL, and output defaults to `vimeo_transcripts/` beside the script instead of `youtube_transcripts/`, so the two never mix in the same database.

```cmd
python transcribe_channel.py "https://vimeo.com/user/USERID/folder/FOLDERID" --cookies-file "vimeo_cookies.txt" --retries 1
```

Private folders require an authenticated session the same way private YouTube videos do: export **only `vimeo.com`** cookies (Netscape format) from an account with access to the folder, following the same steps as above. `--include-shorts`/`--include-livestreams` have no effect on Vimeo (there is no equivalent distinction); every entry in the folder is processed.

## Commands

### Discover without downloading

```cmd
python transcribe_channel.py "CHANNEL_URL" --limit 3 --dry-run
```

### Process a small test

```cmd
python transcribe_channel.py "CHANNEL_URL" --limit 3 --cookies-file "youtube-cookies.txt"
```

### Resume

Rerun the same command. Completed videos are skipped automatically.

```cmd
python transcribe_channel.py "CHANNEL_URL" --cookies-file "youtube-cookies.txt"
```

### Retry previous failures

```cmd
python transcribe_channel.py "CHANNEL_URL" --cookies-file "youtube-cookies.txt" --retry-failed --retries 1
```

### Deliberately redo completed videos

```cmd
python transcribe_channel.py "CHANNEL_URL" --force
```

### Include normally excluded content

```cmd
python transcribe_channel.py "CHANNEL_URL" --include-shorts --include-livestreams
```

### Choose a Whisper model

```cmd
python transcribe_channel.py "CHANNEL_URL" --model medium
```

`small` is the default balance. `tiny` and `base` are good for fast testing. `medium` and `large-v3` need more time and memory. CUDA is selected automatically when a compatible NVIDIA GPU is available; otherwise CPU is used.

### Keep downloaded audio

```cmd
python transcribe_channel.py "CHANNEL_URL" --keep-audio
```

Audio is deleted after successful local transcription by default.

### Combine sources for NotebookLM

```cmd
python transcribe_channel.py --combine
```

This writes groups of approximately 45 clearly separated videos into `youtube_transcripts/combined/`. Tune with `--combine-size 40` or `--max-combined-chars 1200000`.

## Processing model

1. yt-dlp discovers the channel’s public Videos listing.
2. Every discovery is written to SQLite.
3. Each video is loaded one at a time for full metadata.
4. English captions are tried first: `en`, `en-US`, and `en-GB`.
5. Automatic rolling VTT caption cues are de-duplicated by word overlap.
6. If captions are absent, yt-dlp extracts audio and faster-whisper transcribes locally.
7. The Markdown file and SQLite status are committed before the next video.
8. CSV logs are refreshed after every item.

## Status and failure handling

| Status | Meaning |
| --- | --- |
| `completed` | A Markdown transcript was created. |
| `failed` | Access, caption, download, or transcription failed; inspect `processing_log.csv`. |
| `skipped` | The content type was excluded, such as a Short or livestream. |
| `pending` | Discovered but not yet processed. |
| `running` | The run was interrupted mid-item; it will be retried on the next run. |

The console gives concise failure messages. Full tracebacks go only to `logs/transcribe.log`. `Ctrl+C` is safe: rerun the same command to continue. A per-archive lock prevents two copies of the script from working on the same SQLite database.

The tool records and continues past deleted, private, region-restricted, DRM-protected, paywalled, CAPTCHA-gated, or otherwise unauthorised videos. It does not bypass access controls.

## Troubleshooting

| Symptom | Response |
| --- | --- |
| `ModuleNotFoundError: channel_transcriber` | Extract or clone the complete project, not only the main script. |
| `The page needs to be reloaded` | Refresh and re-export a fresh cookie file from the intended account profile, then run with `--retry-failed`. |
| `This video is not available` | YouTube itself is denying access. It may be deleted, private, or restricted for the selected session. |
| FFmpeg error | Run `pip install -r requirements.txt`; `imageio-ffmpeg` supplies a fallback binary. |
| CUDA error | Continue with `--device cpu`. |
| Missing output | Inspect `metadata/processing_log.csv` and `logs/transcribe.log`. |

## Handoff notes for another AI or developer

This is intentionally a small Python project. Preserve that unless a clear requirement calls for more.

- SQLite, not filenames, is the resume source of truth.
- Caption-first processing saves downloads and local compute.
- English is the default language for this channel, but `--language` remains configurable.
- `append_without_overlap` in `channel_transcriber/youtube.py` is essential: YouTube automatic captions commonly repeat earlier words in each rolling cue.
- Never log cookie values or commit cookie files.
- Do not retry deterministic errors such as `This video is not available`; retry transient 429, timeout, connection-reset and server errors.
- Do not remove the single-run lock.
- Keep relative cookie-file paths and default output rooted beside the script.

Before changing YouTube clients, cookies, download settings or transcription flow, run `--limit 3 --dry-run`, then a small authenticated test. YouTube behaviour changes often.

## Repository policy

Source and documentation only belong in Git. Never commit cookie files, browser-profile data, transcripts, SQLite databases, audio, logs, `.venv`, API keys, passwords, or account exports. Review `git status` before every commit.
