# compute-node

Use a GPU machine (a Windows PC through its WSL2 distro, or any Debian/Ubuntu box) from your
laptop as if its CPU and GPU were plugged in locally. Your code and your AI coding agent stay on
the laptop; heavy commands run on the compute node in the **same absolute path** and their
output syncs back.

[中文说明](README.zh-CN.md)

```
 control nodes (laptop: agent + code)                 compute nodes (CPU / GPU / Docker)
 ┌──────────────────────────────────┐                ┌──────────────────────────────────┐
 │ edit, git, grep: local and fast  │ Mutagen 2-way  │ n1: WSL2 distro on a Windows PC  │
 │ ~/proj  ── wsync -n n1 ──────────┼───────────────>│ /Users/you/proj  (same path)     │
 │ rx -n n1 <cmd> ──────────────────┼── ssh :2222 ──>│ runs <cmd> there, CUDA works     │
 │ docker --context n1 ... ─────────┼── ssh ────────>│ Docker Engine + NVIDIA runtime   │
 │ rx nodes --json ─────────────────┼── ssh ──┐      └──────────────────────────────────┘
 └──────────────────────────────────┘         │      ┌──────────────────────────────────┐
   more control nodes, each with its own      └─────>│ n2: plain Linux server           │
   registry: any control node can use any            └──────────────────────────────────┘
   compute node (over Tailscale or the LAN)
```

**Why sync instead of a network mount:** an agent's most frequent operations are reading and
searching files. Keeping them local is fastest; SSHFS-style mounts put every read on the network.
Because paths are identical on both sides, `$PWD`, absolute paths and `docker -v "$PWD:$PWD"`
just work.

**Scope:** sync, run a command, bring results back, and report node status. There is **no
scheduler**: you (or your agent) look at `rx nodes` and pick a node; each compute node runs
its own jobs (tmux etc.).

## Quick start

Two commands: one on the compute node, one on each laptop.

### 1. Compute node: inside the WSL2 distro, or on a Debian/Ubuntu machine

```bash
curl -fsSL https://raw.githubusercontent.com/lemonadesaltbagel/cnode/main/install.sh | sudo bash -s -- node
```

Run it in the WSL terminal (WSL2 must already be installed; nothing on the Windows side is
changed) or on the Linux machine. It installs sshd on port 2222, Docker Engine (plus the NVIDIA
Container Toolkit when a GPU is visible), Tailscale, `cn-status`/`cn-authorize`, and the `/Users`
sync root. Tailscale's login prints a URL: open it once and log in. For an unattended install pass
an auth key: `... node --authkey tskey-auth-...`. Without Tailscale (LAN only): `--no-tailscale`.

Other options: `--user NAME` (default: the user who ran sudo), `--create-user`, `--port 2222`,
`--sync-root DIR` (repeatable), `--ts-hostname NAME`, `--key-only`, `--authorize 'KEY'`,
`--no-docker`, `--gpu auto|yes|no`. For a GPU on plain Linux install the NVIDIA driver first; on
WSL use the **Windows** NVIDIA driver (never a Linux driver inside WSL).

It ends with a join line and the command for the laptop:

```
  join: host=<machine>.<tailnet>.ts.net user=alice port=2222 fingerprint=SHA256:...
  curl -fsSL https://raw.githubusercontent.com/lemonadesaltbagel/cnode/main/install.sh | bash -s -- control --name <name> --host <machine>.<tailnet>.ts.net --user alice --port 2222
```

### 2. Control node: the laptop (macOS or Linux)

```bash
curl -fsSL https://raw.githubusercontent.com/lemonadesaltbagel/cnode/main/install.sh | bash -s -- control --host <host> --user <user>
```

Use the `host`/`user` from the join line (the laptop must be on the same tailnet, or the same LAN
with `--no-tailscale`). It asks for the node user's **password once**, installs this machine's
SSH key on the node, and from then on `rx`, `wsync` and agents never prompt. The node's host key
is trusted on first use; add `--fingerprint SHA256:...` from the join line to pin it instead.

It also installs Mutagen (Homebrew on macOS, else the release binary), the docker CLI (macOS with
Homebrew), an SSH key if you have none, `cnode`/`rx`/`wsync` in `~/.local/bin`, an SSH alias per
node with connection reuse, a docker context per node, and the agent rules block in
`~/.claude/CLAUDE.md` (and `~/.codex/AGENTS.md` if `~/.codex` exists; `--agent-rules FILE` for
more, `--no-agent-rules` to skip). The node is named `wsl` unless you pass `--name`. More nodes
later: `cnode add <name> --host <host> --user <user>`. `bash -s -- control --help` lists everything.

No password at hand (or the node runs `--key-only`)? Run the line printed by `cnode key` on the
node, as the node user: `cn-authorize 'ssh-ed25519 AAAA... you@laptop-compute-node'`.

### 3. Check

```bash
cd ~/some-project
wsync                  # start syncing this folder to the default node
rx nproc               # runs on the node, in the same path
rx nvidia-smi          # GPU visible
rx nodes               # hardware and load of every node
docker --context wsl run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi
```

## Daily use

| Command | What it does |
|---|---|
| `wsync [-n node] [dir]` | Two-way sync `dir` (default `.`) with the same path on the node. Once per project and node. |
| `wsync -l [-n node]` | List sync sessions (all nodes, or one). |
| `wsync -t [-n node \| -a] [dir]` | Stop syncing (files stay on both sides). `-a`: all nodes. |
| `rx [-n node] <cmd>` | Flush local changes, run `<cmd>` on the node in the same directory (login shell), wait until the node's output has synced back. Exit code and output are passed through. |
| `rx nodes [--json]` | Query every node in parallel (short timeout): hardware (CPU model, cores/threads, effective CPUs, RAM, GPU names/memory/driver/CUDA, OS, WSL or not) and live load (load average, free memory, GPU memory used and utilization, disk free on the sync root, tmux sessions), plus sync state. Unreachable nodes are reported, not fatal. Schema below. |
| `cnode add <name> --host H --user U [--port P] [--fingerprint FP]` | Register another compute node; asks for its password once and installs this machine's key. |
| `cnode list` / `cnode default [name]` / `cnode remove <name>` | Manage the registry. |
| `cnode key` | Print the `cn-authorize` line for this machine (manual alternative to the password login). |
| `ssh cn-<node>` | A shell on the node. `ssh -N -L 8888:localhost:8888 cn-<node>` forwards a port. |
| `docker --context <node> ...` | Docker on the node (the install makes the first node the default context). |

The node is chosen by `-n`, else `$RX_NODE`, else the registry default, else the only node.
Quote shell syntax so that it expands on the node: `rx 'make -j$(nproc)'`. Use `rx -- nodes` to
run a remote program literally called `nodes`. `RX_NO_PULL=1` skips the final flush.

```bash
rx uv sync                       # dependency dirs are not synced: install them on the node
rx uv run pytest -x
rx -n gpu2 python train.py --epochs 10
rx docker build -t myimg .       # builds on the node, no context upload
docker run --rm --gpus all -v "$PWD:$PWD" -w "$PWD" myimg python run.py
```

**Long jobs**: start them in tmux on the node; they survive network drops and closed laptops.

```bash
rx -n gpu1 'mkdir -p logs && tmux new -d -s train "python train.py 2>&1 | tee logs/train.log"'
tail -f logs/train.log           # the log syncs back
rx -n gpu1 tmux ls
ssh -t cn-gpu1 tmux attach -t train
```

### `rx nodes --json` schema

One array entry per registered node. `hardware` holds static facts (what the machine *is*),
`load` the live state (what is free *now*); both are `null` when the node is unreachable.
Example with placeholder values:

```json
[
  {
    "name": "gpu1", "alias": "cn-gpu1", "host": "<host>", "user": "<user>", "port": 2222,
    "default": true, "reachable": true, "error": null,
    "hostname": "<node-hostname>",
    "hardware": {
      "cpu_model": "<CPU model name>", "cpu_cores": 8, "cpu_threads": 16, "cpus_effective": 16,
      "mem_total_mb": 24000, "mem_limit_mb": null,
      "gpus": [{"index": 0, "vendor": "nvidia", "name": "<GPU name>", "mem_total_mb": 16000,
                "driver": "<driver version>", "cuda": "<CUDA version>", "compute_cap": "<x.y>"}],
      "os": "Debian GNU/Linux 13 (trixie)", "kernel": "<kernel release>", "arch": "x86_64",
      "wsl": true, "container": false
    },
    "load": {
      "loadavg": [0.5, 0.7, 0.9], "mem_available_mb": 18000,
      "gpus": [{"index": 0, "mem_used_mb": 1200, "mem_free_mb": 14800, "util_pct": 3}],
      "disk": [{"path": "/Users", "free_mb": 500000, "total_mb": 1000000}],
      "tmux": ["train"], "uptime_s": 86400
    },
    "sync": [{"session": "gpu1-0123456789", "path": "/Users/<you>/proj", "status": "Watching",
              "conflicts": 0, "connected": true, "paused": false}]
  },
  {
    "name": "gpu2", "alias": "cn-gpu2", "host": "<host>", "user": "<user>", "port": 2222,
    "default": false, "reachable": false, "error": "timed out after 10s",
    "hostname": null, "hardware": null, "load": null, "sync": []
  }
]
```

| Field | Meaning |
|---|---|
| `hardware.cpu_model`, `cpu_cores`, `cpu_threads` | From `/proc/cpuinfo` (or `lscpu`). |
| `hardware.cpus_effective` | CPUs this account can really use: affinity (`nproc`) capped by a cgroup CPU quota (containers often report the host's core count). |
| `hardware.mem_total_mb`, `mem_limit_mb` | RAM seen by the kernel (for WSL: the `.wslconfig` cap) and a cgroup memory limit if one applies (else `null`). |
| `hardware.gpus[]` | NVIDIA via `nvidia-smi` (name, memory, driver, CUDA, compute capability). AMD/Intel from sysfs with what the driver exposes (name may be `null`, `cuda` is `null`). Empty array: no GPU. |
| `hardware.os`, `kernel`, `arch`, `wsl`, `container` | Distribution, kernel release, CPU architecture, running inside WSL, running inside a container. |
| `load.loadavg` | 1/5/15-minute load average. |
| `load.mem_available_mb` | `MemAvailable`, capped by the cgroup limit. |
| `load.gpus[]` | Per GPU (same `index`): memory used/free and utilization. |
| `load.disk[]` | Free space on each sync root of the node. |
| `load.tmux` | tmux sessions of the node user (jobs started with `rx ... tmux new -d`). |
| `sync[]` | This control node's Mutagen sessions with that node (status, conflicts, connected, paused). |

The table form (`rx nodes`) prints the same as one line per node. On a node, `cn-status`,
`cn-status --json` print the node's own part.

### How rx and wsync work

- `wsync` creates one Mutagen session per *folder x node*, named `<node>-<10 hex of sha1(path)>`
  and labelled `compute=<node>`, endpoint `cn-<node>:<same path>`, mode `two-way-resolved` (the
  control node wins conflicts). Mutagen's daemon keeps syncing in the background (registered with
  launchd on macOS).
- `rx` walks up from `$PWD` to find the session covering it, runs `mutagen sync flush` (so the
  node sees your latest edits), then `ssh cn-<node> 'cd <same path> && exec bash -lc <cmd>'`,
  then flushes again (so you can read the outputs immediately). With connection reuse
  (`ControlMaster`, `ControlPersist 30m`) the overhead is about 0.1-0.5 s per call.
- Not synced (each side keeps its own): `node_modules`, `.venv`, `venv`, `__pycache__`, `target`,
  `.mypy_cache`, `.pytest_cache`, `.ruff_cache`, `.next`, `.turbo`, `.gradle`, `.DS_Store`.
  Everything else syncs both ways, including results written on the node.

### Several nodes, several control nodes

Every control node has its own registry (`~/.config/compute-node/nodes`, one line
`name host user port` per node) and generated SSH aliases `cn-<name>`; any control node can
use any compute node it is authorized on. A folder can sync to several nodes at once (one session
each); the control node is the hub, so a file written by `rx -n n1` reaches `n2` via the laptop.

**Two control nodes, same path, same compute node** (for example two Macs with the same user
name both syncing `/Users/alice/proj` to the same node as the same node user): there are then two
sessions whose node side is the same directory, so the compute node becomes the hub between the
two laptops. Each session resolves conflicts in favour of its own laptop, so this is only safe
when one side edits at a time (or they work in different subfolders); concurrent edits of the
same file, or a delete on one laptop while the other edits, can flip-flop or lose work. Different
users or different paths never interact. Prefer one owner per folder per node.

### Agent rules

The control-node install writes a block between `<!-- BEGIN compute-node -->` and
`<!-- END compute-node -->` to `~/.claude/CLAUDE.md` (Claude Code), to `~/.codex/AGENTS.md` when
`~/.codex` exists (Codex), and to any `--agent-rules FILE`; `--lang zh-CN` writes it in Chinese,
`--no-agent-rules` skips it. Re-running replaces the block in place and leaves the rest of the file
alone. It tells an agent to: edit and search locally and run builds/tests/GPU work through `rx`;
run `rx nodes --json` before dispatching heavy work and choose by `hardware` (CPU model, effective
CPUs, RAM, GPU model/memory/CUDA) and live `load`; never assume a node is idle; keep memory
headroom (do not start a job on a node whose available RAM or GPU memory is below what the job
needs plus a margin); start long jobs in tmux on the node under a unique name; read results from
the synced folder. See [templates/agent-rules.en.md](templates/agent-rules.en.md). To skip
permission prompts for `rx` in Claude Code you can allow `Bash(rx:*)` and `Bash(wsync:*)`; that
lets the agent run anything on the node without asking, and files it writes there sync back.

## What the installers change

### Compute node (`scripts/node-setup.sh`)

| Change | Where / why |
|---|---|
| sshd on port 2222 (not 22, so it never clashes with Windows' own OpenSSH), password or key login, no root login, more parallel sessions for agents | `/etc/ssh/sshd_config.d/10-compute-node.conf`. Ubuntu's `ssh.socket` is switched to `ssh.service` so the port applies. `--key-only` turns passwords off. |
| Tailscale from Tailscale's apt repository, `tailscaled` running, `tailscale up` | Under systemd as a service; without systemd started directly; without a TUN device in userspace-networking mode. `--no-tailscale` skips it. |
| Docker Engine from Docker's apt repository, user added to `docker` | Skipped if another `docker` exists (Docker Desktop integration, `docker.io`). Without systemd it is started with its init script. |
| NVIDIA Container Toolkit (`--gpus all`) | Only when an NVIDIA GPU is visible. |
| inotify limits for Mutagen and build tools | `/etc/sysctl.d/90-compute-node.conf` |
| `nvidia-smi` for SSH sessions (WSL puts `/usr/lib/wsl/lib` on PATH only for local terminals) | `/usr/local/bin/nvidia-smi`, `/etc/profile.d/wsl-lib.sh` (WSL only) |
| Sync root `/Users` owned by the node user | Mirrors macOS paths. For a Linux control node add `--sync-root /home/<you>`. |
| `cn-status`, `cn-authorize` | `/usr/local/bin`, settings in `/etc/compute-node.conf` |
| systemd on WSL | `/etc/wsl.conf [boot] systemd=true` and `[user] default=`, used from the distro's next start; until then the services are started directly, so nothing has to be restarted now. |

### Control node (`scripts/control-setup.sh`, `bin/cnode`)

| Change | Notes |
|---|---|
| `~/.ssh/config`: a marked block at the very top, `Include ~/.config/compute-node/ssh_config` | `Include` must precede any `Host` line. The block written by the original single-node setup (`# BEGIN wsl-compute`) is migrated and removed. |
| `~/.config/compute-node/` | `nodes`, `default`, generated `ssh_config` (one `Host cn-<name>` per node, `ControlMaster`/`ControlPersist 30m`, keychain on macOS), `known_hosts` (host keys, trusted on first use or pinned with `--fingerprint`). |
| `~/.local/bin/cnode`, `rx`, `wsync` (symlinks), `~/.local/share/compute-node/cn-status` | PATH line added to your shell rc if needed. |
| `~/.ssh/id_ed25519` | Created only if missing; a passphrase goes to the macOS keychain. |
| Mutagen daemon, docker context per node | `docker context use <first node>` unless `--keep-docker-context`. |
| Agent rules block in `~/.claude/CLAUDE.md` (+ `~/.codex/AGENTS.md`) | Between markers, replaced in place; `--no-agent-rules` skips. |

## What still needs Windows (WSL nodes)

This tool changes nothing on the Windows side. What it cannot do from inside the distro:

- **WSL2 itself** must be installed, with a Debian or Ubuntu distro (`wsl --install -d Debian`).
- **The distro must be running.** WSL stops a distro some seconds after its last Windows-side
  process (terminal) exits, and stops the VM when idle; systemd services do not keep it alive, and
  after a Windows reboot nothing starts it. Keep a WSL terminal open, or set it up yourself on
  Windows: `vmIdleTimeout=-1` under `[wsl2]` in `%USERPROFILE%\.wslconfig` and a logon/boot task
  that runs `wsl -d <Distro> --exec sleep infinity`.
- **Sleep**: a sleeping PC is not a compute node (Windows power settings).
- **GPU driver**: the Windows NVIDIA driver provides CUDA inside WSL.
- **LAN access without Tailscale**: in WSL's default NAT mode other machines cannot reach the
  distro; that needs Windows-side port forwarding or `networkingMode=mirrored` (plus a Hyper-V
  firewall rule). Tailscale inside the distro avoids all of this.
- If Windows itself runs Tailscale *and* WSL uses mirrored networking, the two can conflict; use
  `--no-tailscale` and the Windows machine's Tailscale name in that case.

## Security model

This tool favours easy deployment; harden it when you need to.

- sshd accepts **passwords and keys** (no root login). The password is only needed once per
  control node: `cnode add` logs in with it and installs that machine's key; all later traffic
  uses the key. After all control nodes are added you can re-run the node install with
  `--key-only` to turn passwords off.
- Host keys are **trusted on first use** and then pinned per node in a dedicated known_hosts
  (`StrictHostKeyChecking yes`), so a *changed* key is refused (`cnode remove` + `cnode add` if it
  is expected). On a network you do not trust, pass `--fingerprint` from the join line so the
  very first connection is verified too.
- With Tailscale only machines in your tailnet can reach port 2222 at all; with `--no-tailscale`
  the port is open to the LAN.
- Anyone who can run `rx` can run anything as the node user, and files written on the node sync
  back to the laptop. Treat a node like a second account of yours.
- `CN_PASSWORD` (for scripted `cnode add`) puts the password in the environment of that one
  command; prefer typing it.

## Networking: Tailscale (default) or LAN

Tailscale gives each machine a stable name (`<machine>.<tailnet>.ts.net`) that works from
anywhere and usually connects directly on the same LAN. The node install runs it inside the WSL
distro or Linux machine, so no router or Windows changes are needed. Install Tailscale on the
laptop too and log in to the same tailnet. In the admin console, **Disable key expiry** for the
node (otherwise it logs out after about 180 days) and keep **MagicDNS** on. `tailscale ping <host>`
should say `via <LAN IP>`; `via DERP` means relayed (slower; check UDP 41641). Without Tailscale
use the node's LAN IP (`--no-tailscale`).

## Limits

- **WSL memory**: WSL gets at most a share of Windows' RAM (by default half) and competes with
  Windows; `rx nodes` shows what is really available. Changing the cap is a Windows setting
  (`memory=` in `.wslconfig`).
- **Containers as compute nodes**: a Docker or RunPod container can serve `rx`/`wsync` (sshd and
  tailscaled start without systemd, Tailscale in userspace mode), but it cannot run Docker Engine:
  unprivileged containers cannot create the namespaces and cgroups it needs, and cannot host user
  namespaces for rootless Docker either. Use `--no-docker` there.
- Each `rx` adds roughly 0.1-0.5 s; fine for real work, wasteful for thousands of tiny calls.
- The network is the bottleneck for big files: download datasets on the node, not through sync.
- Paths must be identical: macOS control nodes map to `/Users/...` on the node. Linux control
  nodes need their home path (e.g. `/home/alice`) added as a sync root on the node.
- Compute nodes: Debian/Ubuntu and derivatives only.
- No scheduling, no locking between agents: `rx nodes` shows what is running; choosing is up to
  you or your agent.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| The node is unreachable after a while (WSL) | The distro or the WSL VM stopped; see "What still needs Windows". Open a WSL terminal to start it again. |
| `tailscale up` waits forever | Open the printed URL and log in, or re-run with `--authkey`. Check with `tailscale status`. |
| `nvidia-smi: command not found` over SSH | Re-run the node setup (it links `nvidia-smi` into `/usr/local/bin`). |
| `rx` or sync hangs or asks for a passphrase | The key's passphrase is not in the agent/keychain: `ssh-add --apple-use-keychain ~/.ssh/id_ed25519` (macOS). |
| `cnode add` fails at the password login | Wrong password, the node user has none (`sudo passwd <user>` on the node), or the node runs `--key-only`: use the `cnode key` line on the node instead. |
| Cannot connect to port 2222 | Is the node up (`tailscale status` on both sides)? Same tailnet? Without Tailscale on WSL see "LAN access" above. |
| `host key ... CHANGED` / `Host key verification failed` | The node was reinstalled or you reached another machine. Check on the node (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`); if expected: `cnode remove <node>` and add it again. |
| `rx: ... does not exist on <node>` | The folder is not synced to that node: `wsync -n <node>` in the project root. |
| `tailscale ping` shows `via DERP` | Relayed, not direct: same LAN? UDP 41641 blocked by the router? |
| Sync conflicts | The control node wins; inspect with `wsync -l` or `mutagen sync monitor`. |
| `permission denied` from docker on the node | Group membership needs a new login (on WSL: close all WSL terminals, or `wsl --terminate <Distro>`). |

## Uninstall

Control node:
```bash
mutagen sync terminate --label-selector compute     # all sessions made by wsync
mutagen daemon unregister
docker context use default && docker context rm <node> ...   # one per node, see: cnode list
rm -rf ~/.local/bin/{cnode,rx,wsync} ~/.local/share/compute-node ~/.config/compute-node
awk '/^# BEGIN compute-node$/{s=1;next} /^# END compute-node$/{s=0;next} !s' ~/.ssh/config > ~/.ssh/config.new && mv ~/.ssh/config.new ~/.ssh/config
```

Compute node (WSL or Linux):
```bash
sudo rm /etc/ssh/sshd_config.d/10-compute-node.conf /etc/sysctl.d/90-compute-node.conf /etc/compute-node.conf \
        /usr/local/bin/cn-status /usr/local/bin/cn-authorize /etc/profile.d/wsl-lib.sh /usr/local/bin/nvidia-smi
sudo systemctl restart ssh   # or disable it: sudo systemctl disable --now ssh
sudo tailscale logout; sudo apt-get purge tailscale
sudo apt-get purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin nvidia-container-toolkit
# /Users holds synced copies of your projects; delete it once you no longer need them
```

## Repository layout

```
install.sh                entry point for both roles (curl | bash), fetches what it needs
scripts/node-setup.sh     compute-node setup (Debian/Ubuntu, inside WSL or plain Linux)
scripts/control-setup.sh  control-node setup (macOS/Linux)
bin/cnode                 rx, wsync (symlinks to it), the node registry and status
node/cn-status            node hardware/load snapshot (also piped over SSH by rx nodes)
node/cn-authorize         add/list/remove control-node keys on a node (manual path)
templates/                agent rules blocks (en, zh-CN)
tests/                    tests/run.sh [lint|control|node|multinode|all]
```

The installers download from `https://raw.githubusercontent.com/lemonadesaltbagel/cnode/main`; set `CN_RAW_URL` to use a fork or a tag.

## Tests

`tests/run.sh` runs everything without touching real machines:

- `lint`: shellcheck and `bash -n` for every script, CRLF and download-URL checks.
- `control`: the control-node install in throwaway HOMEs with ssh/mutagen/docker/brew stubbed:
  files written, agent rules (default on, `--no-agent-rules`, AGENTS.md), trust on first use and
  refusal of a changed host key, wrong `--fingerprint` refused, the one-time password login that
  installs the key (`CN_PASSWORD`, wrong password, no-terminal fallback), rx/wsync command lines,
  `rx nodes --json`, the piped `curl | bash` path, migration from the original single-node setup,
  and that a second run changes nothing.
- `node`: the compute-node install in fresh `debian:13` and `ubuntu:24.04` containers (no systemd,
  no TUN): password and key login, `--key-only`, Docker packages, the real Tailscale package with
  its daemon and login stubbed (auth key, userspace mode, join host, no-key fallback),
  `--no-tailscale`, cn-authorize, the WSL `wsl.conf` path, idempotency.
- `multinode`: two compute-node containers and a control container with two users, all real
  (ssh, Mutagen): `cnode add` with a password installing the key, TOFU and pinned fingerprints,
  the manual `cn-authorize` path, `wsync -n` of one folder to both nodes, `rx -n`, `rx nodes --json`
  with one node stopped and one hung.

Docker tests use the current docker context and skip themselves when the engine has less than
`MIN_AVAILABLE_MB` (6000) free. No test uses a GPU.

## License

MIT, see [LICENSE](LICENSE).
