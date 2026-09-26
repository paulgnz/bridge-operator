#!/usr/bin/env bash
# Tests the scripts in throwaway ubuntu:24.04 (x86_64) containers:
#
#   test/container-test.sh            # everything below
#   test/container-test.sh dry-run    # only the four dry runs
#
# 1. install.sh --dry-run for every chain and role, on a fresh image.
# 2. The installer's early steps for real, in TEST MODE
#    (BRIDGE_OPERATOR_TEST_ONLY_SKIP_BUILDS=1: no downloads, builds, syncs,
#    systemd, firewall or SSH): users, directories, permissions, configs and
#    unit files, checked with systemd-analyze verify; a re-run changes nothing;
#    a simulated end of the key ceremony makes the signer unit appear.
#    Then check.sh runs (it must fail cleanly: nothing is running), and
#    backup.sh setup/run/verify round-trips an encrypted backup.
#
# Needs docker with linux/amd64 (native, or emulated). Logs go to test/out/.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
OUT=$HERE/out
mkdir -p "$OUT"
IMAGE=${IMAGE:-ubuntu:24.04}
DOCKER=(docker run --rm --platform linux/amd64 -v "$REPO:/src:ro")
FAILED=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() {
  printf 'FAIL  %s\n' "$*"
  FAILED=1
}

dry_runs() {
  local chain role log
  for chain in btcvm dogevm; do
    for role in node signer; do
      log=$OUT/dry-run-$chain-$role.log
      if "${DOCKER[@]}" "$IMAGE" /src/install.sh --chain "$chain" --role "$role" --dry-run >"$log" 2>&1; then
        # A dry run must change nothing: no users, no files.
        if grep -q '+ useradd' "$log" && grep -q "+ write /etc/systemd/system/$chain-node.service" "$log"; then
          pass "dry run: $chain $role ($(grep -c '^    + ' "$log") actions, log $log)"
        else
          fail "dry run: $chain $role printed no actions (log $log)"
        fi
      else
        fail "dry run: $chain $role exited non-zero (log $log)"
      fi
    done
  done
  # A dry run on the machine it runs on changes nothing.
  log=$OUT/dry-run-no-change.log
  if "${DOCKER[@]}" "$IMAGE" bash -c '
      /src/install.sh --chain btcvm --role signer --dry-run >/dev/null 2>&1
      ! id btcvm-node 2>/dev/null && ! test -e /etc/bridge-operator && ! test -e /opt/btcvm' >"$log" 2>&1; then
    pass "dry run changes nothing on the machine"
  else
    fail "dry run left something behind (log $log)"
  fi
}

# The in-container half of the real (test-mode) run; see inside.
real_run() {
  local chain=$1
  local log=$OUT/test-mode-$chain.log
  if "${DOCKER[@]}" -e CHAIN="$chain" "$IMAGE" bash /src/test/in-container.sh >"$log" 2>&1; then
    pass "test-mode install, checks, re-run, ceremony hand-off, backup round trip: $chain (log $log)"
  else
    fail "test-mode run: $chain (log $log; tail below)"
    tail -25 "$log"
  fi
}

case ${1:-all} in
  dry-run) dry_runs ;;
  all)
    dry_runs
    real_run btcvm
    real_run dogevm
    ;;
  *) echo "usage: $0 [all|dry-run]" >&2; exit 2 ;;
esac
exit "$FAILED"
