#!/usr/bin/env bash
# Runs inside a throwaway ubuntu:24.04 container, as root, started by
# test/container-test.sh with the repository at /src and CHAIN set.
# TEST MODE only: never run this on a real server.
set -euo pipefail
[[ -f /.dockerenv ]] || { echo "refusing: this only runs inside a test container" >&2; exit 1; }
: "${CHAIN:?}"
export BRIDGE_OPERATOR_TEST_ONLY_SKIP_BUILDS=1
# shellcheck source=/dev/null
source "/src/chains/$CHAIN.env"
UNITS=/etc/systemd/system
ALL_OUTPUT=/tmp/all-output.log
: >"$ALL_OUTPUT"

step() { printf '\n=== %s\n' "$*"; }
check() {
  local desc=$1
  shift
  if "$@"; then
    echo "ok   $desc"
  else
    echo "FAIL $desc"
    exit 1
  fi
}
owner_mode() { [[ "$(stat -c '%U %a' "$1")" == "$2" ]]; }
has() { grep -q -- "$2" "$1"; }
# Runs a script, keeping its output for the secrets check at the end.
logged() { "$@" 2>&1 | tee -a "$ALL_OUTPUT"; }
# Every managed file's hash, and every managed path's owner, mode and time.
# (Paths a role doesn't create yet are skipped.)
managed_sums() {
  local p paths=()
  for p in "$UNITS" /etc/bridge-operator /etc/apt/apt.conf.d/20auto-upgrades /etc/ufw/user.rules \
    "$NODE_STATE" /opt/"$CHAIN" /opt/metal "$COIN_DATA" "$SIGNER_DIR"; do
    [[ -e $p ]] && paths+=("$p")
  done
  find "${paths[@]}" -type f -print0 | sort -z | xargs -0 -r sha256sum
  find "${paths[@]}" -printf '%p %U %m %T@\n' | sort
}
# same_as SNAPSHOT: the managed files are exactly as in SNAPSHOT.
same_as() {
  local now
  now=$(managed_sums)
  [[ $1 == "$now" ]] && return 0
  diff <(echo "$1") <(echo "$now") || true
  return 1
}
verify_units() {
  local u out
  for u in "$@"; do
    out=$(systemd-analyze verify "$UNITS/$u.service" 2>&1 || true)
    # Only this unit's own problems count; the container lacks the rest of
    # a booted system (and says so about other units).
    if grep -F "$u.service" <<<"$out" | grep -qv 'Unit is bound to inactive'; then
      echo "$out"
      echo "FAIL systemd-analyze verify $u"
      exit 1
    fi
    echo "ok   systemd-analyze verify $u.service"
  done
}

step "node role, test mode"
logged /src/install.sh --chain "$CHAIN" --role node
check "build user" id bridge-build
check "node user, no login shell" bash -c "getent passwd $NODE_USER | grep -q ':/usr/sbin/nologin$'"
check "node state 750, node-owned" owner_mode "$NODE_STATE" "$NODE_USER 750"
cfg=$NODE_STATE/chain-configs/$L1_CHAIN_ID/config.json
check "chain config 600, node-owned" owner_mode "$cfg" "$NODE_USER 600"
# shellcheck disable=SC2016 # jq variables
check "chain config: RPC user, random password, indexes" \
  jq -e --arg c "$CHAIN" '.rpcUser == $c and (.rpcPass | test("^[0-9a-f]{48}$")) and .txIndex and .addrIndex' "$cfg"
check "plugin in place under the VM ID, root-owned" owner_mode "/opt/$CHAIN/plugins/$L1_VM_ID" "root 755"
unit=$UNITS/$NODE_SERVICE.service
check "node unit tracks the L1 subnet" has "$unit" "--track-subnets=$L1_SUBNET_ID"
check "node unit: partial sync" has "$unit" "--partial-sync-primary-network=true"
check "node unit: APIs on localhost" has "$unit" "--http-host=127.0.0.1"
check "node unit: sandboxed" has "$unit" "ProtectSystem=strict"
check "node unit: empty capability set" has "$unit" "^CapabilityBoundingSet=$"
check "install.conf records the role" has /etc/bridge-operator/install.conf "^ROLE=node$"
check "automatic updates configured" has /etc/apt/apt.conf.d/20auto-upgrades 'Unattended-Upgrade "1"'
check "firewall rule: Metal staking port" has /etc/ufw/user.rules "9651"
command -v systemd-analyze >/dev/null || apt-get install -yq systemd >/dev/null
verify_units "$NODE_SERVICE"

step "re-run changes nothing"
before=$(managed_sums)
logged /src/install.sh --chain "$CHAIN" --role node >/dev/null
check "same files, owners, modes and times" same_as "$before"

step "signer role, test mode, on the same machine"
logged /src/install.sh --chain "$CHAIN" --role signer | tee /tmp/signer-run.log >/dev/null
check "coin user" id "$COIN_USER"
check "signer user" id "$SIGNER_USER"
check "coin data 750, coin-owned" owner_mode "$COIN_DATA" "$COIN_USER 750"
conf=$COIN_DATA/$COIN_CONF_NAME
check "coin config 600, coin-owned" owner_mode "$conf" "$COIN_USER 600"
check "coin config: rpcauth for the signer, no plain password" \
  bash -c "grep -q '^rpcauth=$SIGNER_USER:' '$conf' && ! grep -q '^rpcpassword=' '$conf'"
check "coin config: chain-specific settings" has "$conf" "^$(head -1 <<<"$COIN_CONF_EXTRA")$"
check "signer dir 700, signer-owned" owner_mode "$SIGNER_DIR" "$SIGNER_USER 700"
env=$SIGNER_DIR/signer.env
check "signer.env 600, signer-owned" owner_mode "$env" "$SIGNER_USER 600"
check "signer.env: L1 password = the chain config's" \
  test "$(sed -n "s/^${ENV_VM_PREFIX}_RPC_PASS=//p" "$env")" == "$(jq -r .rpcPass "$cfg")"
coin_pass=$(sed -n "s/^${ENV_COIN_PREFIX}_RPC_PASS=//p" "$env")
auth=$(sed -n "s/^rpcauth=$SIGNER_USER://p" "$conf")
check "signer.env: coin password matches the rpcauth HMAC" \
  test "$(printf '%s' "$coin_pass" | openssl dgst -sha256 -hmac "${auth%%\$*}" | awk '{print $NF}')" == "${auth#*\$}"
check "signer.env: chain's own RPC port" has "$env" "127.0.0.1:$COIN_RPC_PORT"
check "refund approvals file 600" owner_mode "$SIGNER_DIR/refund-approvals" "$SIGNER_USER 600"
check "no signer unit before the ceremony" test ! -e "$UNITS/$SIGNER_SERVICE.service"
check "tells the operator to run init as the signer user" \
  has /tmp/signer-run.log "sudo -u $SIGNER_USER -H $BRIDGE_BIN signer-setup init -dir $SIGNER_DIR"
check "no signer key made by the installer" test ! -e "$SIGNER_DIR/signer.key"
check "firewall rule: coin peers" has /etc/ufw/user.rules "$COIN_P2P_PORT"
check "signer port not opened to anyone yet" bash -c "! grep -q 9700 /etc/ufw/user.rules"
verify_units "$NODE_SERVICE" "$COIN_SERVICE"

step "re-run changes nothing (signer)"
before=$(managed_sums)
logged /src/install.sh --chain "$CHAIN" --role signer >/dev/null
check "same files, owners, modes and times" same_as "$before"

step "a node can't be switched back from signer"
check "refuses --role node" bash -c "! /src/install.sh --chain $CHAIN --role node >/dev/null 2>&1"

step "simulated end of the key ceremony (TEST placeholders, no key material)"
# What init and join leave behind, stood in for by placeholders: the real
# ones come from the bridge binary, which test mode doesn't build.
runuser -u "$SIGNER_USER" -- sh -c "umask 022; echo TEST-PLACEHOLDER-NOT-A-KEY > '$SIGNER_DIR/signer.key'; echo '{}' > '$SIGNER_DIR/signers.json'"
cat >"$SIGNER_DIR/$SIGNER_SERVICE.service" <<EOF
[Service]
ExecStart=/usr/local/bin/$BRIDGE_BIN signer -signers $SIGNER_DIR/signers.json -key-file $SIGNER_DIR/signer.key -listen 0.0.0.0:9700 -log $SIGNER_DIR/signing-log.json -deposits $SIGNER_DIR/deposits.json -max-daily 50000000
EOF
logged /src/install.sh --chain "$CHAIN" --role signer --signer-allow-from 198.51.100.7 >/dev/null
sunit=$UNITS/$SIGNER_SERVICE.service
check "signer unit created" test -f "$sunit"
check "signer unit keeps join's daily limit" has "$sunit" "-max-daily 50000000"
check "signer unit listens where join said" has "$sunit" "-listen 0.0.0.0:9700"
check "signer unit takes refund approvals" has "$sunit" "-refund-approvals $SIGNER_DIR/refund-approvals"
check "signer unit: only localhost, itself and the coordinator" has "$sunit" "^IPAddressAllow=localhost 192.0.2.10 198.51.100.7$"
check "signer unit: writes only its own directory" has "$sunit" "^ReadWritePaths=$SIGNER_DIR$"
check "key file now 600, signer-owned" owner_mode "$SIGNER_DIR/signer.key" "$SIGNER_USER 600"
check "firewall: signer port open to the coordinator only" \
  bash -c "grep -A1 '9700' /etc/ufw/user.rules | grep -q '198.51.100.7'"
verify_units "$NODE_SERVICE" "$COIN_SERVICE" "$SIGNER_SERVICE"
logged /src/install.sh --chain "$CHAIN" --role signer >/dev/null
check "re-run without the flag keeps the coordinator's address" has "$sunit" "198.51.100.7"

step "check.sh (nothing is running here, so it must fail, cleanly)"
set +e
logged /src/check.sh --offline >/tmp/check.log
rc=$?
set -e
cat /tmp/check.log
check "check.sh exits 1" test "$rc" -eq 1
check "check.sh has no script errors" \
  bash -c "! grep -Eq 'unbound variable|syntax error|command not found|jq: error|integer expression' /tmp/check.log"

step "backup round trip"
age-keygen -o /root/test-identity.txt 2>/dev/null
recipient=$(age-keygen -y /root/test-identity.txt)
logged /src/backup.sh setup "$recipient"
backup=$(find /var/backups/bridge-operator -name "$CHAIN-*.tar.age" | head -1)
check "encrypted backup written, 600" owner_mode "$backup" "root 600"
check "timer written" test -f "$UNITS/bridge-operator-backup.timer"
check "timer: hourly for a signer" has "$UNITS/bridge-operator-backup.timer" "OnCalendar=hourly"
check "backup is not readable without the identity" bash -c "! age -d '$backup' >/dev/null 2>&1"
logged /src/backup.sh verify "$backup" /root/test-identity.txt >/tmp/verify.log
cat /tmp/verify.log
check "verify: every file matches the manifest" has /tmp/verify.log "every file matches its manifest"
check "backup holds the key file" has /tmp/verify.log "$SIGNER_DIR/signer.key"
check "backup holds the signer set" has /tmp/verify.log "$SIGNER_DIR/signers.json"
check "backup holds the node identity dir or config" has /tmp/verify.log "chain-configs/$L1_CHAIN_ID/config.json"

step "no secret ever printed"
for secret in "$(jq -r .rpcPass "$cfg")" "$coin_pass" TEST-PLACEHOLDER-NOT-A-KEY; do
  check "a secret is absent from all script output" bash -c "! grep -qF -- '$secret' '$ALL_OUTPUT'"
done

echo
echo "ALL CHECKS PASSED ($CHAIN)"
