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
  # The installer's own location has moved between releases, so find the binary
  # rather than assuming where it landed.
  if ! command -v oci >/dev/null; then
    FOUND="$(find "$HOME" -maxdepth 4 -type f -name oci -perm -u+x 2>/dev/null | head -1)"
    [ -n "$FOUND" ] || { echo "OCI CLI install finished but no 'oci' binary was found." >&2; exit 1; }
    export PATH="$(dirname "$FOUND"):$PATH"
  fi
  info "installed: $(oci --version)"
fi
OCI_BIN_DIR="$(dirname "$(command -v oci)")"
# The installer edits .bashrc only, which a login shell reads indirectly and a
# `bash -c` never reads at all. Put it in both so every shell finds it.
for rc in "$HOME/.profile" "$HOME/.bashrc"; do
  [ -f "$rc" ] || touch "$rc"
  grep -q 'oracle-cli/bin' "$rc" 2>/dev/null || \
    printf '\nexport PATH="$HOME/bin:$HOME/lib/oracle-cli/bin:%s:$PATH"\n' "$OCI_BIN_DIR" >> "$rc"
done

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

$(printf '\033[1mReady.\033[0m') Run these four, one at a time, in this WSL shell:

  0. source ~/.profile
       Required: the OCI CLI was just added to your PATH, and this shell was
       started before that happened. Check it worked with:  oci --version

  1. oci session authenticate --profile-name DEFAULT --region <your home region>
       e.g. --region eu-frankfurt-1. Name it explicitly: the menu lists 85
       regions across every Oracle realm, and choosing one your tenancy does
       not live in sends you to a sign-in page that cannot find your account.
       Your home region is shown top-right when you log in at cloud.oracle.com.
       A browser opens; if it does not (WSL often cannot launch one), copy the
       printed URL into your Windows browser yourself.

       No Oracle Cloud account yet? Sign up first at oracle.com/cloud/free --
       see deploy/oracle-cloud/README.md, "Prerequisite: an Oracle Cloud
       account".

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
