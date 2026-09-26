# bridge-operator

Run a node or a peg signer for the two Metal Blockchain L1 bridges:
**BTCVM** (BTC, [metalbtc.com](https://metalbtc.com)) and **DogecoinVM**
(DOGE, [metaldoge.com](https://metaldoge.com)).

Each bridge is an L1 on Metal mainnet whose coins are locked on Bitcoin or
Dogecoin by an m-of-n multisig of peg signers. This repository sets up, on
a fresh Ubuntu 24.04 server of your own:

- **a node**: a Metal mainnet node that follows the bridge's L1, built from
  source at a pinned commit, serving its JSON-RPC on localhost; or
- **a peg signer**: the node, plus the chain's own Bitcoin Core (pruned) or
  Dogecoin Core, plus the signer service, which holds one of the multisig
  keys and checks every transaction against its own nodes before signing.

Every download is pinned by SHA-256 and every source build by commit.
Every service runs as its own user under a systemd sandbox. The installer
never makes or touches a private key: you make yours in the key ceremony,
on the signer's machine, as the signer's own user.

> **Status: beta.** Both bridges are live on mainnet with small caps, and
> today every signer key sits on one server. This repository exists to
> bring in independent signers. Nodes don't validate yet. Read
> [GUIDE.md, Status today](GUIDE.md#4-status-today).

## Quickstart

On a fresh Ubuntu 24.04 x86_64 server, with your SSH key installed:

```sh
sudo git clone https://github.com/paulgnz/bridge-operator /opt/bridge-operator && cd /opt/bridge-operator
sudo ./install.sh --chain btcvm --role signer --dry-run | less   # see every action first
sudo ./install.sh --chain btcvm --role signer                    # or: --chain dogevm, --role node
sudo ./check.sh                                                  # sync progress and health
sudo ./backup.sh setup age1YOUR_PUBLIC_KEY                       # encrypted backups
```

A signer then goes through the key ceremony with the coordinator and the
other signers (`btcvm signer-setup init`, send your card, verify the
fingerprint, `join`) and re-runs the installer to start the signer service.
[GUIDE.md](GUIDE.md) covers all of it, step by step.

## What's here

| | |
|---|---|
| [`GUIDE.md`](GUIDE.md) | The operator guide: roles, trust model, requirements and costs, setup, the key ceremony, monitoring, backups, upgrades, emergencies. |
| [`install.sh`](install.sh) | Installs or upgrades a node or signer. Idempotent; `--dry-run` prints every action. |
| [`check.sh`](check.sh) | Read-only health check. Exits 1 on failure. |
| [`backup.sh`](backup.sh) | age-encrypted backups of the signer's key, signing log and settings; `verify` for restore drills. |
| [`chains/`](chains) | Every per-chain value: L1 IDs, pinned commits, coin daemon versions and hashes. |
| [`test/`](test) | Container tests: dry runs, the installer in test mode, and a full real install. |

`make lint` runs `bash -n`, shellcheck and the secret scanner's tests;
`make test` adds the container tests. `make hooks` installs the git hooks
that refuse commits and pushes containing secrets.

---

Developed by Paul Grey @ metallicus.com · Built on btcvm by Deep V @ metallicus.com
