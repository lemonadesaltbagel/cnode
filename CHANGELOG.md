# Changelog

## 0.2.0 - 2026-11-07

Simpler deployment: one command inside WSL (or on a Linux box), one on the laptop.

- Removed the Windows PowerShell installer (`install.ps1`) and every Windows-side change
  (enabling WSL, distro registration, `.wslconfig`, firewall rule, power settings, boot task).
  The compute node is set up entirely from inside the WSL2 distro or Linux machine; what still
  needs Windows is documented in "What still needs Windows".
- Tailscale is installed and started inside the distro by default (systemd service, or started
  directly without systemd, userspace networking without a TUN device); `tailscale up` prints the
  login URL, `--authkey` logs in unattended, `--ts-hostname` names the machine, `--no-tailscale`
  keeps LAN-only.
- No restart step on WSL: systemd is enabled for the next start while services are started
  directly now (the old exit code 10 is gone).
- sshd accepts passwords by default (keys keep working; `--key-only` hardens it, replacing
  `--allow-lan-password`). `cnode add` logs in once with the password (prompt, or `CN_PASSWORD`)
  and installs the control node's key, so later `rx`/`wsync` calls never prompt. `cn-authorize`
  stays as a manual alternative.
- Host keys are trusted on first use by default and pinned afterwards; a changed key is refused.
  `--fingerprint` remains for pinning up front; `--accept-new` and `--copy-id` are now no-ops.
- Fixed: the piped install (`curl | bash`) refused the real download URL after it was filled in;
  `tools/set-raw-url.sh` is removed.
- Tests: password login and automatic key install, Tailscale package with stubbed daemon and
  login, `--no-tailscale`, the piped install; the PowerShell tests are removed.

## 0.1.0 - unreleased

First public release, generalised from a private three-script setup (WSL root setup, Windows
admin script, Mac setup).

- One command per role: `install.ps1` (Windows: enables WSL2, installs a distro, then runs the
  node setup inside it), `install.sh node` (plain Linux or WSL), `install.sh control` (macOS/Linux).
  All steps detect what is already there and are safe to re-run.
- Many control nodes x many compute nodes: node registry (`cnode add/list/remove/default`),
  one SSH alias `cn-<name>` per node, `rx -n <node>`, `wsync -n <node>` (one Mutagen session per
  folder x node), `rx nodes [--json]` status of all nodes in parallel, with static `hardware`
  (CPU model, cores/threads, cgroup-effective CPUs, RAM, GPU name/memory/driver/CUDA, OS, WSL)
  kept separate from live `load`. No scheduling.
- Joining: the node prints a join line with its host-key fingerprint; `cnode add --fingerprint`
  pins the host key (`StrictHostKeyChecking yes`, dedicated known_hosts); `cn-authorize` on the
  node admits a control node's key.
- sshd is key-only by default (`--allow-lan-password` restores password logins from private and
  Tailscale ranges, the previous behaviour).
- `.wslconfig` is merged instead of overwritten; the NVIDIA Container Toolkit is installed only
  when a GPU is present; Ubuntu's socket-activated sshd is handled; works without systemd
  (containers).
- Linux control nodes (Mutagen release binary, no keychain options).
- Agent rules block for coding agents, written by default to `~/.claude/CLAUDE.md` (and
  `~/.codex/AGENTS.md` if present) between markers; `--agent-rules FILE`, `--lang zh-CN`,
  `--no-agent-rules`. Covers node selection by hardware and free resources, memory headroom,
  tmux for long jobs.
- Compatible with the private setup: node `wsl` keeps the `wsl` SSH alias and the
  `wsl-<hash>` session names; its `# BEGIN wsl-compute` SSH block is migrated automatically.
- Tests: shellcheck, control install in a throwaway HOME, node install in Debian/Ubuntu
  containers, a multi-node end-to-end run, and a PowerShell parse check.
