# Changelog

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
