#!/usr/bin/env bash
# Read-only health check for a node or peg signer set up by install.sh:
#
#   sudo ./check.sh [--offline]
#
# Services up, nodes synced (with progress), the L1 bootstrapped, the signer
# answering and refusing unauthenticated requests (using the bridge's own
# "signer-setup check"), disk space, clock, firewall and backups. It changes
# nothing. Exits 1 if any check FAILs; WARN is for things that need a look
# or are still in progress (such as a first sync).
#
# --offline skips the one outside call: comparing the L1's height with the
# bridge's public site.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"

OFFLINE=0
case ${1:-} in
  --offline) OFFLINE=1 ;;
  '') ;;
  -h | --help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown argument: $1" ;;
esac
[[ $EUID -eq 0 ]] || die "run as root (it reads the node's RPC settings and runs checks as the service users): sudo ./check.sh"
load_install_conf

FAILS=0 WARNS=0
ok() { printf '  %s[ ok ]%s %s\n' "$GREEN" "$RESET" "$*"; }
wrn() {
  printf '  %s[warn]%s %s\n' "$YELLOW" "$RESET" "$*"
  WARNS=$((WARNS + 1))
}
bad() {
  printf '  %s[FAIL]%s %s\n' "$RED" "$RESET" "$*"
  FAILS=$((FAILS + 1))
}
section() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }
unit_exists() { [[ -f /etc/systemd/system/$1.service ]]; }

check_service() {
  local name=$1 state
  state=$(systemctl is-active "$name.service" 2>/dev/null || true)
  if [[ $state == active ]]; then
    ok "$name is running (since $(systemctl show -p ActiveEnterTimestamp --value "$name.service" 2>/dev/null))"
  else
    bad "$name is ${state:-unknown}: journalctl -u $name -n 50"
  fi
  if [[ $(systemctl is-enabled "$name.service" 2>/dev/null || true) != enabled ]]; then
    wrn "$name does not start at boot: systemctl enable $name"
  fi
}

# --- Services -------------------------------------------------------------------
section "$CHAIN_TITLE $ROLE on $(hostname)"
check_service "$NODE_SERVICE"
if [[ $ROLE == signer ]]; then
  check_service "$COIN_SERVICE"
  if unit_exists "$SIGNER_SERVICE"; then
    check_service "$SIGNER_SERVICE"
  elif [[ -f $SIGNER_KEY ]]; then
    wrn "$SIGNER_SERVICE is not set up yet: finish the ceremony (signer-setup join), then re-run install.sh"
  else
    wrn "$SIGNER_SERVICE is not set up yet: no signer key; start the ceremony with signer-setup init (GUIDE.md)"
  fi
fi

# --- Metal node and the L1 ------------------------------------------------------
section "Metal node and the $CHAIN_TITLE L1"
node_id=$(metal_call info info.getNodeID | jq -r '.result.nodeID // empty' 2>/dev/null || true)
if [[ -z $node_id ]]; then
  bad "the Metal node's API ($NODE_API) is not answering"
else
  ok "NodeID $node_id ($(metal_call info info.getNodeVersion | jq -r '.result.version // "version unknown"' 2>/dev/null))"
  peers=$(metal_call info info.peers | jq -r '.result.numPeers // 0' 2>/dev/null || echo 0)
  if [[ ${peers:-0} -gt 0 ]]; then ok "$peers peers"; else wrn "no peers yet"; fi

  p_boot=$(metal_call info info.isBootstrapped '{"chain":"P"}' | jq -r '.result.isBootstrapped // empty' 2>/dev/null || true)
  if [[ $p_boot == true ]]; then
    ok "P-Chain synced"
  else
    wrn "P-Chain still syncing (partial sync of the primary network; usually under an hour)"
  fi

  l1_reply=$(metal_call info info.isBootstrapped "{\"chain\":\"$L1_CHAIN_ID\"}" || true)
  l1_boot=$(jq -r '.result.isBootstrapped // empty' <<<"$l1_reply" 2>/dev/null || true)
  if [[ $l1_boot == true ]]; then
    ok "$CHAIN_TITLE L1 bootstrapped ($L1_CHAIN_ID)"
  elif [[ $l1_boot == false ]]; then
    wrn "$CHAIN_TITLE L1 still bootstrapping"
  elif [[ $p_boot != true ]]; then
    wrn "$CHAIN_TITLE L1 not started yet: it starts once the P-Chain has synced"
  else
    bad "the node does not know the $CHAIN_TITLE L1: $(jq -r '.error.message // "no answer"' <<<"$l1_reply" 2>/dev/null)"
  fi

  if [[ $l1_boot == true ]]; then
    rpc_pass=$(jq -r '.rpcPass // empty' "$CHAIN_CONFIG" 2>/dev/null || true)
    height=$(curl -s -m 10 -u "$CHAIN:$rpc_pass" -H 'content-type: application/json' \
      -d '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "$L1_RPC_URL" |
      jq -r '.result // empty' 2>/dev/null || true)
    if [[ -z $height ]]; then
      bad "the L1's JSON-RPC ($L1_RPC_URL) is not answering"
    elif ((OFFLINE)); then
      ok "L1 JSON-RPC answering on localhost, height $height"
    else
      public=$(curl -s -m 10 -u "$PUBLIC_RPC_USER:$PUBLIC_RPC_PASS" -H 'content-type: application/json' \
        -d '{"jsonrpc":"1.0","id":1,"method":"getblockcount","params":[]}' "$PUBLIC_RPC_URL" |
        jq -r '.result // empty' 2>/dev/null || true)
      if [[ -z $public ]]; then
        ok "L1 JSON-RPC answering on localhost, height $height ($PUBLIC_RPC_URL not reachable to compare)"
      elif ((height + 2 >= public)); then
        ok "L1 JSON-RPC answering on localhost, height $height (public site: $public)"
      else
        wrn "L1 height $height, $((public - height)) blocks behind $SITE"
      fi
    fi
  fi
fi

# --- The chain's own coin daemon ------------------------------------------------
if [[ $ROLE == signer ]]; then
  section "$COIN_NAME"
  if ! info_json=$(coin_cli getblockchaininfo 2>/dev/null); then
    bad "$COIN_NAME is not answering: journalctl -u $COIN_SERVICE -n 50"
  else
    blocks=$(jq -r .blocks <<<"$info_json")
    headers=$(jq -r .headers <<<"$info_json")
    progress=$(jq -r '(.verificationprogress * 1000 | floor) / 10' <<<"$info_json")
    # Dogecoin Core 1.14 has neither initialblockdownload nor size_on_disk.
    ibd=$(jq -r '.initialblockdownload // (.verificationprogress < 0.9999)' <<<"$info_json")
    disk=$(jq -r 'if .size_on_disk then "\(.size_on_disk / 1e9 | floor) GB on disk" else "" end
      + if .pruned then ", pruned" else "" end' <<<"$info_json")
    if [[ $ibd == true || $blocks -lt $((headers - 2)) ]]; then
      wrn "first sync in progress: block $blocks of $headers, ${progress}% verified${disk:+ ($disk)}"
    else
      best_time=$(coin_cli getblockheader "$(coin_cli getbestblockhash)" | jq -r .time)
      age_min=$((($(date +%s) - best_time) / 60))
      if ((age_min > COIN_STALE_MINUTES)); then
        wrn "synced to block $blocks, but the newest block is $age_min minutes old"
      else
        ok "synced: block $blocks, newest $age_min minutes old${disk:+ ($disk)}"
      fi
    fi
    conns=$(coin_cli getconnectioncount 2>/dev/null || echo 0)
    if [[ $conns -gt 0 ]]; then ok "$conns peers"; else wrn "no peers"; fi
  fi
fi

# --- The signer -------------------------------------------------------------------
if [[ $ROLE == signer ]]; then
  section "Peg signer"
  if [[ -f $SIGNER_KEY ]]; then
    perms=$(stat -c '%U %a' "$SIGNER_KEY")
    if [[ $perms == "$SIGNER_USER 600" ]]; then
      ok "key file $SIGNER_KEY: owner $SIGNER_USER, mode 600"
    else
      bad "key file $SIGNER_KEY is '$perms', should be '$SIGNER_USER 600': re-run install.sh"
    fi
  fi
  dperms=$(stat -c '%U %a' "$SIGNER_DIR" 2>/dev/null || true)
  [[ $dperms == "$SIGNER_USER 700" ]] || bad "$SIGNER_DIR is '$dperms', should be '$SIGNER_USER 700'"

  if [[ -f $SIGNER_DIR/paused.json ]]; then
    wrn "this signer is PAUSED: $(jq -r '"since \(.since): \(.reason)"' "$SIGNER_DIR/paused.json" 2>/dev/null)"
  fi

  if unit_exists "$SIGNER_SERVICE"; then
    listen=$(sed -n 's/.* -listen \([^ ]*\).*/\1/p' "/etc/systemd/system/$SIGNER_SERVICE.service")
    port=${listen##*:}
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:${port:-$SIGNER_PORT}/v1/status" || true)
    case $code in
      401) ok "signer answering on port ${port:-$SIGNER_PORT}, and refusing an unauthenticated request (401)" ;;
      200) bad "signer answered an unauthenticated request: check its signer set has a coordinator key" ;;
      000 | '') bad "signer not answering on port ${port:-$SIGNER_PORT}" ;;
      *) wrn "signer answered HTTP $code to an unauthenticated request (expected 401)" ;;
    esac

    # The bridge's own check: key file, set membership, both nodes (and
    # that the coin node is synced), and the service at the card's URL.
    # shellcheck disable=SC2016 # $1..$3 belong to the inner shell
    report=$(runuser -u "$SIGNER_USER" -- bash -c 'set -a; . "$1"; set +a; cd "$3"; exec "$2" signer-setup check -dir "$3"' \
      _ "$SIGNER_ENV" "$BRIDGE_BIN_PATH" "$SIGNER_DIR" 2>/dev/null || true)
    if jq -e 'type == "array"' <<<"$report" >/dev/null 2>&1; then
      while IFS=$'\t' read -r okv name detail; do
        if [[ $okv == true ]]; then
          ok "$BRIDGE_BIN signer-setup check: $name: $detail"
        elif [[ $name == *node* && $detail == *syncing* ]]; then
          wrn "$BRIDGE_BIN signer-setup check: $name: $detail"
        else
          bad "$BRIDGE_BIN signer-setup check: $name: $detail"
        fi
      done < <(jq -r '.[] | [.ok, .check, .detail] | @tsv' <<<"$report")
    else
      bad "$BRIDGE_BIN signer-setup check did not run: sudo -u $SIGNER_USER -H $BRIDGE_BIN signer-setup check -dir $SIGNER_DIR"
    fi

    if ufw status 2>/dev/null | grep -q "^$SIGNER_PORT/tcp .*ALLOW"; then
      ok "firewall lets the coordinator reach port $SIGNER_PORT ($(ufw status | awk -v p="$SIGNER_PORT/tcp" '$1 == p {print $NF}' | sort -u | tr '\n' ' '))"
    else
      wrn "no firewall rule lets the coordinator reach port $SIGNER_PORT: re-run install.sh with --signer-allow-from COORDINATOR_IP"
    fi
  fi
fi

# --- The host ------------------------------------------------------------------
section "Host"
check_disk() {
  local dir=$1 label=$2 line free_gb pct_used
  [[ -d $dir ]] || return 0
  line=$(df -P -BG "$dir" | awk 'NR==2')
  free_gb=$(awk '{sub("G","",$4); print $4}' <<<"$line")
  pct_used=$(awk '{sub("%","",$5); print $5}' <<<"$line")
  if ((pct_used >= 95)); then
    bad "disk for $label ($dir): ${free_gb} GB free, ${pct_used}% used"
  elif ((pct_used >= 85 || free_gb < 20)); then
    wrn "disk for $label ($dir): ${free_gb} GB free, ${pct_used}% used"
  else
    ok "disk for $label ($dir): ${free_gb} GB free, ${pct_used}% used"
  fi
}
check_disk "$NODE_STATE" "the Metal node"
[[ $ROLE == signer ]] && check_disk "$COIN_DATA" "$COIN_NAME"

if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null || true) == yes ]]; then
  ok "clock synchronised (the signer refuses requests more than 5 minutes off)"
else
  wrn "clock not synchronised: timedatectl status"
fi
if ufw status 2>/dev/null | grep -q '^Status: active'; then ok "firewall on"; else wrn "firewall (ufw) is off"; fi
if [[ $(systemctl is-enabled unattended-upgrades.service 2>/dev/null || true) == enabled ]]; then
  ok "automatic security updates on"
else
  wrn "unattended-upgrades is not enabled"
fi
[[ -f /var/run/reboot-required ]] && wrn "a reboot is pending (usually a kernel update); plan one"
if command -v sshd >/dev/null 2>&1; then
  if sshd -T 2>/dev/null | grep -qi '^passwordauthentication no'; then
    ok "SSH: password login off"
  else
    wrn "SSH: password login is on; add a key and re-run install.sh"
  fi
fi

# --- Backups ---------------------------------------------------------------------
section "Backups"
newest=$(find "$BACKUP_DIR" -maxdepth 1 -name "$CHAIN-*.tar.age" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 || true)
missing_backup() { if [[ $ROLE == signer ]]; then bad "$*"; else wrn "$*"; fi; }
if [[ -z $newest ]]; then
  missing_backup "no backups yet: sudo ./backup.sh setup AGE_RECIPIENT (GUIDE.md, Backups)"
else
  age_h=$((($(date +%s) - ${newest%%.*}) / 3600))
  if ((age_h > 26)); then
    missing_backup "newest backup is $age_h hours old: ${newest#* }"
  else
    ok "newest backup $age_h hours old: ${newest#* }"
  fi
fi
if [[ $(systemctl is-enabled bridge-operator-backup.timer 2>/dev/null || true) == enabled ]]; then
  ok "backup timer on"
else
  missing_backup "backup timer off: sudo ./backup.sh setup AGE_RECIPIENT"
fi
[[ -s $CONF_DIR/backup-offsite ]] || wrn "backups stay on this server only; add an offsite copy (GUIDE.md, Backups)"

echo
if ((FAILS)); then
  printf '%s%d failed%s, %d to look at\n' "$RED" "$FAILS" "$RESET" "$WARNS"
  exit 1
fi
printf '%sno failures%s, %d to look at\n' "$GREEN" "$RESET" "$WARNS"
