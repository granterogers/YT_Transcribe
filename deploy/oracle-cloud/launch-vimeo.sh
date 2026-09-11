#!/usr/bin/env bash
# Deliver the Vimeo credentials to the provisioned instance and start the
# weekend run. Run this from YOUR machine, from a clone of this repo.
#
#   bash deploy/oracle-cloud/launch-vimeo.sh
#
# Secret handling:
#   * The access token is typed invisibly, kept only in a shell variable, and
#     sent over the SSH channel on stdin -- never in argv (so it never appears
#     in `ps`), never echoed, never written to a local file, never logged.
#   * The cookie file is copied byte-for-byte by scp. Its contents are never
#     read into this script or printed.
set -euo pipefail

NAME="${NAME:-yt-transcribe}"
STATE="$HOME/.${NAME}-provision.env"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------- target ----
if [ -f "$STATE" ]; then
  # shellcheck disable=SC1090
  source "$STATE"
else
  die "No $STATE. Run provision.sh first, or set YT_IP / YT_SSH_KEY / YT_RUN_USER."
fi
IP="${YT_IP:?}"; KEY="${YT_SSH_KEY:?}"; USER_="${YT_RUN_USER:-ubuntu}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "$USER_@$IP")
say "Target"; info "$USER_@$IP  (key $KEY)"
"${SSH[@]}" true || die "Cannot SSH to $IP."
"${SSH[@]}" 'test -f /var/lib/yt-transcribe-bootstrap.done' \
  || die "The instance has not finished bootstrapping. Re-run provision.sh to wait for it."
REMOTE_REPO="$("${SSH[@]}" 'echo $HOME/YT_Transcribe')"

# ----------------------------------------------------------- collect ------
say "Vimeo configuration"

FOLDER_URL="${VIMEO_FOLDER_URL:-}"
while ! printf '%s' "$FOLDER_URL" | grep -qE 'vimeo\.com/user/[0-9]+/folder/[0-9]+'; do
  [ -n "$FOLDER_URL" ] && info "That doesn't look like a folder URL."
  info "Expected form: https://vimeo.com/user/<user id>/folder/<folder id>"
  read -r -p "    Vimeo folder URL: " FOLDER_URL
done

COOKIES_LOCAL="${VIMEO_COOKIES_FILE:-}"
while :; do
  [ -n "$COOKIES_LOCAL" ] || read -r -p "    Path to your local Vimeo cookies.txt: " COOKIES_LOCAL
  COOKIES_LOCAL="${COOKIES_LOCAL/#\~/$HOME}"
  if [ ! -f "$COOKIES_LOCAL" ]; then info "No such file: $COOKIES_LOCAL"; COOKIES_LOCAL=""; continue; fi
  # Browser extensions export JSON, but yt-dlp's --cookies only reads the
  # Netscape format and fails with an opaque parse error on JSON. Convert here.
  if [ "${COOKIES_LOCAL##*.}" = "json" ] || head -c 1 "$COOKIES_LOCAL" | grep -q '[[{]'; then
    info "that is a JSON export; converting to Netscape format"
    CONVERTED="$HOME/.cache/yt-transcribe/vimeo_cookies.txt"
    if python3 "$HERE/convert-cookies.py" "$COOKIES_LOCAL" "$CONVERTED"; then
      COOKIES_LOCAL="$CONVERTED"
    else
      info "conversion failed"; COOKIES_LOCAL=""; continue
    fi
  fi
  # Shape checks only -- no cookie value is ever read into a variable or shown.
  if ! grep -qi 'vimeo\.com' "$COOKIES_LOCAL"; then
    info "That file has no vimeo.com-scoped entries. Export cookies while signed in to Vimeo."; COOKIES_LOCAL=""; continue
  fi
  head -1 "$COOKIES_LOCAL" | grep -qi 'netscape' || info "  (warning: no '# Netscape HTTP Cookie File' header; continuing)"
  info "ok: $(basename "$COOKIES_LOCAL"), $(wc -c < "$COOKIES_LOCAL") bytes, $(grep -cv '^#' "$COOKIES_LOCAL") cookie lines"
  break
done

# The token stays in this variable only: never echoed, never written locally,
# never passed as an argument.
TOKEN="${VIMEO_ACCESS_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -n "${VIMEO_TOKEN_FILE:-}" ]; then
  TOKFILE="${VIMEO_TOKEN_FILE/#\~/$HOME}"
  [ -f "$TOKFILE" ] || die "VIMEO_TOKEN_FILE does not exist: $TOKFILE"
  TOKEN="$(tr -d ' \t\r\n' < "$TOKFILE")"
  info "token read from $TOKFILE"
fi
while [ -z "$TOKEN" ]; do
  info "If the token is already saved in a file, give its path; otherwise press"
  info "Enter and type the token itself (it will not be displayed)."
  read -r -p "    Path to token file (or Enter to type it): " TOKFILE
  if [ -n "$TOKFILE" ]; then
    TOKFILE="${TOKFILE/#\~/$HOME}"
    if [ -f "$TOKFILE" ]; then
      TOKEN="$(tr -d ' \t\r\n' < "$TOKFILE")"
      [ -n "$TOKEN" ] && info "token read from $TOKFILE" || info "That file is empty."
    else
      info "No such file: $TOKFILE"
    fi
  else
    printf '    Vimeo access token (Public + Private scopes; input hidden): '
    read -rs TOKEN; printf '\n'
    [ -n "$TOKEN" ] || info "Empty; try again."
  fi
done
info "token captured (${#TOKEN} characters; value not displayed)"

# ------------------------------------------------- carry over progress -----
# Where the *existing* local archive lives. Under WSL this is usually on the
# Windows drive (/mnt/c/...), not inside the WSL clone, so it is overridable and
# auto-discovered.
say "Existing progress"
if [ -n "${VIMEO_LOCAL_DIR:-}" ]; then
  LOCAL_VIMEO="${VIMEO_LOCAL_DIR/#\~/$HOME}"
elif [ -f "$REPO_ROOT/vimeo_transcripts/database/transcripts.sqlite3" ]; then
  LOCAL_VIMEO="$REPO_ROOT/vimeo_transcripts"
else
  LOCAL_VIMEO=""
  # Running inside WSL? The archive from the Windows machine is under /mnt/c.
  if [ -d /mnt/c/Users ]; then
    info "searching the Windows drive for an existing vimeo_transcripts archive ..."
    while IFS= read -r hit; do LOCAL_VIMEO="$(dirname "$(dirname "$hit")")"; break; done < <(
      find /mnt/c/Users -maxdepth 6 -type f -path '*/vimeo_transcripts/database/transcripts.sqlite3' 2>/dev/null)
    [ -n "$LOCAL_VIMEO" ] && info "found $LOCAL_VIMEO" || true
  fi
fi
LOCAL_DB="${LOCAL_VIMEO:+$LOCAL_VIMEO/database/transcripts.sqlite3}"

if [ -n "$LOCAL_DB" ] && [ -f "$LOCAL_DB" ]; then
  if command -v sqlite3 >/dev/null; then
    DONE="$(sqlite3 "$LOCAL_DB" 'select count(*) from videos where status="completed"' 2>/dev/null || echo '?')"
  else
    DONE="$(python3 -c "import sqlite3,sys;print(sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True).execute('select count(*) from videos where status=\"completed\"').fetchone()[0])" "$LOCAL_DB" 2>/dev/null || echo '?')"
  fi
  info "Found a local Vimeo database with $DONE completed video(s)."
  CARRY="${CARRY_OVER:-}"
  [ -n "$CARRY" ] || { read -r -p "    Copy it (and existing transcripts) to the instance so they are not redone? [Y/n] " CARRY; }
  case "${CARRY:-Y}" in
    [Nn]*) info "Starting fresh on the instance." ;;
    *)
      # WAL mode keeps recent commits in the -wal sidecar; checkpoint so a plain
      # file copy cannot silently strand them.
      if command -v sqlite3 >/dev/null; then
        sqlite3 "$LOCAL_DB" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null 2>&1 || true
      else
        python3 -c "import sqlite3,sys;c=sqlite3.connect(sys.argv[1]);c.execute('PRAGMA wal_checkpoint(TRUNCATE)');c.close()" "$LOCAL_DB" 2>/dev/null || true
      fi
      "${SSH[@]}" "mkdir -p '$REMOTE_REPO/vimeo_transcripts/database' '$REMOTE_REPO/vimeo_transcripts/transcripts'"
      info "copying database ..."
      scp -i "$KEY" -o StrictHostKeyChecking=accept-new \
        "$LOCAL_VIMEO"/database/transcripts.sqlite3* \
        "$USER_@$IP:$REMOTE_REPO/vimeo_transcripts/database/"
      if [ -d "$LOCAL_VIMEO/transcripts" ]; then
        info "copying existing transcripts ..."
        scp -i "$KEY" -r -o StrictHostKeyChecking=accept-new \
          "$LOCAL_VIMEO/transcripts/." \
          "$USER_@$IP:$REMOTE_REPO/vimeo_transcripts/transcripts/"
      fi
      info "carried over."
      ;;
  esac
else
  info "No existing Vimeo database found -- the instance will start fresh."
  info "If you have one, re-run with: VIMEO_LOCAL_DIR=/mnt/c/path/to/vimeo_transcripts bash $0"
fi

# ------------------------------------------------------ deliver secrets ----
say "Delivering credentials"
REMOTE_COOKIES="/home/$USER_/secrets/vimeo_cookies.txt"
"${SSH[@]}" "install -d -m 700 '/home/$USER_/secrets'"
scp -i "$KEY" -o StrictHostKeyChecking=accept-new "$COOKIES_LOCAL" "$USER_@$IP:$REMOTE_COOKIES"
"${SSH[@]}" "chmod 600 '$REMOTE_COOKIES'"
info "cookie file -> $REMOTE_COOKIES (0600)"

# The env file is built here and piped over stdin. Nothing sensitive is ever an
# argument to ssh, so it cannot show up in the remote host's process list.
printf '%s\n' \
  "# written by launch-vimeo.sh -- contains a secret; do not copy off this host" \
  "CHANNEL_URL=$FOLDER_URL" \
  "COOKIES_FILE=$REMOTE_COOKIES" \
  "WHISPER_MODEL=${WHISPER_MODEL:-small}" \
  "DIARIZE=1" \
  "RETRIES=3" \
  "OMP_NUM_THREADS=${OMP_NUM_THREADS:-4}" \
  "VIMEO_ACCESS_TOKEN=$TOKEN" \
  | "${SSH[@]}" "sudo -n install -d -m 700 -o root -g root /etc/yt-transcribe \
      && sudo -n tee /etc/yt-transcribe/vimeo.env >/dev/null \
      && sudo -n chmod 600 /etc/yt-transcribe/vimeo.env \
      && sudo -n chown root:root /etc/yt-transcribe/vimeo.env"
unset TOKEN
info "/etc/yt-transcribe/vimeo.env written (root:root 0600)"
# Only one unit is configured this weekend; make sure the unused YouTube
# template instance can't be started half-configured by accident.
"${SSH[@]}" "sudo -n rm -f /etc/yt-transcribe/youtube.env" || true

# ------------------------------------------------------------- preflight ---
say "Preflight"
"${SSH[@]}" "cd '$REMOTE_REPO' && bash deploy/oracle-cloud/verify.sh vimeo" \
  || die "Preflight failed (see above). Nothing was started."

# ------------------------------------------------------------ smoke test ---
if [ "${SKIP_SMOKE:-0}" != "1" ]; then
  say "Smoke test: two videos, in the foreground"
  info "proves discovery, cookies, token, captions, whisper and diarization all work"
  # Same env file and same run.sh the unit uses, just bounded to two videos.
  # The token is sourced into the process environment on the remote host; it is
  # never an argument, so it stays out of the process list.
  "${SSH[@]}" "sudo -n bash -c \"set -a; . /etc/yt-transcribe/vimeo.env; set +a; \
      export REPO_ROOT='$REMOTE_REPO' EXTRA_ARGS='--limit 2'; \
      exec runuser -u '$USER_' --preserve-environment -- \
        bash '$REMOTE_REPO/deploy/oracle-cloud/run.sh' vimeo\"" \
    || die "Smoke test failed (see above). The service was NOT started."
  info "smoke test passed"
fi

# ----------------------------------------------------------------- start ---
say "Starting the weekend run"
"${SSH[@]}" "sudo -n systemctl enable --now yt-transcribe@vimeo"
sleep 5
"${SSH[@]}" "systemctl --no-pager --full status yt-transcribe@vimeo | head -20" || true

cat <<EOF

$(printf '\033[1mRunning.\033[0m') It is owned by systemd, so you can close this terminal.

  live log     ssh -i $KEY $USER_@$IP 'journalctl -u yt-transcribe@vimeo -f'
  progress     ssh -i $KEY $USER_@$IP "sqlite3 $REMOTE_REPO/vimeo_transcripts/database/transcripts.sqlite3 'select status, count(*) from videos group by status;'"
  stop         ssh -i $KEY $USER_@$IP 'sudo systemctl stop yt-transcribe@vimeo'
  fetch results
               rsync -av -e 'ssh -i $KEY' $USER_@$IP:$REMOTE_REPO/vimeo_transcripts/transcripts/ ./vimeo_transcripts/transcripts/

EOF
