<#
.SYNOPSIS
  One-time Windows bootstrap for the YT_Transcribe Oracle Cloud deployment.

.DESCRIPTION
  The deployment scripts are bash. Rather than maintain a second PowerShell
  port that can drift, this sets up WSL once and hands over to the bash path.
  WSL is also what makes the rest work: scp, rsync and sqlite3 are all needed,
  and /mnt/c gives direct access to the cookies.txt and the existing
  vimeo_transcripts archive already on this machine.

  Handles no secrets.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File windows-setup.ps1
#>
[CmdletBinding()]
param(
  [string]$Distro   = 'Ubuntu-24.04',
  [string]$RepoUrl  = 'https://github.com/granterogers/YT_Transcribe.git',
  [string]$Branch   = 'deploy/oracle-cloud'
)

$ErrorActionPreference = 'Stop'
# WSL's CLI emits UTF-16LE by default, which mangles every string comparison
# below. WSL_UTF8 makes it emit UTF-8.
$env:WSL_UTF8 = '1'

function Say  ($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Info ($m) { Write-Host "    $m" }
function Warn ($m) { Write-Host "    $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

Say 'Checking WSL'
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  Die 'wsl.exe not found. This needs Windows 10 2004+ or Windows 11.'
}

$distros = @()
try { $distros = @(wsl.exe --list --quiet 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } catch { }

if ($distros.Count -eq 0) {
  Warn 'No WSL distribution is installed.'
  $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $admin) {
    Write-Host @"

Installing a distribution needs an elevated prompt. Open PowerShell as
Administrator (Start -> type 'PowerShell' -> Run as administrator) and run:

    wsl --install -d $Distro

Windows may ask you to reboot. After it comes back, the Ubuntu window will ask
you to choose a UNIX username and password -- these are local to WSL and are
not your Oracle or Vimeo credentials; pick anything you will remember.

Then re-run this script (a normal prompt is fine from here on).

"@ -ForegroundColor Yellow
    exit 2
  }
  Say "Installing $Distro (this may require a reboot)"
  wsl.exe --install -d $Distro

  # The installer usually finishes the first-run user setup inline, so re-check
  # instead of making the operator run this script a second time for no reason.
  try { $distros = @(wsl.exe --list --quiet 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } catch { }
  if ($distros.Count -eq 0) {
    Write-Host @"

If Windows asked for a reboot, reboot now. On first launch Ubuntu will ask you
to create a UNIX username and password. Then re-run this script.

"@ -ForegroundColor Yellow
    exit 0
  }
  Info 'distribution installed; continuing'
}

# Prefer the requested distro, else whatever is installed.
if ($distros -contains $Distro) { $target = $Distro } else { $target = $distros[0] }
Info "using distribution: $target"

Say 'Checking the Linux user'
$who = (wsl.exe -d $target -- whoami 2>$null | Out-String).Trim()
if (-not $who) { Die "Could not run commands in '$target'. Open it once from the Start menu to finish its first-run setup, then re-run this script." }
if ($who -eq 'root') {
  Warn "'$target' has no default non-root user."
  Warn "Open the $target app once from the Start menu and create a user, then re-run. Running the deployment as root is not supported."
  exit 2
}
Info "running as: $who"

Say 'Preparing the WSL environment'
Info 'installing git, jq, sqlite3, rsync and the OCI CLI, then cloning the repo'
Info '(you may be asked for your WSL password for sudo)'

# Fetch wsl-setup.sh from the branch rather than assuming this file sits next
# to it -- this script is often downloaded on its own.
$raw = "https://raw.githubusercontent.com/$(($RepoUrl -replace '^https://github.com/','') -replace '\.git$','')/$Branch/deploy/oracle-cloud/wsl-setup.sh"
$local = Join-Path $PSScriptRoot 'wsl-setup.sh'

if (Test-Path $local) {
  $wslPath = (wsl.exe -d $target -- wslpath -a "$local" 2>$null | Out-String).Trim()
  wsl.exe -d $target -- bash "$wslPath"
} else {
  Info "fetching wsl-setup.sh from $Branch"
  wsl.exe -d $target -- bash -c "curl -fsSL '$raw' | REPO_URL='$RepoUrl' BRANCH='$Branch' bash"
}
if ($LASTEXITCODE -ne 0) { Die "WSL setup failed (exit $LASTEXITCODE). Scroll up for the failing step." }

Say 'Done'
Write-Host @"

Open your WSL shell and run the three commands it printed:

    wsl -d $target

    oci session authenticate --profile-name DEFAULT
    cd ~/YT_Transcribe && bash deploy/oracle-cloud/provision.sh
    bash deploy/oracle-cloud/launch-vimeo.sh

"@ -ForegroundColor Green
