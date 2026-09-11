#!/usr/bin/env bash
# Preflight for the Oracle Cloud deployment. Run after setup.sh and after you
# have transferred the cookie files / exported VIMEO_ACCESS_TOKEN.
#
# This script NEVER prints, logs, or transmits a secret. Cookie files are only
# stat'ed and format-sniffed; the token is only tested for non-emptiness.
#
#   bash deploy/oracle-cloud/verify.sh                # environment only
#   bash deploy/oracle-cloud/verify.sh youtube vimeo  # also check those env files
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENV="${VENV:-$REPO_ROOT/.venv}"
FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "Host"
echo "  $(uname -m) | $(nproc) cpu | $(free -h | awk '/^Mem:/{print $2}') ram | glibc $(ldd --version | head -1 | awk '{print $NF}')"
df -h "$REPO_ROOT" | awk 'NR==2{printf "  disk: %s free of %s on %s\n", $4, $2, $6}'

say "System tools"
command -v ffmpeg >/dev/null && ok "ffmpeg: $(ffmpeg -version | head -1 | cut -d' ' -f1-3)" || bad "ffmpeg missing"
if command -v node >/dev/null; then
  NV="$(node -p 'process.versions.node.split(".")[0]')"
  [ "$NV" -ge 22 ] && ok "node $(node --version) (yt-dlp JS runtime)" || bad "node $(node --version) is older than 22"
else
  bad "node missing -- yt-dlp cannot solve YouTube's n-challenge"
fi

say "Python environment"
if [ -x "$VENV/bin/python" ]; then
  ok "venv at $VENV ($("$VENV/bin/python" -V))"
else
  bad "no venv at $VENV -- run setup.sh"; echo; exit 1
fi
"$VENV/bin/python" - <<'PY'
import importlib, sys
fail = False
for mod, why in [
    ("yt_dlp",        "video discovery / captions / audio"),
    ("faster_whisper","local transcription fallback"),
    ("ctranslate2",   "faster-whisper backend"),
    ("torch",         "resemblyzer embeddings"),
    ("resemblyzer",   "--diarize voice embeddings"),
    ("webrtcvad",     "resemblyzer VAD (sdist-only on aarch64: compiled here)"),
    ("sklearn",       "--diarize clustering"),
    ("requests",      "Vimeo folder API"),
    ("curl_cffi",     "Vimeo TLS impersonation"),
    ("pkg_resources", "needed by webrtcvad/resemblyzer; requires setuptools<81"),
]:
    try:
        m = importlib.import_module(mod)
        v = getattr(m, "__version__", "")
        print(f"  \033[32mPASS\033[0m import {mod} {v}  ({why})")
    except Exception as e:
        print(f"  \033[31mFAIL\033[0m import {mod}: {type(e).__name__}: {e}  ({why})")
        fail = True
if torch_ok := sys.modules.get("torch"):
    print(f"  \033[32mPASS\033[0m torch {torch_ok.__version__} threads={torch_ok.get_num_threads()} cuda={torch_ok.cuda.is_available()}")
sys.exit(1 if fail else 0)
PY
[ $? -eq 0 ] || FAIL=1

say "Device selection (expect cpu/int8 on this instance)"
( cd "$REPO_ROOT" && "$VENV/bin/python" -c \
  'from channel_transcriber.youtube import choose_device; d,c=choose_device("auto"); print(f"  chose {d}/{c}"); raise SystemExit(0 if d=="cpu" else 1)' ) \
  && ok "choose_device() falls back to CPU cleanly" || bad "choose_device() did not select cpu"

# ------------------------------------------------------------ secrets ------
# Existence and shape only. Values are never read into a variable or printed.
check_cookie() {  # $1 = path, $2 = expected domain substring
  local f="$1" dom="$2"
  [ -n "$f" ] || { warn "no cookie path configured"; return; }
  if [ ! -f "$f" ]; then bad "cookie file not found: $f"; return; fi
  local perm; perm="$(stat -c '%a' "$f")"
  local lines; lines="$(grep -cv '^#' "$f" 2>/dev/null || echo 0)"
  head -1 "$f" | grep -qi 'netscape' && ok "$f: Netscape header present" || warn "$f: missing '# Netscape HTTP Cookie File' header"
  grep -qi -- "$dom" "$f" && ok "$f: contains $dom-scoped entries" || bad "$f: no $dom entries found"
  [ "$lines" -gt 0 ] && ok "$f: $lines cookie line(s), $(stat -c %s "$f") bytes" || bad "$f: no cookie lines"
  [ "$perm" = "600" ] && ok "$f: permissions 600" || warn "$f: permissions $perm -- run: chmod 600 '$f'"
}

for unit in "$@"; do
  say "Service env: $unit"
  ENVF="/etc/yt-transcribe/$unit.env"
  if [ ! -f "$ENVF" ]; then bad "$ENVF missing -- copy from deploy/oracle-cloud/$unit.env.example"; continue; fi
  ok "$ENVF present (mode $(stat -c '%a' "$ENVF"))"
  # shellcheck disable=SC1090
  set -a; source "$ENVF"; set +a
  [ -n "${CHANNEL_URL:-}" ] && ok "CHANNEL_URL set: $CHANNEL_URL" || bad "CHANNEL_URL not set in $ENVF"
  case "$unit" in
    youtube) check_cookie "${COOKIES_FILE:-}" "youtube.com" ;;
    vimeo)
      check_cookie "${COOKIES_FILE:-}" "vimeo.com"
      if [ -n "${VIMEO_ACCESS_TOKEN:-}" ]; then
        ok "VIMEO_ACCESS_TOKEN is set (${#VIMEO_ACCESS_TOKEN} chars; value not shown)"
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
          -H "Authorization: Bearer $VIMEO_ACCESS_TOKEN" https://api.vimeo.com/me)"
        [ "$code" = "200" ] && ok "Vimeo API accepts the token (GET /me -> 200)" \
                            || bad "Vimeo API returned HTTP $code for GET /me -- token invalid or missing Private scope"
      else
        bad "VIMEO_ACCESS_TOKEN not set in $ENVF -- folder discovery will fail"
      fi ;;
  esac
  unset CHANNEL_URL COOKIES_FILE VIMEO_ACCESS_TOKEN
done

say "Existing progress"
for d in youtube_transcripts vimeo_transcripts; do
  DB="$REPO_ROOT/$d/database/transcripts.sqlite3"
  if [ -f "$DB" ]; then
    "$VENV/bin/python" - "$DB" "$d" <<'PY'
import sqlite3, sys
db, name = sys.argv[1], sys.argv[2]
try:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    rows = dict(con.execute("select status, count(*) from videos group by status").fetchall())
    summary = ", ".join(f"{k}={v}" for k, v in sorted(rows.items())) or "no rows yet"
    print(f"  \033[32mPASS\033[0m {name}: {summary}")
except Exception as e:
    print(f"  \033[31mFAIL\033[0m {name}: unreadable database: {e}")
PY
    LOCK="$REPO_ROOT/$d/database/.transcribe.lock"
    [ -f "$LOCK" ] && warn "$d: stale run lock present (pid $(cat "$LOCK" 2>/dev/null)); run.sh clears it if the pid is dead"
  else
    warn "$d: no database yet -- this side will start fresh"
  fi
done

say "Result"
[ "$FAIL" = 0 ] && { printf '  \033[32mAll checks passed.\033[0m\n\n'; exit 0; }
printf '  \033[31mOne or more checks failed -- fix them before starting the service.\033[0m\n\n'; exit 1
