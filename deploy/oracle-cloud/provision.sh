#!/usr/bin/env bash
# Provision the whole Oracle Cloud Always Free stack from the CLI: VCN, internet
# gateway, route rule, public subnet, and a VM.Standard.A1.Flex instance
# (4 OCPU / 24 GB, aarch64) that bootstraps itself via cloud-init.
#
#   bash deploy/oracle-cloud/provision.sh
#
# Idempotent: re-running reuses any resource it already created (matched by
# display name) and will not launch a second instance.
#
# Handles NO secrets. The Vimeo cookie file and access token are delivered
# afterwards by launch-vimeo.sh, straight from your machine to the instance.
set -euo pipefail

# ------------------------------------------------------------- settings ----
NAME="${NAME:-yt-transcribe}"
REGION="${REGION:-}"                       # blank = whatever the OCI profile says
OCPUS="${OCPUS:-4}"
MEMORY_GB="${MEMORY_GB:-24}"
# Always Free gives 200 GB of block storage in total across the tenancy.
# 150 leaves headroom; transcripts are tiny but --diarize downloads audio for
# every video into TMPDIR.
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-150}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/${NAME}_oracle}"
REPO_URL="${REPO_URL:-https://github.com/granterogers/YT_Transcribe.git}"
BRANCH="${BRANCH:-deploy/oracle-cloud}"
RUN_USER="${RUN_USER:-ubuntu}"
# "Out of host capacity" is the normal Always Free ARM experience. Keep trying.
CAPACITY_RETRY_MINUTES="${CAPACITY_RETRY_MINUTES:-120}"
CAPACITY_RETRY_INTERVAL="${CAPACITY_RETRY_INTERVAL:-60}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$HOME/.${NAME}-provision.env"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

oci_() { oci --region "${REGION_ARG[@]}" "$@"; }

# ---------------------------------------------------------- prequisites ----
say "Prerequisites"
command -v jq >/dev/null || die "jq is required. Install it (apt install jq / brew install jq) and re-run."
# The OCI installer puts the CLI here but only wires it into interactive shells;
# look before concluding it is missing and installing a second copy.
export PATH="$HOME/bin:$HOME/lib/oracle-cli/bin:$PATH"
if ! command -v oci >/dev/null; then
  info "OCI CLI not found; installing to ~/lib/oracle-cli (non-interactive)."
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" \
    -- --accept-all-defaults >/dev/null || die "OCI CLI install failed. See https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm"
  export PATH="$HOME/bin:$HOME/lib/oracle-cli/bin:$PATH"
fi
command -v oci >/dev/null || die "oci still not on PATH. Open a new shell (the installer edits your rc file) and re-run."
info "oci: $(oci --version)"

CONFIG="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
PROFILE="${OCI_CLI_PROFILE:-DEFAULT}"
if [ ! -f "$CONFIG" ]; then
  cat >&2 <<EOF

No OCI CLI configuration at $CONFIG.

Authenticate once (browser-based, no API key files to manage):

    oci session authenticate --profile-name $PROFILE${REGION:+ --region $REGION}

Then re-run this script. This is the one step that needs you: it proves your
Oracle identity, and it is not something I can or should do on your behalf.

EOF
  exit 1
fi

REGION_ARG=(); [ -n "$REGION" ] && REGION_ARG=("$REGION") || REGION_ARG=("$(awk -v p="[$PROFILE]" '$0==p{f=1;next} /^\[/{f=0} f&&/^region/{print $2; exit}' FS=' *= *' "$CONFIG")")
[ -n "${REGION_ARG[0]}" ] || die "Could not determine a region. Set REGION=<e.g. us-ashburn-1>."
info "region: ${REGION_ARG[0]}  profile: $PROFILE"

TENANCY="$(awk -v p="[$PROFILE]" '$0==p{f=1;next} /^\[/{f=0} f&&/^tenancy/{print $2; exit}' FS=' *= *' "$CONFIG")"
COMPARTMENT="${COMPARTMENT_ID:-$TENANCY}"
[ -n "$COMPARTMENT" ] || die "Could not read the tenancy OCID from $CONFIG. Set COMPARTMENT_ID=<ocid>."
info "compartment: $COMPARTMENT"

# Session tokens expire after an hour; fail now with a clear message rather
# than halfway through creating networking.
if ! oci_ iam availability-domain list -c "$COMPARTMENT" >/dev/null 2>&1; then
  die "OCI credentials are not working or have expired. Re-run: oci session authenticate --profile-name $PROFILE"
fi

# --------------------------------------------------------------- ssh key ---
say "SSH key"
if [ -f "$SSH_KEY" ]; then
  info "reusing $SSH_KEY"
else
  mkdir -p "$(dirname "$SSH_KEY")"; chmod 700 "$(dirname "$SSH_KEY")"
  ssh-keygen -t ed25519 -N '' -C "$NAME" -f "$SSH_KEY" >/dev/null
  info "generated $SSH_KEY"
fi
chmod 600 "$SSH_KEY"; PUBKEY="$(cat "$SSH_KEY.pub")"

# ------------------------------------------------------------ networking ---
# Every lookup is by display name so the script is safely re-runnable.
find_one() { jq -r --arg n "$1" '[.data[]? | select(."display-name"==$n) | select(."lifecycle-state"|test("^(AVAILABLE|PROVISIONING|ACTIVE)$"))][0].id // empty'; }

say "Networking"
VCN="$(oci_ network vcn list -c "$COMPARTMENT" --all 2>/dev/null | find_one "$NAME-vcn")"
if [ -z "$VCN" ]; then
  VCN="$(oci_ network vcn create -c "$COMPARTMENT" --display-name "$NAME-vcn" \
          --cidr-blocks '["10.0.0.0/16"]' --dns-label "${NAME//-/}" \
          --wait-for-state AVAILABLE --query 'data.id' --raw-output)"
  info "created VCN $VCN"
else info "reusing VCN $VCN"; fi

IGW="$(oci_ network internet-gateway list -c "$COMPARTMENT" --vcn-id "$VCN" --all 2>/dev/null | find_one "$NAME-igw")"
if [ -z "$IGW" ]; then
  IGW="$(oci_ network internet-gateway create -c "$COMPARTMENT" --vcn-id "$VCN" \
          --display-name "$NAME-igw" --is-enabled true \
          --wait-for-state AVAILABLE --query 'data.id' --raw-output)"
  info "created internet gateway $IGW"
else info "reusing internet gateway $IGW"; fi

# A CLI-created VCN's default route table starts empty; without this rule the
# instance boots with a public IP but no egress, and cloud-init hangs on apt.
RT="$(oci_ network vcn get --vcn-id "$VCN" --query 'data."default-route-table-id"' --raw-output)"
if ! oci_ network route-table get --rt-id "$RT" --query 'data."route-rules"' | grep -q '0.0.0.0/0'; then
  oci_ network route-table update --rt-id "$RT" --force \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW\"}]" >/dev/null
  info "added default route -> internet gateway"
else info "default route already present"; fi

SUBNET="$(oci_ network subnet list -c "$COMPARTMENT" --vcn-id "$VCN" --all 2>/dev/null | find_one "$NAME-subnet")"
if [ -z "$SUBNET" ]; then
  SUBNET="$(oci_ network subnet create -c "$COMPARTMENT" --vcn-id "$VCN" \
            --display-name "$NAME-subnet" --cidr-block 10.0.0.0/24 --dns-label sub \
            --prohibit-public-ip-on-vnic false \
            --wait-for-state AVAILABLE --query 'data.id' --raw-output)"
  info "created public subnet $SUBNET"
else info "reusing subnet $SUBNET"; fi
# The VCN's default security list already permits inbound TCP 22 and all
# egress, which is exactly what this run needs -- nothing else is opened.

# ----------------------------------------------------------------- image ---
say "Image"
IMAGE="$(oci_ compute image list -c "$COMPARTMENT" \
          --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
          --shape "VM.Standard.A1.Flex" --sort-by TIMECREATED --sort-order DESC \
          --query 'data[0].id' --raw-output 2>/dev/null || true)"
[ -n "$IMAGE" ] && [ "$IMAGE" != "null" ] || die "No Ubuntu 24.04 aarch64 image found for VM.Standard.A1.Flex in ${REGION_ARG[0]}."
info "$(oci_ compute image get --image-id "$IMAGE" --query 'data."display-name"' --raw-output)"

# ------------------------------------------------------------ user data ----
say "cloud-init"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
sed -e "s|__REPO_URL__|$REPO_URL|g" -e "s|__BRANCH__|$BRANCH|g" -e "s|__RUN_USER__|$RUN_USER|g" \
    "$HERE/cloud-init.yaml" > "$WORK/user-data.yaml"
grep -q '__' "$WORK/user-data.yaml" && die "cloud-init template still has unsubstituted placeholders."
jq -n --arg k "$PUBKEY" --arg u "$(base64 < "$WORK/user-data.yaml" | tr -d '\n')" \
   '{ssh_authorized_keys:$k, user_data:$u}' > "$WORK/metadata.json"
info "repo $REPO_URL @ $BRANCH, bootstrapping as $RUN_USER"

# ------------------------------------------------------------- instance ----
say "Instance"
EXISTING="$(oci_ compute instance list -c "$COMPARTMENT" --all 2>/dev/null \
  | jq -r --arg n "$NAME" '[.data[]? | select(."display-name"==$n) | select(."lifecycle-state"|test("^(RUNNING|PROVISIONING|STARTING)$"))][0].id // empty')"

if [ -n "$EXISTING" ]; then
  INSTANCE="$EXISTING"; info "reusing existing instance $INSTANCE"
else
  mapfile -t ADS < <(oci_ iam availability-domain list -c "$COMPARTMENT" | jq -r '.data[].name')
  [ "${#ADS[@]}" -gt 0 ] || die "No availability domains returned."
  info "availability domains: ${ADS[*]}"

  DEADLINE=$(( $(date +%s) + CAPACITY_RETRY_MINUTES * 60 ))
  INSTANCE=""
  while :; do
    for AD in "${ADS[@]}"; do
      info "launching in $AD ..."
      set +e
      OUT="$(oci_ compute instance launch -c "$COMPARTMENT" \
              --availability-domain "$AD" --display-name "$NAME" \
              --shape VM.Standard.A1.Flex \
              --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
              --image-id "$IMAGE" --subnet-id "$SUBNET" --assign-public-ip true \
              --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
              --metadata "file://$WORK/metadata.json" \
              --wait-for-state RUNNING 2>&1)"
      RC=$?
      set -e
      if [ $RC -eq 0 ]; then
        INSTANCE="$(printf '%s' "$OUT" | jq -r '.data.id' 2>/dev/null)"
        [ -n "$INSTANCE" ] && [ "$INSTANCE" != null ] && { info "launched $INSTANCE"; break; }
      fi
      if printf '%s' "$OUT" | grep -qiE 'out of host capacity|outofcapacity|insufficient .* capacity'; then
        info "  $AD has no Always Free ARM capacity right now"
      else
        printf '%s\n' "$OUT" >&2
        die "Launch failed for a reason other than capacity (see above)."
      fi
    done
    [ -n "$INSTANCE" ] && break
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
      cat >&2 <<EOF

Every availability domain in ${REGION_ARG[0]} reported no Always Free ARM
capacity for ${CAPACITY_RETRY_MINUTES} minutes. This is a regional capacity
limit, not a problem with your account. Options:

  * Keep retrying:  CAPACITY_RETRY_MINUTES=1440 bash $0
  * Try another region:  REGION=us-phoenix-1 bash $0
  * Upgrade to Pay As You Go. The Always Free ARM allowance still applies and
    stays free, but PAYG tenancies get far better placement in the queue.

EOF
      exit 75
    fi
    info "all ADs full; retrying in ${CAPACITY_RETRY_INTERVAL}s (until $(date -d "@$DEADLINE" '+%H:%M' 2>/dev/null || echo deadline))"
    sleep "$CAPACITY_RETRY_INTERVAL"
  done
fi

IP="$(oci_ compute instance list-vnics --instance-id "$INSTANCE" --query 'data[0]."public-ip"' --raw-output)"
[ -n "$IP" ] && [ "$IP" != null ] || die "Instance is running but has no public IP."

cat > "$STATE" <<EOF
# written by provision.sh $(date -Is)
YT_INSTANCE_ID=$INSTANCE
YT_IP=$IP
YT_SSH_KEY=$SSH_KEY
YT_RUN_USER=$RUN_USER
YT_REGION=${REGION_ARG[0]}
EOF
chmod 600 "$STATE"

say "Instance is up"
info "public IP : $IP"
info "ssh       : ssh -i $SSH_KEY $RUN_USER@$IP"
info "state file: $STATE"

# ------------------------------------------------------------ bootstrap ----
say "Waiting for first-boot bootstrap (installing ffmpeg, Node 22, torch, whisper)"
info "this typically takes 5-12 minutes on 4 Ampere cores"
SSH=(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "$RUN_USER@$IP")
for i in $(seq 1 120); do
  if "${SSH[@]}" 'test -f /var/lib/yt-transcribe-bootstrap.done' 2>/dev/null; then
    say "Bootstrap complete"
    "${SSH[@]}" 'tail -n 5 /var/log/yt-transcribe-bootstrap.log' 2>/dev/null || true
    break
  fi
  if "${SSH[@]}" 'test -f /var/lib/yt-transcribe-bootstrap.failed' 2>/dev/null; then
    echo; "${SSH[@]}" 'cat /var/lib/yt-transcribe-bootstrap.failed; tail -n 40 /var/log/yt-transcribe-bootstrap.log' || true
    die "Bootstrap failed on the instance. Fix the cause, then: ssh -i $SSH_KEY $RUN_USER@$IP 'sudo bash /usr/local/bin/yt-bootstrap.sh'"
  fi
  if [ "$i" -ge 120 ]; then
    die "Bootstrap did not finish in 30 minutes. Check: ssh -i $SSH_KEY $RUN_USER@$IP 'sudo tail -100 /var/log/yt-transcribe-bootstrap.log'"
  fi
  printf '.'; sleep 15
done

cat <<EOF

$(printf '\033[1m')Next and final step$(printf '\033[0m') -- deliver the Vimeo credentials and start the run:

    bash $HERE/launch-vimeo.sh

It reads $STATE for the host, asks you for the folder URL, the path to your
local Vimeo cookies.txt, and the access token (typed invisibly, never echoed),
copies them straight to the instance over SSH, runs the preflight, and starts
the systemd unit.
EOF
