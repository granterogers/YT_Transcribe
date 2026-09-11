#!/usr/bin/env bash
# Prepare a WSL (or any fresh Linux) shell to drive the Oracle deployment:
# git, jq, python, sqlite3, the OCI CLI, and a clone of this repo.
#
# Invoked by windows-setup.ps1, but safe to run by hand:
#   bash wsl-setup.sh
#
# Handles no secrets.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/granterogers/YT_Transcribe.git}"
BRANCH="${BRANCH:-deploy/oracle-cloud}"
REPO="${REPO:-$HOME/YT_Transcribe}"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }

say "System packages"
sudo apt-get update -y -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  git jq curl ca-certificates python3 python3-venv sqlite3 rsync openssh-client
info "ok"

say "OCI CLI"
export PATH="$HOME/bin:$HOME/lib/oracle-cli/bin:$PATH"
if command -v oci >/dev/null; then
  info "already installed: $(oci --version)"
else
  # The official installer; --accept-all-defaults keeps it non-interactive.
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" \
    -- --accept-all-defaults
  info "installed: $(oci --version)"
fi
# The installer edits .bashrc, but only for interactive shells; make sure a
# plain `bash -c` in this WSL distro finds it too.
grep -q 'oracle-cli/bin' "$HOME/.profile" 2>/dev/null || \
  printf '\nexport PATH="$HOME/bin:$HOME/lib/oracle-cli/bin:$PATH"\n' >> "$HOME/.profile"

say "Repository"
if [ -d "$REPO/.git" ]; then
  git -C "$REPO" fetch --all --prune -q
  info "updated $REPO"
else
  git clone -q "$REPO_URL" "$REPO"
  info "cloned to $REPO"
fi
git -C "$REPO" checkout -q "$BRANCH"
info "on branch $BRANCH"

cat <<EOF

$(printf '\033[1mReady.\033[0m') Run these three, in this WSL shell:

  1. oci session authenticate --profile-name DEFAULT
       A browser opens for the Oracle login. If it does not, copy the URL it
       prints into your Windows browser. Pick your home region when asked.

  2. cd $REPO && bash deploy/oracle-cloud/provision.sh
       Builds the network and the Ampere A1 instance, then waits for it to
       finish installing itself. 10-20 minutes, longer if it has to wait for
       Always Free ARM capacity.

  3. bash deploy/oracle-cloud/launch-vimeo.sh
       Asks for the Vimeo folder URL, your cookies.txt and the access token,
       then starts the weekend run.

  Your Windows files are visible here under /mnt/c -- e.g. a cookies.txt in
  Downloads is /mnt/c/Users/$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r\n' || echo '<you>')/Downloads/cookies.txt

EOF
