# YouTube Channel Transcript Archive

This Windows-friendly command-line tool builds a durable Markdown archive from a YouTube channel you are authorised to archive. It discovers videos with `yt-dlp`, uses existing captions first, and only downloads audio and runs local `faster-whisper` when captions are not usable. It remembers every result in SQLite, so stopping halfway through is safe.

It does not bypass YouTube authentication, CAPTCHAs, paywalls, DRM, private videos, or other access controls. If YouTube requires access the tool cannot legitimately obtain, that video is recorded as failed and the run continues.

## What it creates

The default output folder is `youtube_transcripts`:

```text
youtube_transcripts/
  transcripts/       one Markdown file per completed video
  metadata/          videos.csv and failed_videos.csv
  logs/              transcribe.log
  audio/             empty by default; used only with --keep-audio
  database/          transcripts.sqlite3 (the resume record)
  combined/          larger NotebookLM-ready Markdown source files
```

Each transcript includes the title, channel, URL, publish date, duration, transcription method, detected language, and the transcript itself.

## Install on Windows

### 1. Install Python

Install Python 3.10 or later from [python.org](https://www.python.org/downloads/windows/). During installation, select **Add Python to PATH**. Open a new PowerShell window afterward and check:

```powershell
python --version
```

### 2. FFmpeg

`yt-dlp` needs FFmpeg to extract audio for videos that have no usable captions. The project's dependency installation below includes a private FFmpeg binary, so a separate system-wide installation is normally unnecessary.

If you prefer to manage it yourself, the simplest system-wide route is Winget:

```powershell
winget install Gyan.FFmpeg
```

Close and reopen PowerShell, then check:

```powershell
ffmpeg -version
```

If Winget is unavailable, install an FFmpeg build manually and add its `bin` folder to your Windows `PATH`.

### 3. Create a virtual environment and install packages

Open PowerShell in this project folder and run:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install -r requirements.txt
```

If PowerShell prevents activation, run this once in that PowerShell window and retry:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## First test: exactly three videos

Replace the URL with your channel's URL. The tool automatically uses its public **Videos** tab. This uses the real workflow but processes only three discovered videos:

```powershell
python transcribe_channel.py "https://www.youtube.com/@YOUR_CHANNEL/videos" --limit 3
```

Start with `--dry-run` if you only want to confirm discovery and see the first three videos without downloading or transcribing:

```powershell
python transcribe_channel.py "https://www.youtube.com/@YOUR_CHANNEL/videos" --limit 3 --dry-run
```

Review `youtube_transcripts\transcripts` and `youtube_transcripts\metadata\videos.csv` before launching the complete archive.

## Run the full channel

```powershell
python transcribe_channel.py "https://www.youtube.com/@YOUR_CHANNEL/videos"
```

The tool normally excludes Shorts and livestreams. The conservative Shorts rule excludes `/shorts/` URLs and videos a minute or shorter, so a short conventional video can be excluded too. Include those content types explicitly when wanted:

```powershell
python transcribe_channel.py "https://www.youtube.com/@YOUR_CHANNEL/videos" --include-shorts --include-livestreams
```

Use a separate archive folder for each channel if needed:

```powershell
python transcribe_channel.py "CHANNEL_URL" --output-dir "D:\Archives\my-channel"
```

## Stop, resume, and retry

Press `Ctrl+C` to stop. Every completed video is committed to SQLite before the next one begins. Run the same command again to continue: completed videos are skipped by default.

```powershell
python transcribe_channel.py "CHANNEL_URL" --resume
```

`--resume` is included as an easy-to-read reminder; safe resume is the default behaviour. To retry only videos that previously failed:

```powershell
python transcribe_channel.py "CHANNEL_URL" --retry-failed
```

To deliberately redo every completed video, use `--force`. This overwrites their Markdown files when the filename remains the same.

```powershell
python transcribe_channel.py "CHANNEL_URL" --force
```

## Transcript quality and speed

The default `small` model is a sensible starting point for a normal PC. Models are only loaded when a video needs local transcription; captioned videos do not use Whisper.

| Model | Best for | Trade-off |
| --- | --- | --- |
| `tiny` / `base` | Fast trial runs | Lowest accuracy |
| `small` | Most first full archives | Good balance |
| `medium` | Clearer speech, higher accuracy | Slower and uses more memory |
| `large-v3` | Highest quality, capable GPU | Much slower/heavier on CPU |

The program uses an NVIDIA CUDA device automatically when `faster-whisper` can see one, otherwise it falls back to CPU. You can make the choice explicit:

```powershell
python transcribe_channel.py "CHANNEL_URL" --model medium --device cpu
python transcribe_channel.py "CHANNEL_URL" --model large-v3 --device cuda
```

Set a language when you know it, for example `--language en`. Leaving it out lets Whisper detect the spoken language; caption lookup tries English tracks first and falls back to Whisper rather than downloading every translated caption track.

## Useful options

```text
--timestamps                 Put timestamps beside transcript segments.
--keep-audio                 Retain extracted MP3 files (uses substantial disk space).
--retries 5                  Retry temporary operation failures five times.
--delay 2                    Wait two seconds between videos.
--log-level DEBUG            More diagnostic detail in the log.
--limit 10                   Process at most ten discovered videos.
--dry-run                    Discover and list videos, but do no downloading/transcription.
--cookies-from-browser edge  Use the local Edge session for videos you can watch while signed in.
```

## Combine transcripts for NotebookLM

Once a run has created individual Markdown transcripts, make larger sources without contacting YouTube again:

```powershell
python transcribe_channel.py --combine
```

By default the command creates groups of 45 videos, while also keeping each combined file below approximately 1.5 million characters. That usually produces a comfortable number of clearly separated sources for NotebookLM. Change the grouping if desired:

```powershell
python transcribe_channel.py --combine --combine-size 40 --max-combined-chars 1200000
```

Upload files from `youtube_transcripts\combined` as sources. If NotebookLM reports a current size or source limit, lower `--combine-size` or `--max-combined-chars` and run the combine command again.

## Troubleshooting

- **`ffmpeg` is not recognised:** Install FFmpeg, reopen PowerShell, and make sure its `bin` folder is in `PATH`.
- **Caption download fails or returns no captions:** That is normal for some videos. The program proceeds to local transcription.
- **`CUDA` errors:** Use `--device cpu`. CUDA setup varies by graphics driver and hardware; CPU transcription remains supported.
- **YouTube blocks a request or asks you to sign in:** The program will log the error and continue. Do not try to circumvent access controls. Update yt-dlp first with `pip install --upgrade yt-dlp`; then retry legitimately accessible videos with `--retry-failed`.
- **A video is missing from discovery:** Available public videos are all the tool can discover. The tool automatically uses the channel's `/videos` listing and ignores unavailable entries rather than stopping the archive.
- **A short regular video was skipped:** Use `--include-shorts`; the default filter is intentionally conservative.
- **Need to find errors:** Open `youtube_transcripts\metadata\failed_videos.csv` and `youtube_transcripts\logs\transcribe.log`.

## Notes on scale

Eight hundred videos is a long-running local job, especially where audio must be transcribed. Use the three-video test first, keep the computer awake for the full run, and make sure there is adequate free disk space for temporary audio and final transcripts. Temporary audio is deleted by default after each video.
