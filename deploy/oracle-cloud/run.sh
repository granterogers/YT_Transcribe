#!/usr/bin/env bash
# systemd ExecStart wrapper for one transcription run (youtube or vimeo).
#
#   run.sh youtube      # reads /etc/yt-transcribe/youtube.env
#
# Reads its configuration from the environment (systemd supplies it via
# EnvironmentFile), clears a stale run lock left by a killed process, then
# execs transcribe_channel.py with the flags that worked locally.
#
# Never echoes VIMEO_ACCESS_TOKEN or any cookie content.
set -euo pipefail

UNIT="${1:-}"
[ -n "$UNIT" ] || { echo "usage: run.sh <youtube|vimeo>" >&2; exit 2; }

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
VENV="${VENV:-$REPO_ROOT/.venv}"
PY="$VENV/bin/python"
[ -x "$PY" ] || { echo "no interpreter at $PY -- run setup.sh" >&2; exit 1; }

: "${CHANNEL_URL:?CHANNEL_URL must be set (see /etc/yt-transcribe/$UNIT.env)}"
: "${COOKIES_FILE:?COOKIES_FILE must be set (see /etc/yt-transcribe/$UNIT.env)}"
[ -r "$COOKIES_FILE" ] || { echo "cookie file not readable: $COOKIES_FILE" >&2; exit 1; }

case "$UNIT" in
  vimeo)   OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/vimeo_transcripts}" ;;
  youtube) OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/youtube_transcripts}" ;;
  *)       OUTPUT_DIR="${OUTPUT_DIR:?OUTPUT_DIR must be set for custom unit '$UNIT'}" ;;
esac

# Long videos produce large intermediate audio; keep it off any small tmpfs.
export TMPDIR="${TMPDIR:-$REPO_ROOT/.tmp}"
mkdir -p "$TMPDIR" "$OUTPUT_DIR/database"

# Ampere A1 Always Free is 4 OCPU. Cap BLAS/torch threads so that running the
# YouTube and Vimeo units concurrently does not oversubscribe the CPU.
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-2}"
export MKL_NUM_THREADS="$OMP_NUM_THREADS"
export TOKENIZERS_PARALLELISM=false

# RunLock is a bare O_EXCL file holding the writer's pid. A SIGKILL (OOM,
# reboot) leaves it behind and every later run refuses to start. Clear it only
# when the recorded pid is genuinely gone -- never when a run is alive.
LOCK="$OUTPUT_DIR/database/.transcribe.lock"
if [ -f "$LOCK" ]; then
  LOCKPID="$(tr -cd '0-9' < "$LOCK" || true)"
  if [ -n "$LOCKPID" ] && kill -0 "$LOCKPID" 2>/dev/null; then
    echo "A run is already active (pid $LOCKPID) for $OUTPUT_DIR; refusing to start." >&2
    exit 1
  fi
  echo "Clearing stale run lock at $LOCK (pid '${LOCKPID:-unknown}' is not running)."
  rm -f "$LOCK"
fi

cd "$REPO_ROOT"
ARGS=( "$CHANNEL_URL"
       --cookies-file "$COOKIES_FILE"
       --output-dir   "$OUTPUT_DIR"
       --model        "${WHISPER_MODEL:-small}"
       --retry-failed
       --retries      "${RETRIES:-3}" )
[ "${DIARIZE:-1}" = "1" ] && ARGS+=( --diarize )
if [ "$UNIT" = "youtube" ]; then
  [ "${INCLUDE_SHORTS:-1}" = "1" ]      && ARGS+=( --include-shorts )
  [ "${INCLUDE_LIVESTREAMS:-1}" = "1" ] && ARGS+=( --include-livestreams )
fi
[ -n "${EXTRA_ARGS:-}" ] && read -r -a _extra <<< "$EXTRA_ARGS" && ARGS+=( "${_extra[@]}" )

echo "Starting $UNIT run: ${CHANNEL_URL} -> ${OUTPUT_DIR} (model ${WHISPER_MODEL:-small}, ${OMP_NUM_THREADS} threads)"
exec "$PY" -u transcribe_channel.py "${ARGS[@]}"
