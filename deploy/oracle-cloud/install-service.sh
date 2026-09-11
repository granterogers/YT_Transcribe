#!/usr/bin/env bash
# Install the templated systemd unit so runs survive SSH disconnection.
#
#   bash deploy/oracle-cloud/install-service.sh
#
# Creates /etc/yt-transcribe/{youtube,vimeo}.env from the examples if absent.
# It never writes a secret: you fill those files in yourself afterwards.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
RUN_USER="${RUN_USER:-$(id -un)}"
[ "$RUN_USER" != "root" ] || { echo "Refusing to run the service as root. Set RUN_USER=<your login>." >&2; exit 1; }

echo "Installing yt-transcribe@.service"
echo "  user: $RUN_USER"
echo "  repo: $REPO_ROOT"

sudo install -d -m 0700 -o root -g root /etc/yt-transcribe
for unit in youtube vimeo; do
  dst="/etc/yt-transcribe/$unit.env"
  if [ -f "$dst" ]; then
    echo "  keeping existing $dst"
  else
    sudo install -m 0600 -o root -g root "$HERE/$unit.env.example" "$dst"
    echo "  created $dst from the example -- EDIT IT before starting the unit"
  fi
  # systemd reads EnvironmentFile as root, so 0600 root:root is right; the
  # service process itself never gets to read the file directly.
  sudo chmod 600 "$dst"; sudo chown root:root "$dst"
done

sed -e "s|__USER__|$RUN_USER|g" -e "s|__REPO__|$REPO_ROOT|g" \
    "$HERE/yt-transcribe@.service" | sudo tee /etc/systemd/system/'yt-transcribe@.service' >/dev/null
sudo systemctl daemon-reload

cat <<EOF

Installed. Next:
  1. sudo nano /etc/yt-transcribe/youtube.env      # URL + cookie path
     sudo nano /etc/yt-transcribe/vimeo.env        # URL + cookie path + VIMEO_ACCESS_TOKEN
  2. bash $HERE/verify.sh youtube vimeo            # preflight, prints no secrets
  3. sudo systemctl start yt-transcribe@youtube
     journalctl -u yt-transcribe@youtube -f        # live progress
  4. sudo systemctl enable yt-transcribe@youtube   # optional: restart after a reboot

  Status:  systemctl status yt-transcribe@youtube
  Stop:    sudo systemctl stop yt-transcribe@youtube     (clean SIGINT; resume by starting again)
EOF
