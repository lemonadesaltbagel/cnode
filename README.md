# compute-node

Use a GPU machine (a Windows PC through WSL2, or any Debian/Ubuntu box) from your laptop as if
its CPU and GPU were plugged in locally. Your code and your AI coding agent stay on the laptop;
heavy commands run on the compute node in the **same absolute path** and their output syncs back.

[中文说明](README.zh-CN.md)

```
 control nodes (laptop: agent + code)                 compute nodes (CPU / GPU / Docker)
 ┌──────────────────────────────────┐                ┌──────────────────────────────────┐
 │ edit, git, grep: local and fast  │ Mutagen 2-way  │ n1: Windows 11 -> WSL2 (Debian)  │
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

Order does not matter much; the usual flow is: set up the compute node, copy its **join line**,
set up the control node with it, then paste the control node's **authorize line** on the node.

`<raw-url>` below stands for the raw download URL of this repository
(`https://raw.githubusercontent.com/<owner>/<repo>/main`).

### 1a. Compute node on Windows 11 (WSL2)

In an **elevated** PowerShell (right-click > Run as administrator):

```powershell
irm <raw-url>/install.ps1 | iex
```

With options (all optional):

```powershell
& ([scriptblock]::Create((irm <raw-url>/install.ps1))) -Distro Debian -User alice -AuthorizeKey 'ssh-ed25519 AAAA... laptop'
```

It enables WSL2 if needed (then asks for a reboot and to run the same command again), installs a
Debian distro if there is no Debian/Ubuntu one, merges the `.wslconfig` settings below, runs the
Linux setup inside the distro, adds the Hyper-V firewall rule, disables sleep on AC power and
registers a boot task so the node comes up without anyone logging in. It finishes by printing the
join line. Options: `-Distro`, `-User`, `-SshPort 2222`, `-MemoryGB`, `-SyncRoot /Users`,
`-AuthorizeKey`, `-NoDocker`, `-AllowLanPassword`, `-InstallTailscale`, `-SkipWslConfig`,
`-SkipPower`, `-SkipTask`, `-SkipFirewall`, `-ResetTask`.

Requirements: Windows 11 22H2 or newer (mirrored networking), the **Windows** NVIDIA driver
(never install a Linux driver inside WSL). For the boot task it asks once for your Windows
account **password** (not the PIN; for a Microsoft account, its password).

### 1b. Compute node on plain Linux (Debian/Ubuntu)

```bash
curl -fsSL <raw-url>/install.sh | sudo bash -s -- node
```

Options: `--user NAME` (default: the user who ran sudo), `--create-user`, `--port 2222`,
`--sync-root DIR` (repeatable, default `/Users`), `--authorize 'KEY'`, `--allow-lan-password`,
`--no-docker`, `--gpu auto|yes|no`. For a GPU, install the NVIDIA driver first; the setup adds
the NVIDIA Container Toolkit when it sees one.

Both variants end with something like:

```
  join: host=<machine>.<tailnet>.ts.net user=alice port=2222 fingerprint=SHA256:...
```

### 2. Control node (macOS or Linux)

```bash
curl -fsSL <raw-url>/install.sh | bash -s -- control --host <host> --user <user> --fingerprint SHA256:...
```

This installs Mutagen (Homebrew on macOS, else the release binary), the docker CLI (macOS with
Homebrew), an SSH key if you have none, `cnode`/`rx`/`wsync` in `~/.local/bin`, an SSH alias per
node with connection reuse, a docker context per node, the agent rules block in
`~/.claude/CLAUDE.md` (and `~/.codex/AGENTS.md` if `~/.codex` exists; `--agent-rules FILE` for
more, `--no-agent-rules` to skip), and registers the node (default name `wsl`; `--name gpu1` to
choose). `bash -s -- control --help` lists everything.

If the node does not know this machine's key yet, the installer prints the line to run **on the
node**:

```bash
cn-authorize 'ssh-ed25519 AAAA... you@laptop-compute-node'
```

(On Windows: `wsl -d <Distro> -u <user> -- cn-authorize '...'`.) `cnode key` prints it again.

### 3. Check

```bash
cd ~/some-project
wsync                  # start syncing this folder to the default node
rx nproc               # runs on the node, in the same path
rx nvidia-smi          # GPU visible
rx nodes               # status of every node
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
| `cnode add <name> --host H --user U [--port P] [--fingerprint FP]` | Register another compute node. |
| `cnode list` / `cnode default [name]` / `cnode remove <name>` | Manage the registry. |
| `cnode key` | Print the `cn-authorize` line for this machine. |
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

### Windows (`install.ps1`)

| Change | Why |
|---|---|
| `%USERPROFILE%\.wslconfig`, merged (other keys kept, backup `.wslconfig.bak-<time>` when it changes) | `[wsl2] memory=<75% of RAM>GB` caps the VM; `networkingMode=mirrored` makes WSL share Windows' network interfaces, so `<windows-host>:2222` reaches sshd in WSL; `vmIdleTimeout=-1` keeps the VM from shutting down when idle; `[experimental] autoMemoryReclaim=gradual` hands freed page cache back to Windows. |
| Hyper-V firewall rule `WSL-SSH-2222` | With mirrored networking, inbound traffic to WSL is filtered by the Hyper-V firewall. |
| `powercfg`: never sleep / hibernate on AC | A sleeping PC is not a compute node. |
| Scheduled task `WSL Compute Node` | At boot, runs `wsl -d <Distro> --exec /bin/sleep infinity` as you, without logon; systemd in the distro starts sshd and Docker. |
| WSL itself, a Debian distro, a Linux user | Only when missing. |

### Inside WSL / on Linux (`scripts/node-setup.sh`)

| Change | Where |
|---|---|
| sshd on port 2222 (not 22, so it never clashes with Windows' own OpenSSH), keys only, no root login, more parallel sessions for agents | `/etc/ssh/sshd_config.d/10-compute-node.conf`. Ubuntu's `ssh.socket` is switched to `ssh.service` so the port applies. `--allow-lan-password` restores password logins from private and Tailscale (`100.64.0.0/10`) ranges. |
| Docker Engine from Docker's apt repository, user added to `docker` | Skipped if another `docker` exists (Docker Desktop integration, `docker.io`). |
| NVIDIA Container Toolkit (`--gpus all`) | Only when an NVIDIA GPU is visible. |
| inotify limits for Mutagen and build tools | `/etc/sysctl.d/90-compute-node.conf` |
| `nvidia-smi` for SSH sessions (WSL puts `/usr/lib/wsl/lib` on PATH only for local terminals) | `/usr/local/bin/nvidia-smi`, `/etc/profile.d/wsl-lib.sh` (WSL only) |
| Sync root `/Users` owned by the node user | Mirrors macOS paths. For a Linux control node add `--sync-root /home/<you>`. |
| `cn-status`, `cn-authorize` | `/usr/local/bin`, settings in `/etc/compute-node.conf` |
| systemd on WSL | `/etc/wsl.conf [boot] systemd=true` (and `[user] default=`); exits with code 10 so the distro is restarted (install.ps1 does it). |

Without systemd (containers, some minimal hosts) sshd is started directly and Docker is not.

### Control node (`scripts/control-setup.sh`, `bin/cnode`)

| Change | Notes |
|---|---|
| `~/.ssh/config`: a marked block at the very top, `Include ~/.config/compute-node/ssh_config` | `Include` must precede any `Host` line. The block written by the original single-node setup (`# BEGIN wsl-compute`) is migrated and removed. |
| `~/.config/compute-node/` | `nodes`, `default`, generated `ssh_config` (one `Host cn-<name>` per node, `ControlMaster`/`ControlPersist 30m`, keychain on macOS), `known_hosts` (pinned host keys). |
| `~/.local/bin/cnode`, `rx`, `wsync` (symlinks), `~/.local/share/compute-node/cn-status` | PATH line added to your shell rc if needed. |
| `~/.ssh/id_ed25519` | Created only if missing; a passphrase goes to the macOS keychain. |
| Mutagen daemon, docker context per node | `docker context use <first node>` unless `--keep-docker-context`. |
| Agent rules block in `~/.claude/CLAUDE.md` (+ `~/.codex/AGENTS.md`) | Between markers, replaced in place; `--no-agent-rules` skips. |

## Security model

- sshd on the node accepts **keys only** (unless `--allow-lan-password`) and no root login. A
  control node is admitted by running `cn-authorize '<its public key>'` on the node.
- Host keys are **pinned**: `cnode add` scans the node's key and accepts it only if it matches
  `--fingerprint` from the join line (or a key you already trusted in `~/.ssh/known_hosts`). The
  aliases use `StrictHostKeyChecking yes` with a dedicated known_hosts file keyed by alias, so a
  changed IP (LAN vs Tailscale) does not matter but a changed key does. `--accept-new` (or
  answering `y` on a terminal) is trust-on-first-use: convenient on a network you control, but it
  would accept an impostor on the very first connection.
- Anyone who can run `rx` can run anything as the node user, and files written on the node sync
  back to the laptop. Treat a node like a second account of yours.

## Networking: Tailscale (recommended) or LAN

Tailscale gives each machine a stable name (`<machine>.<tailnet>.ts.net`) that works from
anywhere and usually connects directly on the same LAN. On the Windows node: install Tailscale
(or `-InstallTailscale`), log in, enable **Run unattended** in the tray menu. On the laptop:
enable **Launch at login**. In the admin console, **Disable key expiry** for both machines
(otherwise they log out after about 180 days) and keep **MagicDNS** on. `tailscale ping <host>`
should say `via <LAN IP>`; `via DERP` means relayed (slower; check UDP 41641). Without Tailscale
use the node's LAN IP (mirrored networking makes it the Windows IP). If the Windows Tailscale
address does not reach WSL, install Tailscale inside the distro instead.

## Limits

- **WSL memory**: the VM is capped by `.wslconfig` `memory=` (75% of RAM by default) and competes
  with Windows; heavy jobs on a node someone also uses interactively can starve both. Add
  `processors=<N>` under `[wsl2]` to limit cores.
- **Containers as compute nodes**: a Docker or RunPod container can serve `rx`/`wsync` (sshd
  starts without systemd), but it cannot run Docker Engine: unprivileged containers cannot create
  the namespaces and cgroups it needs, and cannot host user namespaces for rootless Docker either.
  Use `--no-docker` there.
- Each `rx` adds roughly 0.1-0.5 s; fine for real work, wasteful for thousands of tiny calls.
- The network is the bottleneck for big files: download datasets on the node, not through sync.
  Prefer a wired connection for the node.
- Paths must be identical: macOS control nodes map to `/Users/...` on the node. Linux control
  nodes need their home path (e.g. `/home/alice`) added as a sync root on the node.
- Windows 10 is not supported (no mirrored networking). Only Debian/Ubuntu (and derivatives)
  for compute nodes.
- No scheduling, no locking between agents: `rx nodes` shows what is running; choosing is up to
  you or your agent.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| PowerShell prints garbage and `You cannot call a method on a null-valued expression` | Windows PowerShell 5.1 reads BOM-less UTF-8 as the ANSI code page. `install.ps1` is ASCII-only for that reason; keep it that way if you edit it. |
| `Unexpected token` when starting the script | Run a downloaded copy with `powershell -ExecutionPolicy Bypass -File <full path>\install.ps1`. |
| `nvidia-smi: command not found` over SSH | Re-run the node setup (it links `nvidia-smi` into `/usr/local/bin`). |
| `rx` or sync hangs or asks for a passphrase | The key's passphrase is not in the agent/keychain: `ssh-add --apple-use-keychain ~/.ssh/id_ed25519` (macOS). |
| Cannot connect to port 2222 | On Windows: `wsl -l -v` shows Running; `.wslconfig` has `networkingMode=mirrored` and `wsl --shutdown` ran since; `Get-NetFirewallHyperVRule -Name WSL-SSH-2222` exists; try the LAN IP to rule out Tailscale. |
| `Host key verification failed` | The node's host key changed (reinstall?) or you reached another machine. Check the fingerprint on the node (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`) and re-run `cnode add ... --fingerprint`. |
| `Permission denied (publickey)` | Run the `cnode key` line on the node as the node user. |
| `rx: ... does not exist on <node>` | The folder is not synced to that node: `wsync -n <node>` in the project root. |
| `tailscale ping` shows `via DERP` | Relayed, not direct: same LAN? UDP 41641 blocked by the router? |
| `client version != tailscaled server version` | Only a warning; update the Tailscale CLI. |
| Sync conflicts | The control node wins; inspect with `wsync -l` or `mutagen sync monitor`. |
| `permission denied` from docker on the node | Group membership needs a new login: `wsl --shutdown` and start again (or log out/in). |
| After `wsl --shutdown` or a crash the node is gone | `Start-ScheduledTask "WSL Compute Node"`. Changed your Windows password? Re-run with `-SkipWslConfig -ResetTask`. |

## Uninstall

Control node:
```bash
mutagen sync terminate --label-selector compute     # all sessions made by wsync
mutagen daemon unregister
docker context use default && docker context rm <node> ...   # one per node, see: cnode list
rm -rf ~/.local/bin/{cnode,rx,wsync} ~/.local/share/compute-node ~/.config/compute-node
awk '/^# BEGIN compute-node$/{s=1;next} /^# END compute-node$/{s=0;next} !s' ~/.ssh/config > ~/.ssh/config.new && mv ~/.ssh/config.new ~/.ssh/config
```

Windows (elevated):
```powershell
Unregister-ScheduledTask -TaskName 'WSL Compute Node' -Confirm:$false
Remove-NetFirewallHyperVRule -Name WSL-SSH-2222
# restore .wslconfig from %USERPROFILE%\.wslconfig.bak-<time> if you want the old one back
```

Linux / WSL:
```bash
sudo rm /etc/ssh/sshd_config.d/10-compute-node.conf /etc/sysctl.d/90-compute-node.conf /etc/compute-node.conf \
        /usr/local/bin/cn-status /usr/local/bin/cn-authorize /etc/profile.d/wsl-lib.sh /usr/local/bin/nvidia-smi
sudo systemctl restart ssh   # or disable it: sudo systemctl disable --now ssh
sudo apt-get purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin nvidia-container-toolkit
# /Users holds synced copies of your projects; delete it once you no longer need them
```

## Repository layout

```
install.sh              entry point for both roles (curl | bash), fetches what it needs
install.ps1             Windows compute node (WSL2), then runs install.sh node inside WSL
scripts/node-setup.sh   compute-node setup (Debian/Ubuntu, WSL or plain Linux)
scripts/control-setup.sh  control-node setup (macOS/Linux)
bin/cnode               rx, wsync (symlinks to it) and the node registry/status
node/cn-status          node status snapshot (also piped over SSH by rx nodes)
node/cn-authorize       add/list/remove control-node keys on a node
templates/              agent rules blocks (en, zh-CN)
tests/                  tests/run.sh [lint|control|node|multinode|ps|all]
tools/set-raw-url.sh    fill in <raw-url> once the repository is published
```

## Tests

`tests/run.sh` runs everything that does not need a real Windows install:

- `lint`: shellcheck and `bash -n` for every script; `install.ps1` must be ASCII-only.
- `control`: the control-node install in throwaway HOMEs with ssh/mutagen/docker/brew stubbed:
  files written, agent rules (default on, `--no-agent-rules`, AGENTS.md), host-key pinning (wrong fingerprint refused, TOFU only on request), rx/wsync
  command lines, `rx nodes --json`, migration from the original single-node setup, and that a
  second run changes nothing.
- `node`: the compute-node install in fresh `debian:13` and `ubuntu:24.04` containers (no
  systemd): sshd config and key login, Docker packages, cn-authorize, `--allow-lan-password`,
  the WSL `wsl.conf`/exit-10 path, idempotency.
- `multinode`: two compute-node containers and a control container with two users, all real
  (ssh, Mutagen): join with fingerprints, `cn-authorize`, `wsync -n` of one folder to both nodes,
  `rx -n`, `rx nodes --json` with one node stopped and one hung.
- `ps`: parses `install.ps1` with Windows PowerShell 5.1 or pwsh (never runs it) and unit-tests
  its `.wslconfig` merge under pwsh in a container.

Docker tests use the current docker context and skip themselves when the engine has less than
`MIN_AVAILABLE_MB` (6000) free. No test uses a GPU.

## License

MIT, see [LICENSE](LICENSE).
