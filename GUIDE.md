# Operator guide

How to run a node or a peg signer for the two Metal Blockchain bridges,
**BTCVM** (BTC) and **DogecoinVM** (DOGE). It is written for a technically
capable operator who has never seen this project: someone comfortable with
Linux servers, SSH and systemd, but not with these bridges.

Contents:

1. [What the bridges are](#1-what-the-bridges-are)
2. [What an operator does: node or signer](#2-what-an-operator-does-node-or-signer)
3. [The trust model](#3-the-trust-model)
4. [Status today](#4-status-today)
5. [Requirements and costs](#5-requirements-and-costs)
6. [Step by step](#6-step-by-step)
7. [Verification](#7-verification)
8. [Monitoring and alerts](#8-monitoring-and-alerts)
9. [Backups and a restore drill](#9-backups-and-a-restore-drill)
10. [Upgrades](#10-upgrades)
11. [Pausing in an emergency](#11-pausing-in-an-emergency)
12. [Incident checklist](#12-incident-checklist)
13. [What never to do](#13-what-never-to-do)
14. [Becoming a validator](#14-becoming-a-validator)
15. [Reference](#15-reference)

---

## 1. What the bridges are

Each bridge is an **L1 on Metal Blockchain mainnet**: a separate chain with
its own validators, whose ledger works like Bitcoin's (BTCVM) or
Dogecoin's (DogecoinVM): the same addresses, keys and scripts, but with
Metal's consensus in place of proof of work. Neither chain has a block
reward or a premine. Coins get onto them only through a **two-way peg**:

- **Peg-in.** A user sends BTC (or DOGE) to a deposit address on Bitcoin
  (or Dogecoin). The coins are locked there under an m-of-n multisig of
  **peg signers**. Once the deposit has enough confirmations, the same
  amount is released to the user on the L1 from a **reserve**, which is
  locked to the same multisig.
- **Peg-out.** The user pays coins back into the reserve on the L1,
  naming an address on Bitcoin (or Dogecoin). The signers pay that
  address from the locked coins.

A process called the **coordinator** watches both chains, works out what
the bridge owes, builds each transaction, and asks the signers to sign
it. It holds no keys. With enough signatures it broadcasts the
transaction.

| | BTCVM | DogecoinVM |
|---|---|---|
| Site | https://metalbtc.com | https://metaldoge.com |
| Source | [paulgnz/btcvm](https://github.com/paulgnz/btcvm), branch `feature/bitcoin-bridge` | [MetalBlockchain/dogecoin-vm](https://github.com/MetalBlockchain/dogecoin-vm), branch `dogecoin` |
| L1 chain ID | `BYogm85qvZxwX4PitKLDPzNDbAgo61nw2NSXx5VVXyZZ8yGUK` | `2hFCfzdMmfXBxYgvvdL7BYiJAxdejyn4AksMYUM2eM5gN7Xrjy` |
| Subnet ID | `SWJQGgyAvXY1aBczr7WupCGpLmukvP2YdXZJUvqm1td37EcJm` | `2t2zEB1T3mNUE2WoheMFMjfhAvQJawtgiwnKPJz2NsFk7FDgyN` |
| Coin daemon a signer runs | Bitcoin Core 31.1, pruned | Dogecoin Core 1.14.9, with `-txindex` |
| Command-line tool | `btcvm` | `dogevm` |

The design documents in each source repository go deeper:
`docs/BRIDGE.md` (the peg), `docs/SIGNERS.md` (separate signers and the
key ceremony) and `docs/RUNBOOK.md` (the maintainers' own runbook).
Every per-chain value this repository uses is in
[`chains/btcvm.env`](chains/btcvm.env) and
[`chains/dogevm.env`](chains/dogevm.env).

## 2. What an operator does: node or signer

This repository sets up one of two roles on a server of your own. One
chain per server: pick BTCVM or DogecoinVM.

**Node** (`--role node`). A Metal mainnet node that syncs Metal's
P-Chain (not the whole primary network) and follows the bridge's L1,
with the L1's plugin built from source. It serves the L1's JSON-RPC on
localhost, for you. A node checks every L1 block for itself, which is
useful on its own: to read the chain without trusting anyone else's
server, and as the first half of a signer. It does **not** validate
(see [section 14](#14-becoming-a-validator)) and holds no keys that
matter to the bridge.

**Peg signer** (`--role signer`). Everything a signer needs, on its own
machine:

- the node above;
- the chain's own coin daemon: Bitcoin Core (pruned) for BTCVM, or
  Dogecoin Core (with a full transaction index) for DogecoinVM;
- the bridge's command-line tool, and after the key ceremony, the
  **signer service**, which holds **one** of the multisig keys.

For every request from the coordinator, the signer checks both chains
**through its own nodes**, confirms the transaction is one the bridge
actually owes (a confirmed deposit not yet credited, a final peg-out not
yet paid, or a refund its operator approved), rebuilds the transaction
itself and signs only if it matches byte for byte, checks its signing
log so it never helps pay the same thing twice, and applies its own
daily limit. That independence is the point: a signer that used someone
else's node would be trusting that node's operator.

As a signer operator you: keep the server patched and running, keep the
key safe and backed up, watch the health checks, approve refunds you
have checked yourself, take part in upgrades and key ceremonies, and
pause your signer when something looks wrong.

## 3. The trust model

This is a **federated peg**. Be clear-eyed about what that means:

- **m of the n signers, together, can move all locked coins.** Nothing
  in Bitcoin or Dogecoin stops them. The public audit (`btcvm audit`,
  and proof of reserves on the sites) would show it, but cannot prevent
  it.
- **Fewer than m signers can move nothing.** A single compromised signer
  cannot steal; it can only refuse to sign.
- **The coordinator can move nothing.** It holds no keys, and every
  signer rebuilds and checks what it is asked to sign. A compromised
  coordinator can delay transfers, not redirect them.
- **Each signer trusts only its own nodes.** That is why a signer runs
  its own Metal node and its own Bitcoin Core or Dogecoin Core.
- **Any one signer can halt the bridge's progress** once fewer than m
  signers are willing, by pausing. Nothing is lost by a pause; deposits
  and withdrawals wait.

The security of the peg is therefore the security of the weakest m
signers. Independent operators, each with their own key on their own
hardware under their own control, are what make it more than a single
point of failure.

## 4. Status today

Stated plainly, as of this writing:

- **Both bridges are live betas** on Metal mainnet with real BTC and
  DOGE, and small caps on what they accept: a largest deposit and a
  most-circulating total, shown on each site and at `/api/info`
  (DogecoinVM: 100 DOGE per deposit, 1,000 DOGE circulating). The code
  has not been audited.
- **Every peg signer key sits on one server** run by the maintainers. A
  compromise of that server exposes all of them; the caps bound the
  loss. This is the weakness this repository exists to fix.
- **This repository brings in independent signers.** The ceremony
  tooling (`signer-setup`) is built, and a signer set up here can take
  part in it today. How your key becomes part of the *live* peg is the
  maintainers' call, and has a gap you should know about: the bridge
  cannot yet move the locked coins to a new signer set (key rotation is
  the next piece of work). Until it can, a fresh key made on your
  machine can join a new signer set but not the live one, and the
  alternative, importing one of the existing keys, is weaker, because
  those keys were once stored together.
- **The validator path is not ready.** Your node follows the L1 but
  does not validate it (section 14).
- **This repository is new.** The installer has been exercised in
  containers (see `test/`), not yet on many real servers. Run the dry
  run first and read what it will do.

## 5. Requirements and costs

**Server.** A dedicated Ubuntu 24.04 LTS x86_64 server (a VPS or bare
metal) that runs nothing else, with SSD or NVMe storage, a public IPv4
address, and SSH access with a key. One chain per server.

| Role | CPU | RAM | Disk | Notes |
|---|---|---|---|---|
| Node (either chain) | 4 vCPU | 8 GB | 100 GB SSD | The node itself needs tens of GB. |
| BTCVM signer | 4–8 vCPU | 16–32 GB | 150 GB+ SSD | Bitcoin Core pruned to ~60 GB of blocks, plus its chain state and the node. |
| DogecoinVM signer | 4–8 vCPU | 16 GB | **400 GB+ SSD** | Dogecoin Core keeps the whole chain with a transaction index: about 260 GB in late 2026, and growing. |

**Network.** Bitcoin Core downloads and checks the whole Bitcoin chain
once (well over 600 GB), even though it keeps only the recent part.
Dogecoin Core downloads its whole chain (a few hundred GB). After that,
traffic is modest, but a full node uploads blocks to peers: Bitcoin Core
is capped here at about 20 GB a day (`maxuploadtarget` in
`/var/lib/bitcoind/bitcoin.conf`); lower it if your bandwidth is
metered.

**Rough monthly cost.** Prices vary a lot by provider and change often;
treat these as ranges and check current pricing:

| Role | Budget VPS / dedicated host | Large cloud provider |
|---|---|---|
| Node | about US$15–30 | about US$60–120 |
| BTCVM signer | about US$30–80 | about US$150–300 |
| DogecoinVM signer | about US$40–100 (the disk is most of it) | about US$200–350 |

Big-cloud figures include block storage; egress fees during the first
sync can add a one-off cost on providers that charge for it.

**Time.** Installing takes 20–40 minutes (mostly compiling). Then the
syncs: Metal's P-Chain in under an hour or so, Bitcoin Core about a day
(sometimes more), Dogecoin Core several hours to a day. The key ceremony
takes an hour of your time, spread over however long it takes all
signers to be ready.

**You.** Someone who can respond to an alert within hours, not days;
who will keep the backup identity safe; and who can join a call with
the other signers to confirm a fingerprint.

## 6. Step by step

### 6.1 Provision the server

1. Create the server: Ubuntu 24.04 LTS, x86_64, with your SSH public key
   installed. Give it a DNS name you control (for example
   `signer.example.com`); the name goes into your signer card, and a
   name survives an IP change where an address would not.
2. Log in over SSH **with your key**, and update it:
   `sudo apt update && sudo apt full-upgrade -y && sudo reboot`.
3. If your provider has its own firewall in front of the server, allow
   inbound: TCP 22 (SSH), TCP 9651 (Metal peers), and for a signer TCP
   8333 (BTCVM) or 22556 (DogecoinVM) for coin peers, and TCP 9700 from
   the coordinator's address only. The installer sets up the same rules
   on the server itself with ufw.
4. For a DogecoinVM signer on a small server: attach a volume of 400 GB
   or more and mount it at `/var/lib/dogecoind` **before** installing.

### 6.2 Get this repository

```sh
sudo git clone <this repository's URL> /opt/bridge-operator
cd /opt/bridge-operator
git log -1 --format='%H %s'
```

Check with the maintainers that the commit you have is the one they
announced, and read the scripts: they are short, and they will run as
root.

### 6.3 Run the installer

First, see exactly what it will do. A dry run changes nothing:

```sh
sudo ./install.sh --chain btcvm --role signer --dry-run | less
```

Then run it for real (use `dogevm` for DogecoinVM, `node` for a node):

```sh
sudo ./install.sh --chain btcvm --role signer
```

What it does, in order:

1. Checks this is Ubuntu 24.04 on x86_64, and warns if the disk looks
   too small.
2. Installs a few packages (git, jq, curl, a compiler, age, ufw,
   unattended-upgrades, time sync).
3. Creates a system user per service, none of which can log in:
   `bridge-build` (compiles), `btcvm-node` (the Metal node), and for a
   signer `bitcoind` and `btcvm-signer`. (`dogevm-node`, `dogecoind` and
   `dogevm-signer` for DogecoinVM.)
4. Installs Go from go.dev, checked against a pinned SHA-256.
5. Builds metalgo v1.13.5 from source at a pinned commit, and the
   bridge's L1 plugin (and, for a signer, the `btcvm` or `dogevm` tool)
   from source at the commit pinned in `chains/*.env`. It refuses to go
   on if the checkout is not exactly that commit, or if the plugin's VM
   ID is not the one the live L1 runs. Binaries are owned by root, so no
   service can change what it runs.
6. For a signer: downloads Bitcoin Core 31.1 or Dogecoin Core 1.14.9,
   checked against a pinned SHA-256, and writes its config: pruned for
   Bitcoin, `txindex=1` for Dogecoin, RPC on localhost only, and an
   `rpcauth` line for the signer, so the daemon's config holds a salted
   hash rather than the password.
7. Writes the L1's chain config for the node (a private RPC password,
   the indexes the bridge needs), and for a signer, `signer.env`: the
   signer's connection settings for its own two nodes.
8. Writes hardened systemd units (section [15](#15-reference)), enables
   the firewall, turns on automatic security updates, and turns SSH
   password login off **only if** an SSH key is already installed (so it
   can't lock you out).
9. Starts the node, and for a signer the coin daemon. The signer service
   itself does **not** exist yet: it needs your key, which you make in
   the ceremony below.

It never makes, reads, prints or copies a private key.

Useful options: `--public-ip IP` if detection picks the wrong address,
`--signer-allow-from IP` for the coordinator's address (section 6.5),
`--skip-ssh-hardening` to leave SSH alone.

### 6.4 Wait for the syncs

```sh
sudo ./check.sh
```

shows each piece's progress: the P-Chain, then the L1 (they come up
within the first hour or so), and the coin daemon's first sync, with a
percentage. Expect warnings while things sync; that is normal. You can do
the key ceremony while the coin daemon syncs.

### 6.5 The key ceremony (signers only)

This follows `docs/SIGNERS.md` in the bridge's repository exactly. Only
public information changes hands: **no private key, token or password is
ever sent to anyone.** Commands below are for BTCVM; for DogecoinVM,
replace `btcvm` with `dogevm` throughout.

Every command that touches your key runs **as the signer's own user**,
`btcvm-signer`, so the key is made by, and belongs to, that user alone:

```sh
S="sudo -u btcvm-signer -H"
```

**Step 1: init: make your key and your signer card.**

```sh
$S btcvm signer-setup init -dir /var/lib/btcvm-signer
```

It asks for your name (or your organisation's), shown to the other
signers, and the URL the coordinator will reach you at:
`http://signer.example.com:9700` (your DNS name, or
`http://YOUR_IP:9700`). Choose **new** to make a key here. That is the
safest choice: the key never exists anywhere else. It writes:

- `/var/lib/btcvm-signer/signer.key`: your private key, mode 0600, owned
  by `btcvm-signer`. It never leaves this machine except inside your
  encrypted backups (section 9).
- `/var/lib/btcvm-signer/card.json`: your signer card, holding your
  name, URL, public key, and a signature proving you hold the key. It
  holds no secret.

(If the maintainers ask you to take over one of the existing keys
instead, they will give it to you over a secure channel, and you import
it here with `-import-key-file` or at the hidden prompt. Never pass a key
on the command line. Read section 4 first.)

**Step 2: send your card to the coordinator.**

```sh
sudo cat /var/lib/btcvm-signer/card.json
```

Send that JSON over any channel; it is public. Also ask the coordinator
for the IP address its requests will come from.

**Step 3: the coordinator assembles the signer set.** Nothing for you to
run. The coordinator checks every card's proof, builds the **signer
set** (all public keys, how many must sign, the networks, the
coordinator's key and the bridge's policy: confirmations, fees and caps)
and gets its **fingerprint**, a short code such as
`3f9a-02bc-7d41-e0a8-55c1`. They send you `signers.json`.

**Step 4: verify the fingerprint over a separate channel.** Get on a
call (or another channel that is not the one `signers.json` came over)
with the coordinator and the other signers. Each of you reads out the
fingerprint your own machine shows in step 5. **Do not go on unless
everyone's matches.** A mismatch means someone's file was changed on the
way.

**Step 5: join.**

```sh
sudo install -o btcvm-signer -g btcvm-signer -m 0644 signers.json /var/lib/btcvm-signer/signers.received.json
$S btcvm signer-setup join -dir /var/lib/btcvm-signer -signers /var/lib/btcvm-signer/signers.received.json
```

`join` checks every card's proof, that your key is in the set, and shows
the whole set: who the signers are, the peg address, the policy and the
fingerprint. It asks you to confirm the fingerprint (step 4), and for a
**daily limit**: the most BTC (or DOGE) your signer will approve moving
in 24 hours, whatever the coordinator asks. Agree a sensible figure with
the coordinator; the bridge's circulating cap is a reasonable ceiling
during the beta. `0` means no limit.

`join` installs the set as `/var/lib/btcvm-signer/signers.json` and
writes a service file into that directory. It keeps the `signer.env` the
installer wrote, so there is nothing to fill in.

**Step 6: create and start the signer service.** Re-run the installer
with the coordinator's address:

```sh
sudo ./install.sh --chain btcvm --role signer --signer-allow-from COORDINATOR_IP
```

Now that the key and the set exist, it writes the hardened unit
`/etc/systemd/system/btcvm-signer.service` (with the daily limit and
listen address you chose at `join`), makes sure the key is 0600 and
owned by `btcvm-signer`, opens port 9700 to the coordinator's address
only, and starts the signer. The address is remembered for later runs.

**Step 7: check.**

```sh
sudo ./check.sh
```

This includes the bridge's own `signer-setup check`: your key file, that
your key is in the set, both nodes answering (and the coin daemon
synced), and your signer answering at its URL **and refusing an
unsigned request**. Every request to a signer must be signed by the
coordinator's key and be under 5 minutes old, so your clock must be
right; the installer turns on time sync.

Then tell the coordinator you are up.

### 6.6 Going live

Your signer signs only when the coordinator asks, and only what checks
out. Going live means the coordinator starts the bridge with a signer
set that includes you. Before that:

- `sudo ./check.sh` passes with no failures, the coin daemon fully
  synced.
- Backups are set up and you have done a restore drill (section 9).
- Monitoring is set up (section 8).
- You and the coordinator have agreed how you reach each other in an
  incident, day and night.

Once live, watch `journalctl -u btcvm-signer -f` for the first few
requests: each is logged as `signed ...` or `refused ...: reason`.

## 7. Verification

`sudo ./check.sh` is read-only and safe to run at any time. It exits 1
if anything failed, so it works in scripts. It checks:

- **Services:** each service running and enabled at boot.
- **Metal node:** answering, its NodeID and version, peers, the P-Chain
  synced, the L1 bootstrapped, the L1's JSON-RPC answering on localhost,
  and how far behind the public site's height it is (`--offline` skips
  that one outside call).
- **Coin daemon:** first-sync progress, or when synced, the age of the
  newest block, and peers.
- **Signer:** the key file's owner and mode, whether it is paused, that
  it refuses an unauthenticated request (HTTP 401), the bridge's own
  `signer-setup check`, and the firewall rule for the coordinator.
- **Host:** disk space, clock sync, firewall, automatic updates, a
  pending reboot, SSH password login.
- **Backups:** the newest backup's age and the backup timer.

By hand, the same things:

```sh
systemctl status btcvm-node bitcoind btcvm-signer
journalctl -u btcvm-signer -n 100
sudo -u bitcoind /opt/bitcoin-31.1/bin/bitcoin-cli -datadir=/var/lib/bitcoind getblockchaininfo
curl -s -X POST -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"P"}}' \
  http://127.0.0.1:9650/ext/info
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9700/v1/status   # 401 is right
```

For DogecoinVM: `dogevm-node`, `dogecoind`, `dogevm-signer`, and
`/opt/dogecoin-1.14.9/bin/dogecoin-cli -datadir=/var/lib/dogecoind`.

## 8. Monitoring and alerts

At the least, run `check.sh` every few minutes and get told when it
fails. For example, with a Slack or Discord incoming webhook whose URL
you keep in a root-only file:

```sh
sudo install -m 0600 /dev/null /etc/bridge-operator/alert-webhook
sudo nano /etc/bridge-operator/alert-webhook          # paste the webhook URL
sudo tee /etc/cron.d/bridge-operator-check >/dev/null <<'EOF'
*/5 * * * * root /opt/bridge-operator/check.sh --offline >/var/log/bridge-operator-check.log 2>&1 || curl -fsS -m 10 -H 'content-type: application/json' -d "{\"content\": \"$(hostname): bridge check failed\", \"text\": \"$(hostname): bridge check failed\"}" "$(cat /etc/bridge-operator/alert-webhook)" >/dev/null
EOF
```

That alerts every five minutes while something is failing, which is what
you want for a signer. Warnings (a sync in progress, a stale block) don't
alert; read `/var/log/bridge-operator-check.log` for them.

Also:

- **An outside check.** The cron job can't tell you the server is down.
  Use an external uptime or "dead man's switch" service and ping it from
  the same cron line on success.
- **Disk.** The coin daemons grow. `check.sh` warns at 85% used and fails
  at 95%.
- **The bridge itself.** Each site's `/api/health` serves the
  maintainers' own checks (peg backing, stuck transfers, node health).
  Watch it too: if the peg check fails, pause (section 11).
- **Reboots.** Security updates install themselves; kernel updates need a
  reboot, which `check.sh` reports. Reboot at a quiet time, and not at
  the same time as the other signers. Everything starts again on its own.

## 9. Backups and a restore drill

What only you have, and what the chains can't give back:

- the signer's key (`signer.key`);
- the signing log (`signing-log.json`), the signer's record of what it
  has signed;
- the signer set, the deposit address registry (`deposits.json`), your
  refund approvals and settings;
- the node's identity (`/var/lib/btcvm-node/staking`), its NodeID, which
  will matter if it ever becomes a validator.

### Set up

Backups are encrypted with [age](https://age-encryption.org) to public
keys you choose. The server can write backups but never read them.

1. On **your own computer** (not the server), make an age identity, and
   keep it somewhere safe and offline, such as a password manager. Make
   a second one for a second person or a second place; losing the only
   identity loses every backup.

   ```sh
   age-keygen -o bridge-backup-identity.txt      # prints its public key: age1...
   ```

2. On the server, give the public keys:

   ```sh
   sudo ./backup.sh setup age1... age1...
   ```

   This backs up once now and then hourly for a signer (daily for a node)
   into `/var/backups/bridge-operator`, keeping a week of hourly backups.
3. Keep a copy off the server. Either put an rsync destination (such as
   a storage box, `user@host:dir`) in `/etc/bridge-operator/backup-offsite`
   and each backup is copied there, or fetch them regularly:
   `scp 'you@server:/var/backups/bridge-operator/*.tar.age' ~/bridge-backups/`
   (make the files readable to you first, or fetch as root).

### The restore drill

Do this when you set up, and then every few months. On your own computer,
with the identity:

```sh
./backup.sh verify btcvm-20260101T000000Z.tar.age bridge-backup-identity.txt
```

It decrypts into a private temporary directory, checks every file
against the backup's manifest, tells you what it holds (the chain, role,
NodeID, your signer's public key, that the key file is present and well
formed), and deletes the decrypted copy. It never shows the key. Compare
the public key and NodeID with what `check.sh` shows on the server.

### Restoring for real

Only when the old server is gone for good (see section 13 on two signers
with one key):

1. Build a new server and run the installer with the same chain and role
   (6.1–6.3). Don't start the ceremony.
2. Stop the services: `sudo systemctl stop btcvm-node bitcoind`.
3. Copy the newest backup over, and unpack it at the filesystem root.
   Files come back at their original paths:

   ```sh
   sudo mkdir -m 700 /root/restore
   age -d -i identity.txt btcvm-….tar.age | sudo tar -xzf - -C /root/restore
   sudo cp -a /root/restore/btcvm/. /
   sudo rm -rf /root/restore
   # The same owners by name, whatever the new server's user IDs are:
   sudo chown -R btcvm-node: /var/lib/btcvm-node
   sudo chown -R btcvm-signer: /var/lib/btcvm-signer
   sudo chown -R bitcoind: /var/lib/bitcoind
   ```

   (Decrypt on your own computer and copy the tarball over if you would
   rather not bring the identity near the server; then shred it.)
4. **Pause the signer before it can start** (section 11), then re-run
   `sudo ./install.sh --chain btcvm --role signer`. It sees the key and
   the set and creates the signer service, which starts paused.
5. Talk to the coordinator: your address has probably changed (a new
   card URL means a new signer set, unless your DNS name moved with you),
   and about the signing log (next paragraph).
6. `sudo ./check.sh`, then resume when the coordinator agrees.

**About the signing log.** The log is what stops your signer from helping
pay the same thing twice. A backup's log is as old as the backup: if your
signer signed anything after it was taken that has not yet confirmed on
chain, the restored log doesn't know about it. So restore **paused**, and
resume only once the coordinator confirms that every transaction your
signer could have signed has confirmed or been replaced. After that the
chains show everything, and the old log is safe. (If the log is lost
entirely, the signer falls back on what the chains show; the same wait
applies.)

## 10. Upgrades

The maintainers announce new pins: a new bridge commit in
`chains/*.env`, or new metalgo, Go or coin daemon versions. To upgrade:

```sh
cd /opt/bridge-operator
sudo git fetch
git log --oneline HEAD..origin/main        # what changed
git diff HEAD origin/main                  # read it: this runs as root
sudo git merge --ff-only origin/main
sudo ./install.sh --chain btcvm --role signer --dry-run | less
sudo ./install.sh --chain btcvm --role signer
sudo ./check.sh
```

The installer rebuilds only what changed, keeps every key, password,
chain database and setting, and restarts only the services whose binary,
configuration or unit changed. A signer restart takes seconds, but
**don't upgrade all signers at the same moment**; agree an order with
the others so the bridge always has enough signers up.

To pin a bridge commit yourself (for example to test one before the
others), change `BRIDGE_COMMIT` in `chains/*.env` to the full commit
SHA, read what changed in that repository, and re-run the installer.
The comments in the file say how.

A change to the bridge's policy (a cap, the confirmations, the fees) is
not an upgrade: it is a new signer set, which every signer joins again
with the ceremony (steps 3–7).

## 11. Pausing in an emergency

**When in doubt, pause.** A pause is safe: nothing is lost, and deposits
and withdrawals made while paused are processed after it ends.

Pause your signer:

```sh
sudo -u btcvm-signer -H btcvm pause -dir /var/lib/btcvm-signer -reason "Investigating an alert"
```

Within seconds your signer refuses every request, giving the pause's
reason. `check.sh` shows it. It is a file (`paused.json` in the signer's
directory), so it works even when little else does, and it survives
restarts. Once fewer than m signers are willing to sign, nothing moves.

Resume, once the cause is understood and the other signers agree:

```sh
sudo -u btcvm-signer -H btcvm resume -dir /var/lib/btcvm-signer
```

If the server itself is suspect, stop the service as well, or instead:
`sudo systemctl stop btcvm-signer`. And if you think someone else has
your key, a pause does not help: pausing stops the software, not someone
who has stolen the key. Tell the coordinator at once (section 12).

## 12. Incident checklist

1. **Pause your signer** (section 11). If the server may be compromised,
   also `sudo systemctl stop btcvm-signer`.
2. **Tell the coordinator and the other signers**, over the channel you
   agreed for incidents. Say what you saw and when.
3. **Keep the evidence.** Don't wipe or rebuild yet. Take a backup
   (`sudo ./backup.sh run`) and save the logs:
   `sudo journalctl --since -2d > incident-journal.txt`.
4. **Check what moved.** The peg address on a public Bitcoin (or
   Dogecoin) explorer, and proof of reserves on the site. Compare with
   `/api/health`.
5. **If your key may be exposed:** say so plainly to the coordinator.
   Treat the key as lost: it must be replaced in a new signer set, and
   the server rebuilt from scratch (not from a backup of the compromised
   server's software).
6. **If it was an outage, not a compromise:** fix it, `sudo ./check.sh`,
   and resume only when the coordinator agrees.
7. **Afterwards**, write down what happened and what would have caught
   it sooner.

Common failures and what they mean:

| `check.sh` says | Likely cause | Do |
|---|---|---|
| a service is failed | a crash, or the disk is full | `journalctl -u NAME -n 100`; `df -h` |
| P-Chain or L1 not synced after hours | no peers (firewall), or disk | check port 9651 is open; `journalctl -u btcvm-node` |
| "L1 still bootstrapping" for over an hour, with the P-Chain synced | the node can't get the L1's blocks from its validator | check `info.peers` lists the validator (section 1's NodeID); send `/var/lib/btcvm-node/logs/<chain ID>.log` to the maintainers |
| coin daemon's newest block is old | a slow block (normal now and then), or no peers | wait one more check; `getconnectioncount` |
| signer not answering | the service is stopped, or its nodes were down when it started (it exits, and systemd starts it again every few seconds) | `systemctl status btcvm-signer`; `journalctl -u btcvm-signer -n 50` |
| signer answered without authentication | the signer set has no coordinator key | stop the signer and tell the coordinator |
| key file mode or owner wrong | someone changed it | re-run the installer, and find out who |
| clock not synchronised | time sync is off | `timedatectl status`; the signer will refuse requests |
| the install stops with `SIGILL in blst_cgo_init` | the CPU lacks the ADX/BMI2 instructions metalgo's BLS library uses (very old hardware, or an emulator) | re-run as `sudo CGO_CFLAGS="-O -D__BLST_PORTABLE__" ./install.sh ...` |

## 13. What never to do

- **Never share your signer key**, or copy it anywhere except inside
  your encrypted backups. Never paste it into chat, email, a ticket or a
  terminal on another machine. No one legitimate will ask for it: not
  the coordinator, not the maintainers.
- **Never run two signers with the same key.** Two copies of one signer
  keep two signing logs, and each could sign a different transaction for
  the same deposit or withdrawal, which is exactly what the log exists to
  prevent. When you move a signer, the old one is stopped and wiped
  first.
- **Never restore an old signing log and resume** while anything your
  signer signed since that backup might still be unconfirmed (section 9).
  Restore paused, and wait.
- **Never confirm a fingerprint you did not compare** with the others
  over a separate channel. Never join with `-yes -fingerprint` using a
  fingerprint someone sent you in the same message as the file.
- **Never point your signer at someone else's node.** Its independence
  is the whole point.
- **Never open the signer's port, or the node's APIs, to the internet.**
  Port 9700 is for the coordinator's address only; the node's APIs stay
  on localhost.
- **Never edit the managed files by hand** (the units, `signer.env`, the
  chain config). Re-run the installer, or change `chains/*.env` and
  re-run.
- **Never commit anything** from `/var/lib/*-signer`, `/etc/bridge-operator`
  or a backup to git. This repository's hooks refuse the file names, but
  don't rely on that.
- **Never skip the dry run** on a server that is already live.

## 14. Becoming a validator

Today, a node set up here **follows** the L1 but does not **validate**
it: it checks every block for itself, but has no say in consensus. On
Metal, an L1's validators are registered on the P-Chain by the L1's
owner, and each pays a small continuous fee. Both bridges run with a
single validator for now, and running several has not been set up or
tested yet. So this is the next step, not a feature:

- `sudo ./check.sh` shows your NodeID. Send it to the maintainers if you
  want to validate later.
- Your node's identity (`/var/lib/btcvm-node/staking`) is in your
  backups, so the NodeID survives a rebuild.
- When the multi-validator path is ready, it will come with its own
  instructions, and the installer will change to match.

## 15. Reference

### Commands

| | |
|---|---|
| `sudo ./install.sh --chain C --role R [--dry-run]` | install, or upgrade to the current pins |
| `sudo ./check.sh [--offline]` | read-only health check; exit 1 on failure |
| `sudo ./backup.sh setup AGE1...` | scheduled encrypted backups |
| `sudo ./backup.sh run` / `list` | back up now / list backups |
| `./backup.sh verify FILE IDENTITY` | restore drill, on your own computer |
| `sudo -u btcvm-signer -H btcvm signer-setup check -dir /var/lib/btcvm-signer` | the bridge's own signer check (needs `signer.env` loaded; `check.sh` does that) |
| `sudo -u btcvm-signer -H btcvm pause -dir /var/lib/btcvm-signer -reason "..."` | pause this signer |
| `sudo -u btcvm-signer -H btcvm resume -dir /var/lib/btcvm-signer` | resume |

### Where things are (BTCVM; DogecoinVM is the same with `dogevm`, `dogecoind`)

| Path | What | Owner, mode |
|---|---|---|
| `/opt/metal/v1.13.5/metalgo` | metalgo | root, 0755 |
| `/opt/btcvm/plugins/<VM ID>` | the L1 plugin | root, 0755 |
| `/opt/btcvm/bin/btcvm` (and `/usr/local/bin/btcvm`) | the bridge tool (signer) | root, 0755 |
| `/opt/bitcoin-31.1/` | Bitcoin Core (signer) | root |
| `/var/lib/btcvm-node/` | the node's data, logs and identity (`staking/`) | `btcvm-node`, 0750 |
| `/var/lib/btcvm-node/chain-configs/<chain ID>/config.json` | the L1's node settings, with its RPC password | `btcvm-node`, 0600 |
| `/var/lib/bitcoind/` | Bitcoin Core's data and `bitcoin.conf` | `bitcoind`, 0750 / 0600 |
| `/var/lib/btcvm-signer/` | key, card, set, signing log, registry, approvals, `signer.env` | `btcvm-signer`, 0700 |
| `/etc/systemd/system/btcvm-node.service`, `bitcoind.service`, `btcvm-signer.service` | the units | root |
| `/etc/bridge-operator/` | install settings, backup recipients, offsite target | root |
| `/var/backups/bridge-operator/` | encrypted backups | root, 0700 |
| `/var/lib/bridge-build/` | source checkouts and build caches | `bridge-build` |

### Ports

| Port | What | Open to |
|---|---|---|
| 22/tcp | SSH | everyone (key login only) |
| 9651/tcp | Metal peers (staking port) | everyone |
| 8333/tcp or 22556/tcp | Bitcoin / Dogecoin peers (signer) | everyone |
| 9700/tcp | the signer's API (signer) | the coordinator's address only |
| 9650/tcp | the node's APIs and the L1's JSON-RPC | localhost only |
| 8332/tcp or 22555/tcp | the coin daemon's RPC (signer) | localhost only |

### How each service is sandboxed

Every unit runs as its own user with an empty capability set and no way
to gain privileges, sees the filesystem read-only except its own state
directory (`ProtectSystem=strict` with one `ReadWritePaths`), has no
access to home directories, a private `/tmp` and no devices, cannot
change kernel settings, modules, logs, cgroups, the clock or the
hostname, is limited to ordinary system calls (`@system-service`) and
address families, and cannot map memory writable and executable. The
signer is further limited to talking to localhost, its own address and
the coordinator's (`IPAddressAllow`), and to plain IP and Unix sockets.
Run `systemd-analyze security btcvm-signer` to see the details.

### Refund approvals

A signer approves a refund only if its operator listed it, after checking
it: one `TXID:VOUT ADDRESS` per line in
`/var/lib/btcvm-signer/refund-approvals`. Edit it with
`sudo -u btcvm-signer -H nano /var/lib/btcvm-signer/refund-approvals` when
the coordinator asks for a refund you have checked on a public explorer.
The signer reads it on each request; no restart needed.
