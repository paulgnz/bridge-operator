#!/usr/bin/env bash
# The real installer, end to end, in a throwaway ubuntu:24.04
# (linux/amd64) container running systemd:
#
#   test/real-install-test.sh btcvm|dogevm
#
# No test mode: it downloads Go and the coin daemon (checking their pinned
# SHA-256), builds metalgo and the bridge at their pinned commits, checks
# the VM ID, writes everything, enables the firewall inside the container,
# and starts the sandboxed services under systemd. It then waits a few
# minutes and records whether each service stays up under its sandbox, what
# check.sh says, and the services' logs, and removes the container.
#
# The node and the coin daemon begin syncing mainnet from this machine
# while it runs (outbound only; the node advertises a documentation-only
# address, 192.0.2.10). Expect 20 to 60 minutes, mostly the Go builds.
# Output goes to test/out/real-<chain>.log. Docker needs 20 GB or more free:
# the coin daemon starts its first sync and will fill a small disk.
set -euo pipefail

CHAIN=${1:?usage: test/real-install-test.sh btcvm|dogevm}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
OUT=$HERE/out
mkdir -p "$OUT"
NAME=bridge-operator-real-$CHAIN
IMAGE=bridge-operator-systemd:24.04
RUN_MINUTES=${RUN_MINUTES:-4}

docker build -q --platform linux/amd64 -t "$IMAGE" - >/dev/null <<'EOF'
FROM ubuntu:24.04
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -yq systemd systemd-sysv dbus sudo \
 && rm -f /etc/systemd/system/*.wants/* /lib/systemd/system/multi-user.target.wants/getty* \
 && systemctl mask systemd-logind.service getty.target console-getty.service \
    systemd-binfmt.service proc-sys-fs-binfmt_misc.automount proc-sys-fs-binfmt_misc.mount
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF

docker rm -f "$NAME" >/dev/null 2>&1 || true
# KEEP=1 leaves the container running for inspection (docker exec -it NAME bash).
[[ ${KEEP:-0} == 1 ]] || trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
# Not --privileged: a privileged systemd can reset the host kernel's
# binfmt_misc handlers, which breaks amd64 emulation for every container.
# These capabilities are what systemd, ufw and the units' sandboxing need.
docker run -d --name "$NAME" --platform linux/amd64 --cgroupns=host \
  --cap-add SYS_ADMIN --cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_RESOURCE \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v "$REPO:/src:ro" --tmpfs /run --tmpfs /run/lock "$IMAGE" >/dev/null
ct() { docker exec "$NAME" "$@"; }
for _ in $(seq 30); do
  state=$(ct systemctl is-system-running 2>/dev/null || true)
  [[ $state == running || $state == degraded ]] && break
  sleep 2
done

# EMULATION ONLY: under Rosetta or qemu every x86_64 program runs through a
# translator that needs memory both writable and executable, so
# MemoryDenyWriteExecute=yes kills even /bin/true. This drop-in lifts that
# one option inside the test container; every other sandbox option stays.
# On a real x86_64 host there is no translator and no drop-in.
if [[ $(uname -m) != x86_64 ]]; then
  # shellcheck source=/dev/null
  for unit in $(. "$REPO/chains/$CHAIN.env" && echo "$NODE_SERVICE $COIN_SERVICE $SIGNER_SERVICE"); do
    ct mkdir -p "/etc/systemd/system/$unit.service.d"
    ct sh -c "printf '[Service]\n# TEST ONLY: x86_64 emulation needs W+X memory\nMemoryDenyWriteExecute=no\n' >/etc/systemd/system/$unit.service.d/emulation-test-only.conf"
  done
  EMULATED=1
  # Emulators lack ADX/BMI2, which blst (in metalgo) uses unless built
  # portable; real x86_64 servers have them.
  BUILD_ENV=(env CGO_CFLAGS="-O -D__BLST_PORTABLE__")
else
  EMULATED=0
  BUILD_ENV=()
fi

{
  echo "=== systemd: $(ct systemctl is-system-running 2>/dev/null || true)"
  ((EMULATED)) && echo "=== emulated x86_64: MemoryDenyWriteExecute lifted by a test-only drop-in; blst built portable"
  echo "=== install.sh --chain $CHAIN --role signer (real)"
  start=$(date +%s)
  ct ${BUILD_ENV[@]+"${BUILD_ENV[@]}"} /src/install.sh --chain "$CHAIN" --role signer --public-ip 192.0.2.10
  echo "=== install took $((($(date +%s) - start) / 60)) minutes"

  echo "=== re-run (should rebuild nothing, restart nothing)"
  ct ${BUILD_ENV[@]+"${BUILD_ENV[@]}"} /src/install.sh --chain "$CHAIN" --role signer --public-ip 192.0.2.10

  echo "=== letting the services run for $RUN_MINUTES minutes"
  sleep $((RUN_MINUTES * 60))
  # shellcheck source=/dev/null
  for unit in $(. "$REPO/chains/$CHAIN.env" && echo "$NODE_SERVICE $COIN_SERVICE"); do
    echo "--- $unit: $(ct systemctl is-active "$unit" || true), restarts: $(ct systemctl show -p NRestarts --value "$unit")"
    ct systemctl show -p ActiveEnterTimestamp,ExecMainStatus --value "$unit" || true
    ct journalctl -u "$unit" --no-pager -n 25 || true
    echo "--- sandbox exposure score (lower is better):"
    ct systemd-analyze security --no-pager "$unit" | tail -1 || true
  done
  # shellcheck source=/dev/null
  state_dir=$(. "$REPO/chains/$CHAIN.env" && echo "${NODE_STATE:?}")
  # shellcheck source=/dev/null
  chain_id=$(. "$REPO/chains/$CHAIN.env" && echo "$L1_CHAIN_ID")
  echo "=== node logs: the L1 and any errors"
  ct sh -c "ls $state_dir/logs; grep -ahiE 'error|fatal|panic|$chain_id|subnet|plugin|vm' $state_dir/logs/main.log | tail -40" || true
  ct sh -c "tail -20 $state_dir/logs/$chain_id.log 2>/dev/null" || true
  echo "=== check.sh"
  ct /src/check.sh || true
  echo "=== ufw"
  ct ufw status verbose || true
} 2>&1 | tee "$OUT/real-$CHAIN.log"
