#!/usr/bin/env bash
# Provision an Oracle Cloud "Always Free" Ampere A1 (aarch64, CPU-only) instance
# to run transcribe_channel.py unattended.
#
# Idempotent: safe to re-run. Handles Ubuntu (apt) and Oracle Linux (dnf).
# Handles NO secrets -- cookie files and VIMEO_ACCESS_TOKEN are placed by you,
# separately, and only checked for existence by verify.sh.
#
#   bash deploy/oracle-cloud/setup.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENV="${VENV:-$REPO_ROOT/.venv}"
NODE_MAJOR="${NODE_MAJOR:-22}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- sanity ----
say "Host check"
ARCH="$(uname -m)"
echo "  arch:  $ARCH"
echo "  cpus:  $(nproc)"
echo "  mem:   $(free -h | awk '/^Mem:/{print $2}')"
echo "  glibc: $(ldd --version | head -1 | awk '{print $NF}')"
[ "$ARCH" = "aarch64" ] || echo "  NOTE: expected aarch64 (Ampere A1); continuing anyway."

# ctranslate2 and torch ship manylinux_2_28 aarch64 wheels -> glibc >= 2.28.
GLIBC="$(ldd --version | head -1 | awk '{print $NF}')"
awk -v v="$GLIBC" 'BEGIN{split(v,a,"."); if (a[1]*1000+a[2] < 2028) exit 1}' \
  || die "glibc $GLIBC is older than 2.28; ctranslate2/torch aarch64 wheels will not install. Use Ubuntu 22.04+ or Oracle Linux 8+."

if command -v apt-get >/dev/null 2>&1; then PKG=apt; else PKG=dnf; fi
echo "  pkg:   $PKG"

# ------------------------------------------------------- system packages ----
say "System packages (ffmpeg, build toolchain, Python venv)"
# build toolchain is genuinely required: webrtcvad (a resemblyzer dependency,
# pulled in by --diarize) is sdist-only on PyPI and must compile a small C
# extension on aarch64. Everything else installs from prebuilt wheels.
if [ "$PKG" = apt ]; then
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ffmpeg git curl ca-certificates \
    python3 python3-venv python3-dev \
    build-essential pkg-config libsndfile1
else
  sudo dnf install -y oracle-epel-release-el"$(rpm -E %rhel)" 2>/dev/null || sudo dnf install -y epel-release || true
  sudo dnf install -y ffmpeg-free ffmpeg || true
  sudo dnf install -y git curl ca-certificates python3 python3-devel python3-pip gcc gcc-c++ make pkgconfig libsndfile
fi
command -v ffmpeg >/dev/null || die "ffmpeg not on PATH after install. On Oracle Linux enable EPEL/RPM Fusion, or rely on the imageio-ffmpeg fallback."
echo "  ffmpeg: $(ffmpeg -version | head -1)"

# -------------------------------------------------------------- Node.js ----
# yt-dlp needs a JS runtime to solve YouTube's signature / "n challenge".
# yt-dlp only auto-enables deno; this project pins node explicitly in
# channel_transcriber/youtube.py (_ydl -> "js_runtimes": {"node": {}}),
# so node is the runtime that must exist. No CLI flag is needed.
say "Node.js >= $NODE_MAJOR (yt-dlp JS runtime)"
node_ok() { command -v node >/dev/null 2>&1 && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge "$NODE_MAJOR" ]; }
if node_ok; then
  echo "  already present: $(node --version)"
else
  if [ "$PKG" = apt ]; then
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  else
    curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
    sudo dnf install -y nodejs
  fi
fi
node_ok || die "Node >= $NODE_MAJOR still not available; yt-dlp will fail on YouTube extraction."
echo "  node: $(node --version)"

# ---------------------------------------------------------- python venv ----
say "Python virtualenv at $VENV"
PYBIN="$(command -v python3.12 || command -v python3.11 || command -v python3)"
echo "  interpreter: $PYBIN ($("$PYBIN" -V))"
# ctranslate2 aarch64 wheels cover cp39-cp314; torch aarch64 covers cp310-cp314.
"$PYBIN" -c 'import sys; raise SystemExit(0 if (3,10) <= sys.version_info < (3,15) else 1)' \
  || die "Python $("$PYBIN" -V) is outside 3.10-3.14; torch has no linux-aarch64 wheel for it."
[ -d "$VENV" ] || "$PYBIN" -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip wheel

# torch is installed from the CPU-only index FIRST so that the generic PyPI
# metadata (which declares nvidia-*/triton CUDA dependencies) never gets a
# chance to resolve. This instance has no GPU and the CUDA payload is several
# gigabytes that would not even install on aarch64.
say "PyTorch (CPU-only build) -- pinned ahead of resemblyzer's torch dependency"
python -m pip install --index-url https://download.pytorch.org/whl/cpu torch

say "Project requirements"
python -m pip install -r "$REPO_ROOT/requirements.txt"

# Whisper on 4 Ampere OCPUs: int8 on CPU is chosen automatically by
# choose_device(); no CUDA path is touched.
say "Done. Next: bash deploy/oracle-cloud/verify.sh"
