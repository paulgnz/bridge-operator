# shellcheck shell=bash disable=SC2034,SC2153
# Shared by install.sh, check.sh and backup.sh. Not run on its own.
# (SC2034, SC2153: the variables here are used by the scripts that source
# this file, and chains/*.env sets the rest.)

# --- Pins shared by both chains ----------------------------------------------
# To update Go: take the new version's linux-amd64 SHA-256 from
# https://go.dev/dl/ (the page lists it next to each file) and change both
# lines. The bridges' go.mod files say which Go they need.
GO_VERSION=1.24.11
GO_SHA256=bceca00afaac856bc48b4cc33db7cd9eb383c81811379faed3bdbc80edb0af65
GO_URL=https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz

# metalgo, built from source at this tag, which must resolve to this commit.
# To update: git ls-remote https://github.com/MetalBlockchain/metalgo
# 'refs/tags/vX.Y.Z^{}' gives the commit.
METALGO_REPO=https://github.com/MetalBlockchain/metalgo
METALGO_VERSION=v1.13.5
METALGO_COMMIT=d93bc237d3b4b6f7bb395c8a36b4069a7a222489
METALGO_BIN=/opt/metal/${METALGO_VERSION}/metalgo

# --- Fixed places and ports ---------------------------------------------------
CONF_DIR=/etc/bridge-operator
INSTALL_CONF=$CONF_DIR/install.conf
BACKUP_DIR=/var/backups/bridge-operator
# Downloads land here (root only), never in a shared /tmp.
DL_DIR=/var/cache/bridge-operator
BUILD_USER=bridge-build
BUILD_HOME=/var/lib/bridge-build
METAL_HTTP_PORT=9650      # localhost only
METAL_STAKING_PORT=9651   # Metal peer-to-peer, public
SIGNER_PORT=9700          # the signer's API; open only to the coordinator

# --- Output --------------------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\033[1m' RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RESET=$'\033[0m'
else
  BOLD='' RED='' GREEN='' YELLOW='' RESET=''
fi
log() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() {
  printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}

# --- Chains -------------------------------------------------------------------
# REPO_DIR is set by the calling script: the directory holding chains/.
load_chain() {
  local chain=$1
  case $chain in
    btcvm | dogevm) ;;
    *) die "unknown chain '$chain': use btcvm or dogevm" ;;
  esac
  local file=$REPO_DIR/chains/$chain.env
  [[ -f $file ]] || die "missing $file"
  # shellcheck source=/dev/null
  source "$file"
  [[ $CHAIN == "$chain" ]] || die "$file sets CHAIN=$CHAIN, not $chain"

  # Derived from the values in chains/*.env.
  PLUGIN_DIR=$OPT_DIR/plugins
  BRIDGE_BIN_PATH=$OPT_DIR/bin/$BRIDGE_BIN
  CHAIN_CONFIG_DIR=$NODE_STATE/chain-configs
  CHAIN_CONFIG=$CHAIN_CONFIG_DIR/$L1_CHAIN_ID/config.json
  NODE_API=http://127.0.0.1:$METAL_HTTP_PORT
  L1_RPC_URL=$NODE_API/ext/bc/$L1_CHAIN_ID/rpc
  COIN_CONF=$COIN_DATA/$COIN_CONF_NAME
  COIN_CLI_PATH=$COIN_HOME/bin/$COIN_CLI
  SIGNER_ENV=$SIGNER_DIR/signer.env
  SIGNER_KEY=$SIGNER_DIR/signer.key
  SIGNER_SET=$SIGNER_DIR/signers.json
  # The service file signer-setup join writes; install.sh reads the
  # operator's choices (-max-daily, -listen) from it.
  SIGNER_JOIN_UNIT=$SIGNER_DIR/$SIGNER_SERVICE.service
  # The RPC user the signer uses on the chain's own node.
  COIN_RPC_USER=$SIGNER_USER
}

# The installed chain and role, as install.sh recorded them.
load_install_conf() {
  [[ -r $INSTALL_CONF ]] || die "no $INSTALL_CONF: run install.sh first (as root)"
  CHAIN='' ROLE=''
  # shellcheck source=/dev/null
  source "$INSTALL_CONF"
  [[ -n $CHAIN && -n $ROLE ]] || die "$INSTALL_CONF does not name a chain and role"
  load_chain "$CHAIN"
}

# A JSON-RPC call to the Metal node's own APIs (info, health, platform).
metal_call() {
  local endpoint=$1 method=$2 params=${3:-'{}'}
  curl -s -m 10 -X POST -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
    "$NODE_API/ext/$endpoint"
}

# The coin daemon's CLI, as its own user, with its cookie for auth.
coin_cli() {
  runuser -u "$COIN_USER" -- "$COIN_CLI_PATH" -datadir="$COIN_DATA" "$@"
}
