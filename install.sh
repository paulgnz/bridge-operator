#!/usr/bin/env bash
# Sets up a Metal mainnet node, or a peg signer, for one of the bridges:
# BTCVM (BTC) or DogecoinVM (DOGE). Run as root on a fresh Ubuntu 24.04
# x86_64 server:
#
#   sudo ./install.sh --chain btcvm|dogevm --role node|signer [--dry-run]
#
# node    A Metal mainnet node that syncs the P-Chain and tracks the chain's
#         L1, with the L1 plugin built from source at a pinned commit. It
#         serves the L1's JSON-RPC on localhost. It does not validate.
# signer  Everything a peg signer needs on its own machine: the node above,
#         the chain's own Bitcoin Core (pruned) or Dogecoin Core (-txindex),
#         and the bridge binary. The signer service is created only once the
#         operator has run the key ceremony (GUIDE.md); re-run this script
#         after "signer-setup join" to create and start it.
#
# This script never makes, reads, prints or copies a private key. The
# signer's key is made by "btcvm signer-setup init" (or dogevm), run by the
# operator as the signer's own user.
#
# Safe to re-run: it upgrades to the pins in chains/*.env and lib/common.sh
# and keeps all state, passwords and keys. --dry-run prints every action
# without doing any of them.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
usage: sudo ./install.sh --chain btcvm|dogevm --role node|signer [options]

  --chain btcvm|dogevm        which bridge's L1
  --role node|signer          a node, or a peg signer (node + coin daemon + signer)
  --dry-run                   print every action without doing it
  --public-ip IP              this server's public IPv4 (default: detected)
  --signer-allow-from IP      the coordinator's address, allowed to reach the
                              signer on port 9700 (repeatable; remembered)
  --skip-ssh-hardening        leave the SSH server's settings alone
  -h, --help                  this help

See GUIDE.md for the whole procedure.
EOF
}

CHAIN_ARG='' ROLE_ARG='' DRY_RUN=0 PUBLIC_IP_ARG='' SKIP_SSH=0
ALLOW_FROM_ARG=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --chain) CHAIN_ARG=${2:-}; shift 2 ;;
    --role) ROLE_ARG=${2:-}; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --public-ip) PUBLIC_IP_ARG=${2:-}; shift 2 ;;
    --signer-allow-from) ALLOW_FROM_ARG+=("${2:-}"); shift 2 ;;
    --skip-ssh-hardening) SKIP_SSH=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ -n $CHAIN_ARG && -n $ROLE_ARG ]] || { usage >&2; exit 2; }
case $ROLE_ARG in node | signer) ;; *) die "unknown role '$ROLE_ARG': use node or signer" ;; esac
load_chain "$CHAIN_ARG"
ROLE=$ROLE_ARG

# TEST ONLY. Set by test/container-test.sh to exercise the installer's early
# steps (users, directories, configuration, unit files) in a container: it
# skips the downloads, builds and syncs, puts stub scripts where the binaries
# go, and never touches systemd, the firewall or SSH. Never set it on a real
# server: the result can't run anything.
TEST_ONLY=${BRIDGE_OPERATOR_TEST_ONLY_SKIP_BUILDS:-0}

is_ipv4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_signer() { [[ $ROLE == signer ]]; }

# --- Doing, or printing in a dry run ---------------------------------------------

quote() {
  local out=() a
  for a in "$@"; do out+=("$(printf '%q' "$a")"); done
  printf '%s' "${out[*]}"
}

# run CMD...: runs it, or prints it in a dry run.
run() {
  if ((DRY_RUN)); then
    printf '    + %s\n' "$(quote "$@")"
  else
    "$@"
  fi
}

# write_file PATH MODE OWNER:GROUP < CONTENT
# Writes atomically, only if something differs; sets FILE_CHANGED to 1 if it
# did. Files are created with umask 077 before chmod, so a secret is never
# readable by others even for a moment. Contents are shown only in a dry run,
# where secrets are placeholders.
FILE_CHANGED=0
write_file() {
  local path=$1 mode=$2 owner=$3 content tmp
  content=$(cat; printf x)
  content=${content%x}
  FILE_CHANGED=0
  if ((DRY_RUN)); then
    printf '    + write %s (mode %s, owner %s):\n' "$path" "$mode" "$owner"
    printf '%s' "$content" | sed 's/^/    |   /'
    FILE_CHANGED=1
    return
  fi
  if [[ -f $path ]] && [[ "$(stat -c '%a %U:%G' "$path")" == "${mode#0} $owner" ]] &&
    printf '%s' "$content" | cmp -s - "$path"; then
    return
  fi
  tmp=$(umask 077 && mktemp "$(dirname "$path")/.bridge-operator.XXXXXX")
  printf '%s' "$content" >"$tmp"
  chown "$owner" "$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$path"
  FILE_CHANGED=1
}

# A new random password (never printed). In a dry run, a placeholder.
new_secret() {
  if ((DRY_RUN)); then
    printf '<random, made at install time>'
  else
    openssl rand -hex 24
  fi
}

# The build user's environment: Go from /usr/local/go, never a downloaded
# toolchain, and caches in its own home. CGO_CFLAGS passes through: on a CPU
# without ADX/BMI2 (very old x86_64, or an emulator), metalgo's BLS library
# (blst) needs CGO_CFLAGS="-O -D__BLST_PORTABLE__", or it dies with SIGILL.
build_env() {
  runuser -u "$BUILD_USER" -- env HOME="$BUILD_HOME" PATH=/usr/local/go/bin:/usr/bin:/bin \
    GOTOOLCHAIN=local GOPATH="$BUILD_HOME/go" GOCACHE="$BUILD_HOME/.cache/go-build" \
    ${CGO_CFLAGS:+CGO_CFLAGS="$CGO_CFLAGS"} "$@"
}
as_build() {
  if ((DRY_RUN)); then
    printf '    + [as %s] %s\n' "$BUILD_USER" "$(quote "$@")"
  else
    build_env "$@"
  fi
}
# build_in DIR CMD...: runs CMD in DIR as the build user.
build_in() {
  local dir=$1
  shift
  if ((DRY_RUN)); then
    printf '    + [as %s, in %s] %s\n' "$BUILD_USER" "$dir" "$(quote "$@")"
  else
    # shellcheck disable=SC2016 # $1 and $@ belong to the inner shell
    build_env bash -c 'cd "$1" && shift && exec "$@"' _ "$dir" "$@"
  fi
}

# verify_sha256 FILE HASH: stops the install unless FILE has that SHA-256.
verify_sha256() {
  if ((DRY_RUN)); then
    printf '    + check that the SHA-256 of %s is %s\n' "$1" "$2"
  else
    echo "$2  $1" | sha256sum -c --quiet - || die "$1 does not match its pinned SHA-256; not installing it"
  fi
}

# A test-only stand-in for a binary (see TEST_ONLY).
install_stub() {
  local path=$1
  run install -d -m 0755 "$(dirname "$path")"
  write_file "$path" 0755 root:root <<'EOF'
#!/bin/sh
echo "bridge-operator TEST STUB: not a real binary" >&2
exit 1
EOF
}

# --- Steps ------------------------------------------------------------------------

preflight() {
  log "Checking this machine"
  if [[ $EUID -ne 0 ]]; then
    if ((DRY_RUN)); then
      warn "not root: fine for a dry run, but the real install needs sudo"
    else
      die "run as root: sudo ./install.sh ..."
    fi
  fi
  local os_id='' os_version=''
  if [[ -r /etc/os-release ]]; then
    os_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
    os_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
  fi
  if [[ $os_id != ubuntu || $os_version != 24.04 ]]; then
    if ((DRY_RUN)); then
      warn "this is ${os_id:-unknown} ${os_version:-}, not Ubuntu 24.04"
    else
      die "this installer supports Ubuntu 24.04 only (found ${os_id:-unknown} ${os_version:-})"
    fi
  fi
  if [[ $(uname -m) != x86_64 ]]; then
    if ((DRY_RUN)); then
      warn "this is $(uname -m), not x86_64"
    else
      die "this installer supports x86_64 only (the pinned downloads are x86_64 builds)"
    fi
  fi
  local other
  for other in btcvm dogevm; do
    [[ $other == "$CHAIN" ]] && continue
    if [[ -f /etc/systemd/system/$other-node.service ]]; then
      die "this server already runs the $other node; run one chain per server (both use ports $METAL_HTTP_PORT and $METAL_STAKING_PORT)"
    fi
  done
  if [[ -r $INSTALL_CONF ]]; then
    local prev_role
    prev_role=$(sed -n 's/^ROLE=//p' "$INSTALL_CONF")
    if [[ $prev_role == signer && $ROLE == node ]]; then
      die "this server is set up as a signer; re-run with --role signer (going back to node would orphan the signer)"
    fi
  fi
  local want=$MIN_DISK_GB_NODE
  is_signer && want=$MIN_DISK_GB_SIGNER
  local free_gb
  free_gb=$(df -P -BG /var/lib 2>/dev/null | awk 'NR==2 {sub("G","",$4); print $4}' || true)
  if [[ -n $free_gb && $free_gb -lt $want ]]; then
    warn "only ${free_gb} GB free under /var/lib; a $CHAIN_TITLE $ROLE needs about $want GB or more (GUIDE.md, Requirements)"
  fi
  if ((TEST_ONLY)); then
    warn "BRIDGE_OPERATOR_TEST_ONLY_SKIP_BUILDS is set: TEST MODE, nothing built, downloaded or started"
  fi
}

packages() {
  log "System packages"
  export DEBIAN_FRONTEND=noninteractive
  local pkgs=(ca-certificates curl git jq build-essential openssl age rsync ufw unattended-upgrades)
  # A clock in sync matters: the signer refuses requests more than 5 minutes
  # off its own clock. Keep chrony if it is there; otherwise timesyncd.
  if ! dpkg -s chrony >/dev/null 2>&1; then pkgs+=(systemd-timesyncd); fi
  run apt-get update -q
  run apt-get install -yq --no-install-recommends "${pkgs[@]}"
}

ensure_user() {
  local name=$1 home=$2
  if id "$name" >/dev/null 2>&1; then
    return
  fi
  run useradd --system --user-group --home-dir "$home" --no-create-home --shell /usr/sbin/nologin "$name"
}

users_and_dirs() {
  log "Service users and directories"
  ensure_user "$BUILD_USER" "$BUILD_HOME"
  ensure_user "$NODE_USER" "$NODE_STATE"
  if is_signer; then
    ensure_user "$COIN_USER" "$COIN_DATA"
    ensure_user "$SIGNER_USER" "$SIGNER_DIR"
  fi
  # Binaries are owned by root, so no service can change what it runs.
  run install -d -m 0755 -o root -g root /opt/metal "$OPT_DIR" "$OPT_DIR/bin" "$PLUGIN_DIR"
  run install -d -m 0750 -o "$BUILD_USER" -g "$BUILD_USER" "$BUILD_HOME" "$BUILD_HOME/src"
  run install -d -m 0750 -o "$NODE_USER" -g "$NODE_USER" "$NODE_STATE" "$NODE_STATE/logs"
  run install -d -m 0700 -o "$NODE_USER" -g "$NODE_USER" "$CHAIN_CONFIG_DIR" "$CHAIN_CONFIG_DIR/$L1_CHAIN_ID" \
    "$NODE_STATE/chaindata" "$NODE_STATE/chainlogs"
  run install -d -m 0755 -o root -g root "$CONF_DIR"
  run install -d -m 0700 -o root -g root "$BACKUP_DIR" "$DL_DIR"
  if is_signer; then
    run install -d -m 0750 -o "$COIN_USER" -g "$COIN_USER" "$COIN_DATA"
    # The signer's directory: its key, signer set, signing log. Only the
    # signer's user can open it.
    run install -d -m 0700 -o "$SIGNER_USER" -g "$SIGNER_USER" "$SIGNER_DIR"
  fi
}

install_go() {
  if ((TEST_ONLY)); then return; fi
  if grep -q "go$GO_VERSION " <<<"$(/usr/local/go/bin/go version 2>/dev/null)"; then
    info "Go $GO_VERSION already installed"
    return
  fi
  log "Go $GO_VERSION (SHA-256 pinned)"
  local tgz=$DL_DIR/go.tgz
  run curl -fsSLo "$tgz" "$GO_URL"
  verify_sha256 "$tgz" "$GO_SHA256"
  run rm -rf /usr/local/go
  run tar -C /usr/local -xzf "$tgz"
  run rm -f "$tgz"
}

# checkout_pinned DIR REPO REF COMMIT [DEPTH]: DIR holds REPO at exactly
# COMMIT, which REF (a branch or tag) is expected to contain.
checkout_pinned() {
  local dir=$1 repo=$2 ref=$3 commit=$4 depth=()
  [[ -n ${5:-} ]] && depth=(--depth "$5")
  if [[ -d $dir/.git ]]; then
    as_build git -C "$dir" remote set-url origin "$repo"
    as_build git -C "$dir" fetch -q ${depth[@]+"${depth[@]}"} origin "$ref"
  else
    as_build git clone -q ${depth[@]+"${depth[@]}"} --branch "$ref" "$repo" "$dir"
  fi
  if ! ((DRY_RUN)) && ! runuser -u "$BUILD_USER" -- git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
    as_build git -C "$dir" fetch -q origin "$commit"
  fi
  as_build git -C "$dir" -c advice.detachedHead=false checkout -q --detach "$commit"
  if ! ((DRY_RUN)); then
    local head
    head=$(runuser -u "$BUILD_USER" -- git -C "$dir" rev-parse HEAD)
    [[ $head == "$commit" ]] || die "$repo: checked out $head, expected the pinned $commit"
  fi
}

NODE_BIN_CHANGED=0
build_metalgo() {
  if ((TEST_ONLY)); then
    [[ -x $METALGO_BIN ]] || NODE_BIN_CHANGED=1
    install_stub "$METALGO_BIN"
    return
  fi
  if [[ -x $METALGO_BIN ]]; then
    info "metalgo $METALGO_VERSION already built"
    return
  fi
  log "metalgo $METALGO_VERSION from source (commit $METALGO_COMMIT)"
  local src=$BUILD_HOME/src/metalgo
  checkout_pinned "$src" "$METALGO_REPO" "$METALGO_VERSION" "$METALGO_COMMIT" 1
  build_in "$src" ./scripts/build.sh
  run install -D -m 0755 -o root -g root "$src/build/metalgo" "$METALGO_BIN"
  NODE_BIN_CHANGED=1
}

SIGNER_BIN_CHANGED=0
build_bridge() {
  local stamp=$OPT_DIR/BUILT_FROM
  if ((TEST_ONLY)); then
    [[ -f $PLUGIN_DIR/$L1_VM_ID ]] || NODE_BIN_CHANGED=1
    install_stub "$PLUGIN_DIR/$L1_VM_ID"
    if is_signer; then
      install_stub "$BRIDGE_BIN_PATH"
      run ln -sfn "$BRIDGE_BIN_PATH" "/usr/local/bin/$BRIDGE_BIN"
    fi
    return
  fi
  if [[ -f $PLUGIN_DIR/$L1_VM_ID && "$(cat "$stamp" 2>/dev/null)" == "$BRIDGE_COMMIT" ]] &&
    { ! is_signer || [[ -x $BRIDGE_BIN_PATH ]]; }; then
    info "$CHAIN_TITLE already built at $BRIDGE_COMMIT"
    return
  fi
  log "$CHAIN_TITLE from source ($BRIDGE_REPO at $BRIDGE_COMMIT)"
  local src=$BUILD_HOME/src/$CHAIN outdir=$BUILD_HOME/out/$CHAIN
  checkout_pinned "$src" "$BRIDGE_REPO" "$BRIDGE_BRANCH" "$BRIDGE_COMMIT"
  as_build mkdir -p "$outdir"
  # The plugin's file name must be the VM ID the L1 was created with.
  if ((DRY_RUN)); then
    build_in "$src" go run ./scripts/vm-id-generator.go
    info "(the installer stops unless that prints $L1_VM_ID)"
  else
    local vmid
    # shellcheck disable=SC2016 # $1 belongs to the inner shell
    vmid=$(build_env bash -c 'cd "$1" && go run ./scripts/vm-id-generator.go' _ "$src")
    [[ $vmid == "$L1_VM_ID" ]] || die "this source builds VM $vmid, but the $CHAIN_TITLE L1 runs $L1_VM_ID"
  fi
  build_in "$src" go build -o "$outdir/plugin" "$BRIDGE_PLUGIN_PKG"
  # Staged beside, not in, the plugin directory: metalgo treats every file
  # there as a VM. The mv is atomic, so the node never sees half a plugin.
  run install -m 0755 -o root -g root "$outdir/plugin" "$OPT_DIR/.plugin.new"
  run mv -f "$OPT_DIR/.plugin.new" "$PLUGIN_DIR/$L1_VM_ID"
  NODE_BIN_CHANGED=1
  if is_signer; then
    build_in "$src" go build -o "$outdir/cli" "$BRIDGE_CLI_PKG"
    run install -m 0755 -o root -g root "$outdir/cli" "$BRIDGE_BIN_PATH.new"
    run mv -f "$BRIDGE_BIN_PATH.new" "$BRIDGE_BIN_PATH"
    run ln -sfn "$BRIDGE_BIN_PATH" "/usr/local/bin/$BRIDGE_BIN"
    SIGNER_BIN_CHANGED=1
  fi
  write_file "$stamp" 0644 root:root <<<"$BRIDGE_COMMIT"
}

COIN_BIN_CHANGED=0
install_coin() {
  if ((TEST_ONLY)); then
    [[ -x $COIN_HOME/bin/$COIN_DAEMON ]] || COIN_BIN_CHANGED=1
    install_stub "$COIN_HOME/bin/$COIN_DAEMON"
    install_stub "$COIN_HOME/bin/$COIN_CLI"
    return
  fi
  if [[ -x $COIN_HOME/bin/$COIN_DAEMON ]]; then
    info "$COIN_NAME $COIN_VERSION already installed"
    return
  fi
  log "$COIN_NAME $COIN_VERSION (SHA-256 pinned)"
  local tgz=$DL_DIR/$COIN_DAEMON.tgz
  run curl -fsSLo "$tgz" "$COIN_URL"
  verify_sha256 "$tgz" "$COIN_SHA256"
  run rm -rf "${DL_DIR:?}/$COIN_TAR_DIR"
  run tar -C "$DL_DIR" -xzf "$tgz"
  run chown -R root:root "$DL_DIR/$COIN_TAR_DIR"
  run rm -rf "$COIN_HOME"
  run mv "$DL_DIR/$COIN_TAR_DIR" "$COIN_HOME"
  run rm -f "$tgz"
  COIN_BIN_CHANGED=1
}

# The L1's chain config: node-local settings, including a private RPC
# password for this node's own JSON-RPC (localhost only).
NODE_CONF_CHANGED=0
L1_RPC_PASS=''
chain_config() {
  log "$CHAIN_TITLE chain config ($CHAIN_CONFIG)"
  if [[ -f $CHAIN_CONFIG ]]; then
    # A dry run never reads (or shows) an existing password.
    if ((DRY_RUN)); then
      L1_RPC_PASS='<kept from the existing file>'
    else
      L1_RPC_PASS=$(jq -r '.rpcPass // empty' "$CHAIN_CONFIG")
    fi
  fi
  [[ -n $L1_RPC_PASS ]] || L1_RPC_PASS=$(new_secret)
  # Written directly, not with jq: a dry run on a fresh server has no jq yet.
  # Every value is plain text (a hex password, fixed paths): nothing to escape.
  write_file "$CHAIN_CONFIG" 0600 "$NODE_USER:$NODE_USER" <<EOF
{
  "rpcUser": "$CHAIN",
  "rpcPass": "$L1_RPC_PASS",
  "txIndex": true,
  "addrIndex": true,
  "dataDir": "$NODE_STATE/chaindata",
  "logDir": "$NODE_STATE/chainlogs"
}
EOF
  ((FILE_CHANGED)) && NODE_CONF_CHANGED=1
  return 0
}

# rpcauth=USER:SALT$HMAC, as Bitcoin Core's share/rpcauth/rpcauth.py makes
# it, so the password itself is not stored in the daemon's config.
rpcauth_line() {
  local user=$1 pass=$2 salt hmac
  if ((DRY_RUN)); then
    printf 'rpcauth=%s:<salt>$<hmac of the password>\n' "$user"
    return
  fi
  salt=$(openssl rand -hex 16)
  hmac=$(printf '%s' "$pass" | openssl dgst -sha256 -hmac "$salt" | awk '{print $NF}')
  printf 'rpcauth=%s:%s$%s\n' "$user" "$salt" "$hmac"
}

COIN_CONF_CHANGED=0
COIN_RPC_PASS=''
coin_config() {
  log "$COIN_NAME config ($COIN_CONF)"
  local pass_var=${ENV_COIN_PREFIX}_RPC_PASS
  if [[ -f $SIGNER_ENV ]]; then
    if ((DRY_RUN)); then
      COIN_RPC_PASS='<kept from the existing file>'
    else
      COIN_RPC_PASS=$(sed -n "s/^$pass_var=//p" "$SIGNER_ENV")
    fi
  fi
  if [[ -f $COIN_CONF ]]; then
    if [[ -n $COIN_RPC_PASS ]] && grep -q "^rpcauth=$COIN_RPC_USER:" "$COIN_CONF"; then
      info "keeping the existing $COIN_CONF_NAME"
      return
    fi
    # The signer's password is unknown or its rpcauth line is missing: make
    # a new one. Everything else in the file (the operator may have tuned it)
    # stays.
    COIN_RPC_PASS=$(new_secret)
    write_file "$COIN_CONF" 0600 "$COIN_USER:$COIN_USER" < <(
      grep -v "^rpcauth=$COIN_RPC_USER:" "$COIN_CONF" || true
      rpcauth_line "$COIN_RPC_USER" "$COIN_RPC_PASS"
    )
  else
    COIN_RPC_PASS=$(new_secret)
    write_file "$COIN_CONF" 0600 "$COIN_USER:$COIN_USER" <<EOF
# $COIN_NAME for the $CHAIN_TITLE peg signer. Written once by bridge-operator
# install.sh; edit freely (install.sh only manages the rpcauth line for
# $COIN_RPC_USER). RPC listens on localhost only.
server=1
$COIN_CONF_EXTRA
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
$(rpcauth_line "$COIN_RPC_USER" "$COIN_RPC_PASS")
EOF
  fi
  COIN_CONF_CHANGED=1
}

# The signer's connection settings for its own two nodes. signer-setup join
# writes this file only if it is missing, so the one written here is kept.
SIGNER_ENV_CHANGED=0
signer_env() {
  log "Signer connection settings ($SIGNER_ENV)"
  write_file "$SIGNER_ENV" 0600 "$SIGNER_USER:$SIGNER_USER" <<EOF
# Connection settings for this signer's own nodes. Managed by bridge-operator
# install.sh. Holds passwords: mode 0600, never commit or share it.
${ENV_VM_PREFIX}_NETWORK=mainnet
${ENV_VM_PREFIX}_RPC=$L1_RPC_URL
${ENV_VM_PREFIX}_RPC_USER=$CHAIN
${ENV_VM_PREFIX}_RPC_PASS=$L1_RPC_PASS
${ENV_COIN_PREFIX}_NETWORK=mainnet
${ENV_COIN_PREFIX}_RPC=http://127.0.0.1:$COIN_RPC_PORT
${ENV_COIN_PREFIX}_RPC_USER=$COIN_RPC_USER
${ENV_COIN_PREFIX}_RPC_PASS=$COIN_RPC_PASS
EOF
  ((FILE_CHANGED)) && SIGNER_ENV_CHANGED=1
  # Refunds a signer approves, one "TXID:VOUT ADDRESS" per line (GUIDE.md).
  if [[ ! -f $SIGNER_DIR/refund-approvals ]]; then
    write_file "$SIGNER_DIR/refund-approvals" 0600 "$SIGNER_USER:$SIGNER_USER" <<'EOF'
# Refunds this signer approves, one per line, after checking each yourself:
# TXID:VOUT ADDRESS
EOF
  fi
}

PUBLIC_IP=''
ALLOW_FROM=()
settle_addresses() {
  local saved_ip='' saved_allow=''
  if [[ -r $INSTALL_CONF ]]; then
    saved_ip=$(sed -n 's/^PUBLIC_IP_OVERRIDE=//p' "$INSTALL_CONF")
    saved_allow=$(sed -n 's/^SIGNER_ALLOW_FROM=//p' "$INSTALL_CONF" | tr -d '"')
  fi
  PUBLIC_IP_OVERRIDE=${PUBLIC_IP_ARG:-$saved_ip}
  if [[ -n $PUBLIC_IP_OVERRIDE ]]; then
    is_ipv4 "$PUBLIC_IP_OVERRIDE" || die "--public-ip $PUBLIC_IP_OVERRIDE is not an IPv4 address"
    PUBLIC_IP=$PUBLIC_IP_OVERRIDE
  elif ((TEST_ONLY)); then
    PUBLIC_IP=192.0.2.10 # TEST-NET-1: documentation only, never routed
  elif ((DRY_RUN)); then
    printf '    + curl -fsS4 -m 10 https://ifconfig.me   (detects the public IP)\n'
    PUBLIC_IP='<public-ip>'
  else
    PUBLIC_IP=$(curl -fsS4 -m 10 https://ifconfig.me || curl -fsS4 -m 10 https://api.ipify.org || true)
    is_ipv4 "$PUBLIC_IP" || die "could not detect this server's public IPv4; pass --public-ip"
  fi
  if ((${#ALLOW_FROM_ARG[@]})); then
    local a
    for a in "${ALLOW_FROM_ARG[@]}"; do
      is_ipv4 "$a" || [[ $a =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "--signer-allow-from $a is not an IPv4 address or range"
      ALLOW_FROM+=("$a")
    done
  elif [[ -n $saved_allow ]]; then
    read -r -a ALLOW_FROM <<<"$saved_allow"
  fi
  info "public IP: $PUBLIC_IP"
  is_signer && info "signer reachable from: ${ALLOW_FROM[*]:-nobody yet (pass --signer-allow-from COORDINATOR_IP)}"
  return 0
}

# Sandboxing shared by every unit. Each unit adds ReadWritePaths for its own
# state; everything else is read-only (ProtectSystem=strict) or hidden.
SANDBOX='NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RemoveIPC=yes
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
UMask=0077'

NODE_UNIT_CHANGED=0
node_unit() {
  log "Metal node service ($NODE_SERVICE)"
  write_file "/etc/systemd/system/$NODE_SERVICE.service" 0644 root:root <<EOF
# Managed by bridge-operator install.sh; re-run it rather than editing this.
[Unit]
Description=Metal mainnet node tracking the $CHAIN_TITLE L1 ($L1_CHAIN_ID)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$NODE_USER
Group=$NODE_USER
Environment=HOME=$NODE_STATE
WorkingDirectory=$NODE_STATE
# Syncs only the P-Chain of the primary network, and tracks the L1's subnet.
# Its APIs (and the L1's JSON-RPC) listen on localhost only; peers reach it on
# the staking port.
ExecStart=$METALGO_BIN --network-id=mainnet --partial-sync-primary-network=true --track-subnets=$L1_SUBNET_ID --data-dir=$NODE_STATE --log-dir=$NODE_STATE/logs --plugin-dir=$PLUGIN_DIR --chain-config-dir=$CHAIN_CONFIG_DIR --http-host=127.0.0.1 --http-port=$METAL_HTTP_PORT --staking-port=$METAL_STAKING_PORT --public-ip=$PUBLIC_IP
Restart=on-failure
RestartSec=10
# SIGTERM to metalgo only: it shuts each chain down in order, and the chain's
# plugin closes its database. Sent to the whole unit, it killed the plugin
# first and lost accepted blocks.
KillMode=mixed
TimeoutStopSec=120
LimitNOFILE=65536

$SANDBOX
ReadWritePaths=$NODE_STATE
# The plugin talks to metalgo over local sockets; NETLINK lets Go list
# network interfaces.
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF
  ((FILE_CHANGED)) && NODE_UNIT_CHANGED=1
  return 0
}

COIN_UNIT_CHANGED=0
coin_unit() {
  log "$COIN_NAME service ($COIN_SERVICE)"
  write_file "/etc/systemd/system/$COIN_SERVICE.service" 0644 root:root <<EOF
# Managed by bridge-operator install.sh; re-run it rather than editing this.
[Unit]
Description=$COIN_NAME $COIN_VERSION (mainnet) for the $CHAIN_TITLE peg signer
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$COIN_USER
Group=$COIN_USER
ExecStart=$COIN_HOME/bin/$COIN_DAEMON -datadir=$COIN_DATA -conf=$COIN_CONF -printtoconsole
Restart=on-failure
RestartSec=30
# Shutting down flushes the chain state to disk; give it time.
TimeoutStopSec=600
LimitNOFILE=16384

$SANDBOX
ReadWritePaths=$COIN_DATA
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF
  ((FILE_CHANGED)) && COIN_UNIT_CHANGED=1
  return 0
}

# The signer's service unit. The daily limit and listen address are the
# operator's choices at signer-setup join.
signer_unit_content() {
  local max_daily=$1 listen=$2 allow
  # The signer talks only to its own nodes on localhost, and answers only
  # the coordinator (and this machine, for signer-setup check).
  allow="localhost"
  [[ $PUBLIC_IP == '<public-ip>' ]] || allow+=" $PUBLIC_IP"
  ((${#ALLOW_FROM[@]})) && allow+=" ${ALLOW_FROM[*]}"
  cat <<EOF
# Managed by bridge-operator install.sh; re-run it rather than editing this.
# (signer-setup join also writes $SIGNER_JOIN_UNIT; this hardened unit is
# the one installed, with the same settings.)
[Unit]
Description=$CHAIN_TITLE peg signer
Wants=network-online.target $NODE_SERVICE.service $COIN_SERVICE.service
After=network-online.target $NODE_SERVICE.service $COIN_SERVICE.service

[Service]
Type=simple
User=$SIGNER_USER
Group=$SIGNER_USER
EnvironmentFile=$SIGNER_ENV
ExecStart=$BRIDGE_BIN_PATH signer -signers $SIGNER_SET -key-file $SIGNER_KEY -listen $listen -log $SIGNER_DIR/signing-log.json -deposits $SIGNER_DIR/deposits.json -refund-approvals $SIGNER_DIR/refund-approvals -max-daily $max_daily
Restart=on-failure
RestartSec=5

$SANDBOX
ReadWritePaths=$SIGNER_DIR
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
IPAddressDeny=any
IPAddressAllow=$allow

[Install]
WantedBy=multi-user.target
EOF
}

# The signer's service, created only once the ceremony has run (init, then
# join).
SIGNER_READY=0 SIGNER_UNIT_CHANGED=0
signer_unit() {
  local unit=/etc/systemd/system/$SIGNER_SERVICE.service
  if [[ ! -f $SIGNER_KEY || ! -f $SIGNER_SET || ! -f $SIGNER_JOIN_UNIT ]]; then
    if [[ ! -f $SIGNER_KEY ]]; then
      info "no signer key yet: the key ceremony comes next (see the end of this output)"
    else
      info "signer key present, but not joined to a signer set yet: run signer-setup join (GUIDE.md)"
    fi
    if ((DRY_RUN)); then
      info "After the ceremony, a re-run of install.sh writes $unit:"
      signer_unit_content '<from join>' "0.0.0.0:$SIGNER_PORT" | sed 's/^/    |   /'
    fi
    return
  fi
  log "Peg signer service ($SIGNER_SERVICE)"
  # The key stays where init made it; only its ownership and mode are
  # enforced. This script never opens it.
  run chown "$SIGNER_USER:$SIGNER_USER" "$SIGNER_KEY"
  run chmod 0600 "$SIGNER_KEY"
  local max_daily listen
  max_daily=$(sed -n 's/.* -max-daily \([0-9][0-9]*\).*/\1/p' "$SIGNER_JOIN_UNIT")
  listen=$(sed -n 's/.* -listen \([^ ]*\).*/\1/p' "$SIGNER_JOIN_UNIT")
  [[ -n $max_daily ]] || die "could not read -max-daily from $SIGNER_JOIN_UNIT; run signer-setup join again"
  write_file "$unit" 0644 root:root < <(signer_unit_content "$max_daily" "${listen:-0.0.0.0:$SIGNER_PORT}")
  ((FILE_CHANGED)) && SIGNER_UNIT_CHANGED=1
  SIGNER_READY=1
}

ssh_ports() {
  local ports=''
  if command -v sshd >/dev/null 2>&1; then
    ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -u | tr '\n' ' ')
  fi
  printf '%s' "${ports:-22}"
}

firewall() {
  log "Firewall (ufw)"
  local p a
  # SSH first, so enabling the firewall can't lock the operator out.
  for p in $(ssh_ports); do
    run ufw allow "$p/tcp" comment 'SSH'
  done
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw allow "$METAL_STAKING_PORT/tcp" comment 'Metal peers (staking port)'
  if is_signer; then
    run ufw allow "$COIN_P2P_PORT/tcp" comment "$COIN_NAME peers"
    for a in ${ALLOW_FROM[@]+"${ALLOW_FROM[@]}"}; do
      run ufw allow from "$a" to any port "$SIGNER_PORT" proto tcp comment 'peg signer: coordinator'
    done
  fi
  if ((TEST_ONLY)); then
    info "TEST MODE: not enabling ufw"
    return
  fi
  run ufw --force enable
}

auto_updates() {
  log "Automatic security updates"
  write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 root:root <<'EOF'
// Managed by bridge-operator install.sh.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
}

ssh_hardening() {
  ((SKIP_SSH)) && { info "leaving SSH alone (--skip-ssh-hardening)"; return; }
  if ! command -v sshd >/dev/null 2>&1; then
    info "no SSH server here; nothing to harden"
    return
  fi
  log "SSH: key logins only"
  # Only switch passwords off if someone can already log in with a key.
  local f has_key=0
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -s $f ]] && grep -qE '^(ssh-|ecdsa-|sk-)' "$f" && has_key=1
  done
  if ((!has_key)); then
    warn "no SSH key in any authorized_keys: leaving password login ON so you are not locked out. Add a key and re-run."
    return
  fi
  write_file /etc/ssh/sshd_config.d/10-bridge-operator.conf 0644 root:root <<'EOF'
# Managed by bridge-operator install.sh: key logins only.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  if ((FILE_CHANGED)) && ! ((DRY_RUN)); then
    if ! sshd -t; then
      rm -f /etc/ssh/sshd_config.d/10-bridge-operator.conf
      die "sshd rejected the new settings; removed them, SSH unchanged"
    fi
    ((TEST_ONLY)) || systemctl try-reload-or-restart ssh.service
  fi
  if ! ((DRY_RUN)) && grep -qi '^passwordauthentication yes' <<<"$(sshd -T 2>/dev/null)"; then
    warn "another file in /etc/ssh/sshd_config.d still turns password login on; check it"
  fi
}

# start_service NAME CHANGED: enable it; restart it if its binary, config or
# unit changed, else start it if it is stopped.
start_service() {
  local name=$1 changed=$2
  run systemctl enable "$name.service"
  if ((changed)); then
    run systemctl restart "$name.service"
  else
    run systemctl start "$name.service"
  fi
}

services() {
  if ((TEST_ONLY)); then
    info "TEST MODE: not touching systemd"
    return
  fi
  log "Starting services"
  run systemctl daemon-reload
  start_service "$NODE_SERVICE" $((NODE_BIN_CHANGED | NODE_CONF_CHANGED | NODE_UNIT_CHANGED))
  if is_signer; then
    start_service "$COIN_SERVICE" $((COIN_BIN_CHANGED | COIN_CONF_CHANGED | COIN_UNIT_CHANGED))
    if ((SIGNER_READY)); then
      start_service "$SIGNER_SERVICE" $((SIGNER_BIN_CHANGED | SIGNER_ENV_CHANGED | SIGNER_UNIT_CHANGED))
    fi
  fi
}

record_install() {
  write_file "$INSTALL_CONF" 0644 root:root <<EOF
# Written by bridge-operator install.sh; read by check.sh and backup.sh.
CHAIN=$CHAIN
ROLE=$ROLE
PUBLIC_IP_OVERRIDE=$PUBLIC_IP_OVERRIDE
SIGNER_ALLOW_FROM="${ALLOW_FROM[*]:-}"
BRIDGE_COMMIT=$BRIDGE_COMMIT
METALGO_VERSION=$METALGO_VERSION
EOF
}

next_steps() {
  local bin=$BRIDGE_BIN su="sudo -u $SIGNER_USER -H"
  echo
  log "Done: $CHAIN_TITLE $ROLE"
  cat <<EOF

The Metal node is syncing the P-Chain, then the $CHAIN_TITLE L1. Check progress
any time with:  sudo ./check.sh
EOF
  if ! is_signer; then
    cat <<EOF

This node does not validate. To become a validator, send its NodeID
(sudo ./check.sh prints it) to the $CHAIN_TITLE L1's owner; adding validators
is not open yet (GUIDE.md, "Becoming a validator").
EOF
    return
  fi
  cat <<EOF

$COIN_NAME is syncing mainnet ($COIN_SYNC_TIME). You can do the key
ceremony while it syncs.
EOF
  if ((SIGNER_READY)); then
    cat <<EOF

The signer service is installed and running. Check it:
  sudo ./check.sh
EOF
    ((${#ALLOW_FROM[@]})) || cat <<EOF

The coordinator can't reach this signer yet. Re-run with its address:
  sudo ./install.sh --chain $CHAIN --role signer --signer-allow-from COORDINATOR_IP
EOF
    return
  fi
  cat <<EOF

Next, the key ceremony (GUIDE.md, step 4). Run each command yourself, as the
signer's own user; the key is made on this machine and never leaves it:

  1. Make your key and signer card:
       $su $bin signer-setup init -dir $SIGNER_DIR
     Name: yours or your organisation's. URL: http://$PUBLIC_IP:$SIGNER_PORT
     (or a DNS name for this server).
  2. Send your card (public, no secrets) to the coordinator:
       sudo cat $SIGNER_DIR/card.json
  3. When the coordinator sends back signers.json and reads out its
     fingerprint over a separate channel:
       sudo install -o $SIGNER_USER -g $SIGNER_USER -m 0644 signers.json $SIGNER_DIR/signers.received.json
       $su $bin signer-setup join -dir $SIGNER_DIR -signers $SIGNER_DIR/signers.received.json
     (join keeps the $SIGNER_ENV this installer wrote.)
  4. Create and start the hardened signer service:
       sudo ./install.sh --chain $CHAIN --role signer --signer-allow-from COORDINATOR_IP
  5. Check:  sudo ./check.sh
EOF
}

main() {
  if ((DRY_RUN)); then
    log "DRY RUN: $CHAIN_TITLE $ROLE. Nothing below is done; each action is printed."
  fi
  preflight
  packages
  users_and_dirs
  install_go
  build_metalgo
  build_bridge
  is_signer && install_coin
  chain_config
  if is_signer; then
    coin_config
    signer_env
  fi
  settle_addresses
  node_unit
  if is_signer; then
    coin_unit
    signer_unit
  fi
  firewall
  auto_updates
  ssh_hardening
  services
  record_install
  next_steps
}

main
