#!/usr/bin/env bash
# Encrypted backups of what a node or peg signer can't rebuild from the
# chains: the signer's key, signing log, signer set, deposit registry,
# refund approvals and settings, the node's identity (NodeID), and the
# service configuration.
#
#   sudo ./backup.sh setup AGE_RECIPIENT...   # scheduled backups; one now
#   sudo ./backup.sh run                      # back up now
#   sudo ./backup.sh list
#        ./backup.sh verify FILE IDENTITY     # on another machine: prove it restores
#
# Backups are encrypted with age (https://age-encryption.org) to the
# recipients' public keys (age1... or an ssh-ed25519 public key). This
# server holds no decryption key, so it can write backups but never read
# them. Keep the matching identities (private keys) offline, and more than
# one person's, so losing one laptop loses nothing.
#
# A signer is backed up hourly, a node daily, into /var/backups/bridge-operator
# (newest KEEP kept). If /etc/bridge-operator/backup-offsite holds an rsync
# destination (user@host:dir), each backup is copied there too.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"

RECIPIENTS=$CONF_DIR/backup-recipients
OFFSITE=$CONF_DIR/backup-offsite
# Where setup installs this script, so the timer doesn't depend on where
# the repository was checked out.
INSTALLED=/usr/local/lib/bridge-operator
# Tests only: skip systemctl in a container without systemd.
TEST_ONLY=${BRIDGE_OPERATOR_TEST_ONLY_SKIP_BUILDS:-0}

usage() { sed -n '7,11p' "$0" | sed 's/^# \{0,1\}//' >&2; }

need_root() { [[ $EUID -eq 0 ]] || die "run as root: sudo ./backup.sh $1"; }

cmd_setup() {
  need_root setup
  [[ $# -ge 1 ]] || { usage; exit 2; }
  load_install_conf
  local r
  for r in "$@"; do
    [[ $r =~ ^age1[0-9a-z]{58}$ || $r =~ ^ssh-(ed25519|rsa)\  ]] ||
      die "'$r' is not an age recipient (age1...) or an SSH public key (quote it: \"ssh-ed25519 AAAA...\")"
  done
  command -v age >/dev/null || die "age is not installed (install.sh installs it)"
  install -d -m 0755 "$CONF_DIR"
  install -d -m 0700 "$BACKUP_DIR"
  printf '%s\n' "$@" >"$RECIPIENTS.new"
  chmod 0644 "$RECIPIENTS.new"
  mv -f "$RECIPIENTS.new" "$RECIPIENTS"

  install -d -m 0755 "$INSTALLED" "$INSTALLED/lib" "$INSTALLED/chains"
  install -m 0755 "$REPO_DIR/backup.sh" "$INSTALLED/backup.sh"
  install -m 0644 "$REPO_DIR/lib/common.sh" "$INSTALLED/lib/common.sh"
  install -m 0644 "$REPO_DIR"/chains/*.env "$INSTALLED/chains/"

  local when='daily'
  [[ $ROLE == signer ]] && when='hourly'
  cat >/etc/systemd/system/bridge-operator-backup.service <<EOF
# Managed by bridge-operator backup.sh setup.
[Unit]
Description=Encrypted backup of the $CHAIN_TITLE $ROLE's keys and settings

[Service]
Type=oneshot
ExecStart=$INSTALLED/backup.sh run
Nice=10
EOF
  cat >/etc/systemd/system/bridge-operator-backup.timer <<EOF
# Managed by bridge-operator backup.sh setup.
[Unit]
Description=Scheduled ($when) backup of the $CHAIN_TITLE $ROLE

[Timer]
OnCalendar=$when
RandomizedDelaySec=10m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  if ((TEST_ONLY)); then
    info "TEST MODE: not touching systemd"
  else
    systemctl daemon-reload
    systemctl enable --now bridge-operator-backup.timer >/dev/null
  fi
  log "$when backups to $BACKUP_DIR, encrypted to $# recipient(s)"
  cmd_run
}

cmd_run() {
  need_root run
  load_install_conf
  [[ -s $RECIPIENTS ]] || die "no recipients; run: sudo ./backup.sh setup AGE_RECIPIENT"
  local keep=${KEEP:-30}
  [[ $ROLE == signer ]] && keep=${KEEP:-168} # a week of hourly backups

  local stamp work root out
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  work=$(mktemp -d)
  # shellcheck disable=SC2064 # expand now: $work is local
  trap "rm -rf '$work'" EXIT
  root=$work/$CHAIN
  mkdir -p "$root"

  # Copied with their paths, so a restore unpacks at the filesystem root.
  local files=(
    "$INSTALL_CONF" "$RECIPIENTS"
    "$NODE_STATE/staking"
    "$CHAIN_CONFIG_DIR"
    "/etc/systemd/system/$NODE_SERVICE.service"
  )
  if [[ $ROLE == signer ]]; then
    # The whole signer directory: signer.key, card.json, signers.json,
    # signing-log.json, deposits.json, refund-approvals, signer.env, and
    # paused.json if paused. The signer writes each by atomic rename, so a
    # copy is always a consistent version.
    files+=("$SIGNER_DIR" "$COIN_CONF"
      "/etc/systemd/system/$COIN_SERVICE.service" "/etc/systemd/system/$SIGNER_SERVICE.service")
  fi
  [[ -s $OFFSITE ]] && files+=("$OFFSITE")
  local f
  for f in "${files[@]}"; do
    [[ -e $f ]] || { info "not there yet, skipped: $f"; continue; }
    mkdir -p "$root$(dirname "$f")"
    cp -a "$f" "$root$(dirname "$f")/"
  done

  # The signer's watch-only wallet in the coin daemon, copied consistently
  # by the daemon itself. It holds addresses, never keys; rebuilding it
  # means a rescan, which a pruned Bitcoin node can't do for old blocks.
  if [[ $ROLE == signer ]] && systemctl is-active -q "$COIN_SERVICE.service" 2>/dev/null; then
    local wallet=wallet-$stamp.dat wallet_args=() target
    install -d -o "$COIN_USER" -g "$COIN_USER" -m 0700 "$COIN_DATA/backups"
    if [[ -n $COIN_WALLET ]]; then
      wallet_args=(-rpcwallet="$COIN_WALLET")
      target=$COIN_DATA/backups/$wallet
    else
      # Dogecoin Core 1.14 writes wallet backups into its backups/ folder
      # whatever path it is given (as dogecoin-vm's deploy/backup.sh notes).
      target=$wallet
    fi
    if coin_cli "${wallet_args[@]}" backupwallet "$target" >/dev/null 2>&1 &&
      [[ -f $COIN_DATA/backups/$wallet ]]; then
      mkdir -p "$root$COIN_DATA"
      mv "$COIN_DATA/backups/$wallet" "$root$COIN_DATA/wallet-backup.dat"
    else
      info "no $COIN_NAME wallet backed up (the signer makes its wallet when it first starts)"
    fi
  fi

  # A manifest, so a restore can be checked against what was live.
  local node_id pubkey
  node_id=$(metal_call info info.getNodeID 2>/dev/null | jq -r '.result.nodeID // empty' 2>/dev/null || true)
  pubkey=$(jq -r '.publicKey // empty' "$SIGNER_DIR/card.json" 2>/dev/null || true)
  (cd "$root" && find . -type f -print0 | sort -z | xargs -0 sha256sum) >"$work/sums"
  jq -n --arg host "$(hostname)" --arg time "$stamp" --arg chain "$CHAIN" --arg role "$ROLE" \
    --arg nodeID "$node_id" --arg signerPublicKey "$pubkey" --arg commit "$BRIDGE_COMMIT" \
    --rawfile sha256 "$work/sums" \
    '{host: $host, time: $time, chain: $chain, role: $role, nodeID: $nodeID,
      signerPublicKey: $signerPublicKey, bridgeCommit: $commit, sha256: $sha256}' >"$root/MANIFEST.json"

  out=$BACKUP_DIR/$CHAIN-$stamp.tar.age
  install -d -m 0700 "$BACKUP_DIR"
  local recipients=() r
  while read -r r; do
    [[ -n $r && $r != \#* ]] && recipients+=(-r "$r")
  done <"$RECIPIENTS"
  tar -C "$work" -czf - "$CHAIN" | age "${recipients[@]}" -o "$out.partial"
  chmod 0600 "$out.partial"
  mv "$out.partial" "$out"
  log "wrote $out ($(du -h "$out" | cut -f1))"

  # Keep the newest $keep.
  find "$BACKUP_DIR" -maxdepth 1 -name "$CHAIN-*.tar.age" -printf '%T@ %p\n' | sort -rn |
    tail -n +$((keep + 1)) | cut -d' ' -f2- | xargs -r rm -f

  if [[ -s $OFFSITE ]]; then
    rsync -a --chmod=F600 "$out" "$(cat "$OFFSITE")/" && log "copied offsite"
  fi
}

cmd_list() {
  ls -lh "$BACKUP_DIR"/*.tar.age 2>/dev/null || echo "no backups yet"
  systemctl list-timers bridge-operator-backup.timer --no-pager 2>/dev/null | head -2 || true
}

# Decrypts a backup into a private temporary directory, checks every file
# against its manifest, and says what it holds. Prints no secret. Works on
# Linux or macOS with age installed; needs no root.
cmd_verify() {
  [[ $# -eq 2 ]] || die "usage: ./backup.sh verify BACKUP.tar.age IDENTITY_FILE"
  local file=$1 identity=$2 dir root
  command -v age >/dev/null || die "age is not installed"
  dir=$(mktemp -d)
  chmod 700 "$dir"
  # shellcheck disable=SC2064 # expand now
  trap "rm -rf '$dir'" EXIT
  age -d -i "$identity" "$file" | tar -xzf - -C "$dir"
  root=$(find "$dir" -mindepth 1 -maxdepth 1 -type d | head -1)
  [[ -f $root/MANIFEST.json ]] || die "no MANIFEST.json: not a bridge-operator backup"
  local sha=sha256sum
  command -v sha256sum >/dev/null || sha='shasum -a 256'
  if ! (cd "$root" && jq -j .sha256 MANIFEST.json | $sha -c --quiet -); then
    die "some files do not match the manifest"
  fi
  log "decrypted and every file matches its manifest"
  jq -r 'def v: if . == null or . == "" then "-" else . end;
    "    chain \(.chain), role \(.role), from \(.host) at \(.time)",
    "    NodeID \(.nodeID | v), signer public key \(.signerPublicKey | v)",
    "    built from \(.bridgeCommit)"' "$root/MANIFEST.json"
  local key
  key=$(find "$root" -name signer.key -type f | head -1)
  if [[ -n $key ]]; then
    # Shape only: 64 hex characters. The key itself is never shown.
    if grep -qE '^[0-9a-f]{64}$' "$key"; then
      info "signer key present and well formed"
    else
      warn "signer.key is present but not 64 hex characters"
    fi
  fi
  if [[ -n $(find "$root" -name signing-log.json -type f) ]]; then
    info "signing log present"
  fi
  info "files:"
  (cd "$root" && find . -type f ! -name MANIFEST.json | sort | sed 's/^\./      /')
  info "(the decrypted copy has been deleted)"
}

case ${1:-} in
  setup) shift; cmd_setup "$@" ;;
  run) cmd_run ;;
  list) cmd_list ;;
  verify) shift; cmd_verify "$@" ;;
  *) usage; exit 2 ;;
esac
