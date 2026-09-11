# Unattended weekend run on Oracle Cloud (Always Free, Ampere A1)

Target: a single **VM.Standard.A1.Flex** shape, 4 OCPU / 24 GB RAM, `aarch64`, **no GPU**.
Goal: `transcribe_channel.py` runs for a whole weekend under systemd and survives
every SSH disconnection, reboot and transient network failure.

No application code changes are required for this deployment. `choose_device()`
already falls back to `cpu`/`int8`, and the Windows-only CUDA DLL registration
hack is inert outside `win32`.

---

## On Windows: start here

The deployment scripts are bash, and the steps they perform need `scp`, `rsync`
and `sqlite3` — so they run from WSL, not from `cmd` or PowerShell. WSL is also
what makes your existing files reachable: `/mnt/c` exposes the Windows drive, so
your `cookies.txt` and the `vimeo_transcripts` archive already on this machine
are picked up directly.

From a normal `cmd` prompt:

```bat
curl -L -o windows-setup.ps1 https://raw.githubusercontent.com/granterogers/YT_Transcribe/deploy/oracle-cloud/deploy/oracle-cloud/windows-setup.ps1
powershell -ExecutionPolicy Bypass -File windows-setup.ps1
```

It checks for WSL, installs Ubuntu if there is none (that part needs an elevated
prompt and possibly a reboot — it tells you exactly what to run), then inside
WSL installs git, jq, sqlite3, rsync and the OCI CLI and clones this repo.

Afterwards, everything happens in the WSL shell:

```bash
wsl
oci session authenticate --profile-name DEFAULT
cd ~/YT_Transcribe && bash deploy/oracle-cloud/provision.sh
bash deploy/oracle-cloud/launch-vimeo.sh
```

`launch-vimeo.sh` searches `/mnt/c/Users` for an existing
`vimeo_transcripts/database/transcripts.sqlite3` so your completed videos are
not redone. If it is somewhere unusual, point at it:

```bash
VIMEO_LOCAL_DIR=/mnt/c/path/to/vimeo_transcripts bash deploy/oracle-cloud/launch-vimeo.sh
```

---

## Quick start — two commands (macOS, Linux, or the WSL shell above)

Everything except Oracle authentication and handing over your own Vimeo
credentials is automated.

```bash
# once: prove who you are to Oracle (browser login, no key files to manage)
oci session authenticate --profile-name DEFAULT

# 1. create VCN, gateway, route, subnet and the A1.Flex instance, and let
#    cloud-init install ffmpeg, Node 22, the venv and the systemd unit
bash deploy/oracle-cloud/provision.sh

# 2. hand over the Vimeo folder URL, cookie file and token, then start the run
bash deploy/oracle-cloud/launch-vimeo.sh
```

`provision.sh` retries across every availability domain for two hours by
default when Always Free ARM capacity is unavailable (`CAPACITY_RETRY_MINUTES`
raises that). It is idempotent — re-running reuses what it already built and
never launches a second instance. It writes `~/.yt-transcribe-provision.env`,
which `launch-vimeo.sh` reads for the host and key.

`launch-vimeo.sh` prompts for the folder URL, the path to your local
`cookies.txt`, and the access token (typed invisibly). It offers to carry your
existing `vimeo_transcripts` database over — WAL-checkpointed first, so no
recent results are lost — runs the preflight, runs a two-video smoke test, and
only then enables the systemd unit. `SKIP_SMOKE=1` skips the trial run.

### The two things that are not automated, and why

1. **`oci session authenticate`** — this proves your Oracle identity. It is not
   something I can or should do for you.
2. **The Vimeo cookie file and access token** — these are your credentials. The
   scripts move them from your machine to your instance over SSH and check that
   they work; nothing ever reads their values back out, prints them, or writes
   them anywhere but the root-owned `0600` env file on the instance.

The sections below document what those two scripts do, and how to drive any of
it by hand.

---

## 0. Provision the instance (what `provision.sh` automates)

Oracle's Always Free ARM allowance is 4 OCPU / 24 GB across the tenancy, so ask
for all of it in one instance.

1. Console -> **Compute -> Instances -> Create instance**.
2. **Image:** Canonical **Ubuntu 24.04** (ships Python 3.12 and glibc 2.39 — both
   inside the range the wheels below need). Oracle Linux 9 also works.
3. **Shape:** *Ampere* -> `VM.Standard.A1.Flex` -> **4 OCPUs, 24 GB memory**.
4. **Boot volume:** raise from the 47 GB default to **100–200 GB**. Transcripts are
   tiny, but audio is downloaded per video into a temp dir and `--diarize`
   forces that download for *every* video.
5. **SSH keys:** upload your public key. Save the assigned public IP.
6. Networking: defaults are fine. The run only makes **outbound** HTTPS — no
   ingress rules beyond the default SSH port are needed.

> **"Out of host capacity"** is the common failure on Always Free ARM. It is a
> regional capacity limit, not an account problem. Either retry in a different
> availability domain / region, or upgrade to Pay As You Go (the Always Free
> ARM allowance still applies and stays free) which gets you a much better
> place in the queue.

Then:

```bash
ssh ubuntu@<public-ip>          # 'opc@' on Oracle Linux images
git clone https://github.com/granterogers/YT_Transcribe.git
cd YT_Transcribe
git checkout deploy/oracle-cloud
```

---

## 1. ARM64 dependency reality check

Checked against live PyPI for `linux-aarch64`. Everything installs from a
prebuilt wheel **except one package**:

| Package | aarch64 status |
|---|---|
| `yt-dlp`, `faster-whisper`, `resemblyzer`, `librosa`, `pooch` | pure-Python wheel — fine |
| `ctranslate2` | `manylinux_2_28_aarch64`, cp39–cp314 — **needs glibc ≥ 2.28** |
| `torch` | `manylinux_2_28_aarch64`, cp310–cp314 |
| `scikit-learn`, `numpy`, `scipy`, `numba`, `llvmlite`, `soxr`, `curl_cffi` | aarch64 wheels present |
| **`webrtcvad` 2.0.10** | **sdist only — compiles from C source** |

Two consequences, both handled by `setup.sh`:

- **`webrtcvad` must be built**, so `build-essential` + `python3-dev` are installed.
  It is a small C extension and builds in seconds. `resemblyzer` depends on it,
  so this only bites when `--diarize` is used — which is always, here.
  *Fallback if the build ever fails:* `pip install webrtcvad-wheels` (2.0.14 ships
  `manylinux2014_aarch64` wheels and imports as `webrtcvad`), then reinstall
  `resemblyzer` with `--no-deps`.
- **`torch` is installed from the CPU-only index first.** Torch's published
  metadata declares `nvidia-*` and `triton` dependencies for *any* Linux; on a
  GPU-less ARM box those are several gigabytes of packages that would fail or
  waste the boot volume. Installing from `https://download.pytorch.org/whl/cpu`
  ahead of `requirements.txt` pins the CPU build before `resemblyzer` can pull
  the generic one.

`setup.sh` also refuses to continue on glibc < 2.28 or on a Python outside
3.10–3.14, rather than letting pip fall through to a source build of
`ctranslate2` (which would not succeed).

---

## 2. Install (what cloud-init runs on first boot)

```bash
bash deploy/oracle-cloud/setup.sh
```

Installs `ffmpeg`, the build toolchain, **Node.js 22**, creates `.venv`, installs
CPU torch, then `requirements.txt`.

Node is not optional: yt-dlp needs a JS runtime for YouTube's signature and
"n challenge" solving. It only auto-enables `deno`, which is not installed here —
but no CLI flag is needed, because `channel_transcriber/youtube.py` already
hardcodes `"js_runtimes": {"node": {}}` in `_ydl()`. Node just has to exist.

---

## 3. Authentication material

Three secrets. **None of them should ever be pasted into a chat window, a
command line, a git commit, or a log.** `.gitignore` already excludes
`*cookies*.txt`, and this branch adds `deploy/**/*.env`.

Transfer the two cookie files straight from your machine over SSH:

```bash
# on your Windows machine (PowerShell, Git Bash or WSL)
ssh ubuntu@<public-ip> 'mkdir -p ~/secrets && chmod 700 ~/secrets'
scp youtube_cookies.txt ubuntu@<public-ip>:~/secrets/
scp vimeo_cookies.txt   ubuntu@<public-ip>:~/secrets/
ssh ubuntu@<public-ip> 'chmod 600 ~/secrets/*.txt'
```

Both must be Netscape format; the Vimeo one must contain `vimeo.com`-scoped
entries. `verify.sh` confirms the format and scope **without printing contents**.

The Vimeo API token goes into the env file on the server, edited on the server:

```bash
sudo nano /etc/yt-transcribe/vimeo.env     # set VIMEO_ACCESS_TOKEN=...
```

Create it at <https://developer.vimeo.com/apps> with **Public + Private** read
scopes. It is required for folder discovery specifically: yt-dlp has no "folder"
extractor, so `channel_transcriber/vimeo_api.py` enumerates the folder through
Vimeo's REST API. `verify.sh` validates it with a `GET /me` and reports only the
HTTP status.

---

## 4. Carry over existing progress (recommended)

State lives in `<output>/database/transcripts.sqlite3`. Copying it over means the
weekend run skips everything already `completed` instead of re-transcribing it.

**The database runs in WAL mode**, so the `-wal` and `-shm` sidecar files hold
recent commits. Copy all three, with no local run in flight, or you will silently
lose the most recent results:

```bash
# on your Windows machine, with no transcribe_channel.py running
rsync -av --progress \
  youtube_transcripts/database/transcripts.sqlite3* \
  youtube_transcripts/transcripts/ \
  ubuntu@<public-ip>:~/YT_Transcribe/youtube_transcripts/

rsync -av --progress \
  vimeo_transcripts/database/transcripts.sqlite3* \
  vimeo_transcripts/transcripts/ \
  ubuntu@<public-ip>:~/YT_Transcribe/vimeo_transcripts/
```

(If `rsync` isn't available on Windows, `scp -r` over the same paths works; keep
the `transcripts.sqlite3*` glob so the sidecars come too.)

`verify.sh` prints the per-status row counts it finds, so you can confirm the
carried-over state before starting.

To **start fresh** instead, simply don't copy anything — `Paths.create()` builds
the tree on first run.

---

## 5. Install and start the service (what `launch-vimeo.sh` automates)

```bash
bash deploy/oracle-cloud/install-service.sh
sudo nano /etc/yt-transcribe/youtube.env      # CHANNEL_URL + COOKIES_FILE
sudo nano /etc/yt-transcribe/vimeo.env        # CHANNEL_URL + COOKIES_FILE + token
bash deploy/oracle-cloud/verify.sh youtube vimeo
```

Smoke-test one unit before committing the weekend to it — set
`EXTRA_ARGS=--limit 3` in the env file, run it, confirm transcripts appear, then
remove the limit.

```bash
sudo systemctl start yt-transcribe@youtube
sudo systemctl start yt-transcribe@vimeo
journalctl -u yt-transcribe@youtube -f
```

`systemctl start` returns immediately and the process is owned by systemd, not
by your login session, so closing the laptop is safe. Add
`sudo systemctl enable yt-transcribe@youtube` if you also want it to come back
after an instance reboot.

The unit restarts on failure every 120 s (resumable state makes that free),
capped at 10 restarts/hour so a bad cookie file cannot hot-loop all weekend.
`systemctl stop` sends SIGINT, which the script handles with
*"Stopped safely. Run the same command again to continue."*

### Running both at once

4 OCPUs total. The env files default to `OMP_NUM_THREADS=2` each so the two
units split the box. If you run only one, set it to `4`.

### What the unit actually runs

`run.sh` assembles exactly the invocation that worked locally:

```
python transcribe_channel.py "<CHANNEL_URL>" --cookies-file "<COOKIES_FILE>" \
  --output-dir <...> --model small --retry-failed --retries 3 \
  --diarize [--include-shorts --include-livestreams]
```

plus two operational details: `TMPDIR` is pinned inside the repo (so large
intermediate audio never lands on a small `/tmp`), and a **stale run lock** left
by a killed process is cleared — but only after checking the recorded pid is
actually dead, so a live run is never stomped.

---

## 6. Monitoring over the weekend

```bash
systemctl status yt-transcribe@youtube
journalctl -u yt-transcribe@youtube --since '1 hour ago'
tail -f ~/YT_Transcribe/youtube_transcripts/logs/transcribe.log
ls ~/YT_Transcribe/youtube_transcripts/transcripts | wc -l

# progress by status, straight from the database
sqlite3 ~/YT_Transcribe/youtube_transcripts/database/transcripts.sqlite3 \
  'select status, count(*) from videos group by status;'
```

`metadata/*.csv` is rewritten after every video, so it is always current.

**Expected pace.** Caption-first keeps most YouTube videos cheap. The real CPU
cost is `--diarize`: it forces an audio download and a resemblyzer embedding
pass for *every* video, captions or not. On 4 Ampere cores expect roughly
0.1–0.3× realtime per video for diarization plus, for caption-less videos,
`small`/int8 Whisper at roughly 0.5–1.5× realtime. If the backlog looks too
large on Saturday morning, drop `WHISPER_MODEL` to `base` and restart the unit —
already-completed videos are not redone.

---

## 7. Retrieving results

```bash
rsync -av ubuntu@<public-ip>:~/YT_Transcribe/youtube_transcripts/transcripts/ ./youtube_transcripts/transcripts/
rsync -av ubuntu@<public-ip>:~/YT_Transcribe/youtube_transcripts/database/transcripts.sqlite3* ./youtube_transcripts/database/
```

Stop the service first if you want the database sidecars to be quiescent.

To build the NotebookLM-oriented combined sources on the server:

```bash
cd ~/YT_Transcribe && .venv/bin/python transcribe_channel.py --combine \
  --output-dir ~/YT_Transcribe/youtube_transcripts
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Another run appears active for this output folder` | A live run, or a lock `run.sh` decided not to clear. Check `systemctl status`; only delete `<output>/database/.transcribe.lock` after confirming nothing is running. |
| YouTube extraction fails with signature/n-challenge errors | Node missing or < 22. `node --version`; re-run `setup.sh`. |
| `VIMEO_ACCESS_TOKEN is not set` | The unit's env file lacks it, or you exported it in your shell instead of the file. systemd does not inherit your login environment. |
| Vimeo `GET /me` returns 401/403 in `verify.sh` | Token invalid or missing the Private scope. Regenerate it. |
| Vimeo 404 on the folder | Folder URL must look like `vimeo.com/user/<id>/folder/<id>`, and the token's account must have access. |
| `pip` tries to build `ctranslate2` from source | Python or glibc out of range — `setup.sh` should have stopped first. Use Ubuntu 22.04+ with Python 3.10–3.14. |
| `webrtcvad` build error | Missing `python3-dev`/`build-essential`, or use the `webrtcvad-wheels` fallback in §1. |
| `ModuleNotFoundError: pkg_resources` | `setuptools` got upgraded past 81. `pip install 'setuptools<81'`. |
| Unit stops after ~10 failures | `StartLimitBurst` tripped. Fix the underlying error, then `sudo systemctl reset-failed yt-transcribe@youtube` and start again. |
| Disk full | Enlarge the boot volume, or check nothing is accumulating under the repo `.tmp/` from a killed run. |
| `provision.sh` exits 75 | Every AD is out of Always Free ARM capacity. Raise `CAPACITY_RETRY_MINUTES=1440`, or try `REGION=us-phoenix-1`. |
| `provision.sh` says credentials expired | Session tokens last an hour. `oci session authenticate --profile-name DEFAULT` and re-run; it resumes from what already exists. |
| Bootstrap never finishes | `ssh -i ~/.ssh/yt-transcribe_oracle ubuntu@<ip> 'sudo tail -100 /var/log/yt-transcribe-bootstrap.log'`. Re-run it with `sudo bash /usr/local/bin/yt-bootstrap.sh` — it is idempotent. |
| Smoke test fails | Nothing is started, by design. The output names the failing stage: discovery (URL/token), cookies, or transcription. |
| `'oci' is not recognized` / `bash` opens WSL's installer on Windows | You are in `cmd`, not WSL. See **On Windows: start here** above. |
| `launch-vimeo.sh` says it found no existing database | It only searches `/mnt/c/Users` six levels deep. Pass `VIMEO_LOCAL_DIR=/mnt/c/...` explicitly. |
