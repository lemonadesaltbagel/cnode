# compute-node

在笔记本上使用一台 GPU 机器（Windows 电脑里的 WSL2 发行版，或任意 Debian/Ubuntu 机器），就像它的
CPU 和 GPU 直接插在本机上一样。代码和 AI 编程 agent 都留在笔记本上；重负载命令在算力节点的
**同一绝对路径**下执行，产出再同步回来。

[English](README.md)

```
 控制节点（笔记本：agent + 代码）                      算力节点（CPU / GPU / Docker）
 ┌──────────────────────────────────┐                ┌──────────────────────────────────┐
 │ 编辑、git、grep：在本地，最快    │ Mutagen 双向   │ n1: Windows 电脑里的 WSL2 发行版 │
 │ ~/proj  ── wsync -n n1 ──────────┼───────────────>│ /Users/you/proj（同名路径）      │
 │ rx -n n1 <命令> ─────────────────┼── ssh :2222 ──>│ 在那里执行，可用 CUDA            │
 │ docker --context n1 ... ─────────┼── ssh ────────>│ Docker Engine + NVIDIA 运行时    │
 │ rx nodes --json ─────────────────┼── ssh ──┐      └──────────────────────────────────┘
 └──────────────────────────────────┘         │      ┌──────────────────────────────────┐
   更多控制节点，各有自己的节点登记表：       └─────>│ n2: 普通 Linux 服务器            │
   任一控制节点可用任一算力节点                      └──────────────────────────────────┘
   （经 Tailscale 或局域网）
```

**为什么用同步而不是网络挂载：** agent 最频繁的操作是读文件和搜索，留在本地最快；SSHFS 这类挂载
会让每次读文件都走网络。两边路径完全一致，所以 `$PWD`、绝对路径和 `docker -v "$PWD:$PWD"` 都能直接用。

**范围：** 只做同步、发送命令、取回结果和报告节点状态。**不做调度**：由你（或 agent）看
`rx nodes` 自己选节点；每个算力节点自己管理进程（tmux 等）。

## 快速开始

两条命令：一条在算力节点上，一条在每台笔记本上。

### 1. 算力节点：在 WSL2 发行版里，或在 Debian/Ubuntu 机器上

```bash
curl -fsSL https://raw.githubusercontent.com/lemonadesaltbagel/cnode/main/install.sh | sudo bash -s -- node
```

在 WSL 终端里运行（需已装好 WSL2），或在 Linux 机器上运行。在 WSL 上它还会通过 WSL 互操作准备 Windows 一侧：合并
`.wslconfig`、检查页面文件，并在 Windows 桌面上**弹出一次 UAC 提示**，注册开机任务、防火墙规则以及（需要时）更大的页面文件，
见 [Windows 一侧](#windows-一侧wsl-节点)。它会安装 2222 端口的 sshd、
Docker Engine（检测到 GPU 时加装 NVIDIA Container Toolkit）、Tailscale、`cn-status`/`cn-authorize`，并建好同步根目录
`/Users`。Tailscale 登录时会打印一个网址，打开登录一次即可；无人值守安装可传入认证密钥：`... node --authkey tskey-auth-...`。
不用 Tailscale（只走局域网）：`--no-tailscale`。

其他参数：`--user 用户名`（默认是执行 sudo 的用户）、`--create-user`、`--port 2222`、`--sync-root 目录`（可重复）、
`--ts-hostname 名字`、`--key-only`、`--password-anywhere`、`--authorize '公钥'`、`--no-docker`、`--gpu auto|yes|no`、`--no-windows`（不动 Windows）、
`--no-elevate`（不弹 UAC，管理员步骤记为待办）、`--agent-sudo`（见 [sudo](#节点上的-sudo)）。普通 Linux 上用 GPU 要先装好
NVIDIA 驱动；WSL 上用 **Windows 版** NVIDIA 驱动（WSL 里不要装 Linux 驱动）。

最后会打印 join 行和笔记本上要执行的命令：

```
  join: host=<机器名>.<tailnet>.ts.net user=alice port=2222 fingerprint=SHA256:...
  curl -fsSL https://raw.githubusercontent.com/lemonadesaltbagel/cnode/main/install.sh | bash -s -- control --name <名字> --host <机器名>.<tailnet>.ts.net --user alice --port 2222
```

### 2. 控制节点：笔记本（macOS 或 Linux）

```bash
curl -fsSL https://raw.githubusercontent.com/lemonadesaltbagel/cnode/main/install.sh | bash -s -- control --host <主机> --user <用户>
```

`host`/`user` 用 join 行里的值（笔记本要在同一个 tailnet 里；用 `--no-tailscale` 时要在同一局域网）。它会**询问一次**节点用户的
密码，把本机的 SSH 密钥装到节点上，之后 `rx`、`wsync` 和 agent 都不会再要求输入。节点的主机密钥首次使用即信任；想预先固定，
加上 join 行里的 `--fingerprint SHA256:...`。

它还会安装 Mutagen（macOS 用 Homebrew，否则用官方二进制）、docker CLI（macOS + Homebrew）、没有 SSH 密钥时新建一把、把
`cnode`/`rx`/`wsync` 装到 `~/.local/bin`、为每个节点生成带连接复用的 SSH 别名和 docker context，并在 `~/.claude/CLAUDE.md`
（若存在 `~/.codex` 则还有 `~/.codex/AGENTS.md`）写入 agent 规则块（`--agent-rules 文件` 再加文件，`--no-agent-rules` 跳过）。
节点默认名为 `wsl`，可用 `--name` 指定。之后再加节点：`cnode add <名字> --host <主机> --user <用户>`。
`bash -s -- control --help` 查看全部参数。

手头没有密码（或节点用了 `--key-only`）？在节点上以节点用户身份执行 `cnode key` 打印的那一行：
`cn-authorize 'ssh-ed25519 AAAA... you@laptop-compute-node'`。

### 3. 验证

```bash
cd ~/某个项目
wsync                  # 把当前目录同步到默认节点
rx nproc               # 在节点的同名路径下执行
rx nvidia-smi          # 能看到 GPU
rx nodes               # 所有节点的硬件和负载
docker --context wsl run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi
```

## 日常使用

| 命令 | 作用 |
|---|---|
| `wsync [-n 节点] [目录]` | 把目录（默认 `.`）与节点上的同名路径双向同步。每个项目每个节点运行一次。 |
| `wsync -l [-n 节点]` | 列出同步会话（全部节点或某个节点）。 |
| `wsync -t [-n 节点 \| -a] [目录]` | 停止同步（两边文件都保留）。`-a`：所有节点。 |
| `rx [-n 节点] <命令>` | 先推送本地改动，在节点的同名目录执行（登录 shell），等节点产出同步回来再返回。退出码和输出原样传回。 |
| `rx nodes [--json]` | 并行查询所有节点（超时很短）：硬件（CPU 型号、核/线程数、实际可用 CPU、内存、GPU 型号/显存/驱动/CUDA、系统、是否 WSL）和实时负载（平均负载、可用内存、显存占用和利用率、同步根目录剩余磁盘、tmux 会话），以及同步状态。不可达的节点会被报告，不会报错退出。格式见下。 |
| `cnode add <名> --host H --user U [--port P] [--fingerprint FP]` | 登记另一个算力节点；询问一次密码并自动装好本机密钥。 |
| `cnode list` / `cnode default [名]` / `cnode remove <名>` | 管理节点登记表。 |
| `cnode key` | 打印本机的 `cn-authorize` 授权行（密码登录之外的手动方式）。 |
| `ssh cn-<节点>` | 登录节点。`ssh -N -L 8888:localhost:8888 cn-<节点>` 转发端口。 |
| `docker --context <节点> ...` | 在节点上用 Docker（安装时把第一个节点设为默认 context）。 |

节点选择顺序：`-n`，否则 `$RX_NODE`，否则登记表里的默认节点，否则唯一的那个节点。
含 shell 语法时整条加单引号，让它在节点上展开：`rx 'make -j$(nproc)'`。要执行远端一个名叫 `nodes` 的程序，
用 `rx -- nodes`。`RX_NO_PULL=1` 跳过最后的回传等待。

```bash
rx uv sync                       # 依赖目录不同步，要在节点上安装
rx uv run pytest -x
rx -n gpu2 python train.py --epochs 10
rx docker build -t myimg .       # 在节点本地构建，不上传构建上下文
docker run --rm --gpus all -v "$PWD:$PWD" -w "$PWD" myimg python run.py
```

**长任务**：在节点上用 tmux 后台运行，断网或合上笔记本都不受影响。

```bash
rx -n gpu1 'mkdir -p logs && tmux new -d -s train "python train.py 2>&1 | tee logs/train.log"'
tail -f logs/train.log           # 日志会同步回来
rx -n gpu1 tmux ls
ssh -t cn-gpu1 tmux attach -t train
```

### `rx nodes --json` 的格式

每个已登记的节点对应数组中的一项。`hardware` 是静态硬件信息（机器**是什么**），`load` 是实时状态（**现在**还剩多少）；
节点不可达时两者都是 `null`。示例（值为占位符）：

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
      "wsl": true, "container": false,
      "windows": {
        "available": true, "os": "<Windows edition and build>", "ram_gb": 31.1,
        "pagefile_total_gb": 55.5, "pagefile_system_managed": false,
        "pagefiles": [{"name": "C:\\pagefile.sys", "allocated_gb": 23.5}, {"name": "D:\\pagefile.sys", "allocated_gb": 32.0}],
        "commit_limit_gb_at_install": 86.0, "commit_limit_gb": 86.0,
        "recommended": {"wsl_memory_gb": 24, "wsl_swap_gb": 6, "pagefile_gb": 55, "pagefile_drive": "D:", "commit_limit_gb": 86.1},
        "wslconfig": {"path": "C:\\Users\\<you>\\.wslconfig", "memory": "24GB", "swap": "6GB", "vmIdleTimeout": "-1",
                      "networkingMode": "mirrored", "autoMemoryReclaim": "gradual"},
        "autostart": "registered", "tailscale_on_windows": false,
        "admin_script": "C:\\Users\\<you>\\.cnode\\windows-admin.ps1",
        "warnings": [],
        "pending": [{"id": "wsl-restart", "title": "Restart WSL so .wslconfig (...) takes effect",
                     "run": "wsl --shutdown   (in Windows, when nothing is running in WSL; ...)", "needs": "wsl-shutdown"}]
      }
    },
    "load": {
      "loadavg": [0.5, 0.7, 0.9], "mem_available_mb": 18000,
      "gpus": [{"index": 0, "mem_used_mb": 1200, "mem_free_mb": 14800, "util_pct": 3}],
      "disk": [{"path": "/Users", "free_mb": 500000, "total_mb": 1000000}],
      "tmux": ["train"], "uptime_s": 86400,
      "windows_commit_free_gb": 40.2, "windows_warnings": []
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

| 字段 | 含义 |
|---|---|
| `hardware.cpu_model`、`cpu_cores`、`cpu_threads` | 来自 `/proc/cpuinfo`（或 `lscpu`）。 |
| `hardware.cpus_effective` | 实际可用的 CPU 数：CPU 亲和性（`nproc`）再受 cgroup CPU 配额限制（容器里常显示宿主机的核数）。 |
| `hardware.mem_total_mb`、`mem_limit_mb` | 内核看到的内存（WSL 上就是 `.wslconfig` 的上限），以及 cgroup 内存上限（没有则为 `null`）。 |
| `hardware.gpus[]` | NVIDIA 通过 `nvidia-smi`（型号、显存、驱动、CUDA、计算能力）。AMD/Intel 从 sysfs 读取驱动提供的信息（型号可能为 `null`，`cuda` 为 `null`）。空数组表示没有 GPU。 |
| `hardware.os`、`kernel`、`arch`、`wsl`、`container` | 发行版、内核版本、CPU 架构、是否在 WSL 中、是否在容器中。 |
| `load.loadavg` | 1/5/15 分钟平均负载。 |
| `load.mem_available_mb` | `MemAvailable`，再受 cgroup 上限约束。 |
| `load.gpus[]` | 每块 GPU（`index` 对应）：已用/剩余显存和利用率。 |
| `load.disk[]` | 节点每个同步根目录的剩余空间。 |
| `load.tmux` | 节点用户的 tmux 会话（用 `rx ... tmux new -d` 启动的任务）。 |
| `hardware.windows` | 仅 WSL 节点（否则为 `null`）：Windows 宿主的内存、页面文件、提交限制（实时）、推荐值、`.wslconfig` 的值、`autostart`（`registered`/`pending`）、`warnings[]`，以及待办步骤 `pending[]`：每项有 `id`、`title`、`run`（要执行的准确命令）和 `needs`（`admin`、`reboot`、`wsl-shutdown`）。已明显完成的步骤（新内存上限已生效、提交限制已达到）会自动消失。 |
| `load.windows_commit_free_gb`、`load.windows_warnings[]` | 实时的 Windows 提交内存余量，以及余量偏低时的警告。任务必须同时放得进它和 `mem_available_mb`。 |
| `sync[]` | 本控制节点与该节点之间的 Mutagen 会话（状态、冲突数、是否连接、是否暂停）。 |

表格形式（`rx nodes`）每个节点一行，内容相同。在节点上运行 `cn-status`、`cn-status --json` 输出该节点自己的部分。

### rx 和 wsync 的工作方式

- `wsync` 为每个“目录 × 节点”建一个 Mutagen 会话，名为 `<节点>-<sha1(路径) 前 10 位>`，标签
  `compute=<节点>`，远端为 `cn-<节点>:<同名路径>`，模式 `two-way-resolved`（冲突时控制节点优先）。
  Mutagen 守护进程在后台持续同步（macOS 上注册为 launchd 服务）。
- `rx` 从 `$PWD` 向上查找覆盖它的会话，先 `mutagen sync flush`（节点看到最新代码），再执行
  `ssh cn-<节点> 'cd <同名路径> && exec bash -lc <命令>'`，最后再 flush 一次（输出文件可以立刻读）。
  有连接复用（`ControlMaster`、`ControlPersist 30m`），每次调用约多 0.1–0.5 秒。
- 不同步的目录（两边各自维护）：`node_modules`、`.venv`、`venv`、`__pycache__`、`target`、
  `.mypy_cache`、`.pytest_cache`、`.ruff_cache`、`.next`、`.turbo`、`.gradle`、`.DS_Store`。
  其余文件都双向同步，包括节点上生成的结果。

### 多个节点、多个控制节点

每个控制节点有自己的登记表（`~/.config/compute-node/nodes`，每行 `名字 主机 用户 端口`）和生成的 SSH
别名 `cn-<名字>`；控制节点只要在某个算力节点上被授权，就能使用它。一个目录可以同时同步到多个节点
（每个节点一个会话）；控制节点是中心，所以 `rx -n n1` 写出的文件会经笔记本再到达 `n2`。

**两个控制节点把同一路径同步到同一个算力节点**（例如两台用户名相同的 Mac，都以同一个节点用户把
`/Users/alice/proj` 同步到同一个节点）：此时两个会话在节点一侧是同一个目录，算力节点就成了两台笔记本之间的中转。
每个会话在冲突时都以自己的笔记本为准，所以只有“同一时间只有一边在改”（或各改各的子目录）才安全；
两边同时改同一个文件，或一边删除而另一边在改，可能来回覆盖甚至丢失修改。不同用户或不同路径互不影响。
建议每个目录在每个节点上只有一个“主人”。

### Agent 规则

控制节点安装会在 `<!-- BEGIN compute-node -->` 和 `<!-- END compute-node -->` 之间写入一段规则：写到
`~/.claude/CLAUDE.md`（Claude Code）、存在 `~/.codex` 时写到 `~/.codex/AGENTS.md`（Codex），以及每个
`--agent-rules 文件`；`--lang zh-CN` 用中文，`--no-agent-rules` 跳过。重跑时原位替换这一段，文件其余内容不动。
规则告诉 agent：在本地编辑和搜索，构建/测试/GPU 任务一律走 `rx`；派发重负载前先 `rx nodes --json`，按 `hardware`
（CPU 型号、实际可用 CPU、内存、GPU 型号/显存/CUDA）和实时 `load` 选节点；不要假定节点空闲；保留内存余量（节点可用内存或
显存（或 Windows 提交内存余量）低于任务所需加余量时不要启动）；节点报告 Windows 待办步骤时先把准确命令告诉用户；不在节点上用 sudo
（见 [sudo](#节点上的-sudo)）；长任务在节点上用 tmux 起一个唯一名字的会话；从同步目录读结果。见
[templates/agent-rules.zh-CN.md](templates/agent-rules.zh-CN.md)。想在 Claude Code 里免确认调用 `rx`，可以允许
`Bash(rx:*)` 和 `Bash(wsync:*)`；这样 agent 不经确认就能在节点上执行任意命令，它在节点上写的文件也会同步回来。

## 安装脚本做了哪些更改

### 算力节点（`scripts/node-setup.sh`）

| 更改 | 位置 / 原因 |
|---|---|
| sshd 端口 2222（不用 22，避免和 Windows 自带的 OpenSSH 冲突）、密钥登录不限来源，密码登录只接受私有网段、链路本地、本机和 Tailscale 地址，禁止 root，为 agent 调大并发会话 | `/etc/ssh/sshd_config.d/10-compute-node.conf`。Ubuntu 的 `ssh.socket` 会改成 `ssh.service`，端口才生效。`--key-only` 关闭密码登录；`--password-anywhere` 允许公网地址也用密码。 |
| Tailscale 官方 apt 仓库的 Tailscale，运行 `tailscaled` 并 `tailscale up` | 有 systemd 时作为服务；没有 systemd 时直接启动；没有 TUN 设备时用 userspace-networking 模式。`--no-tailscale` 跳过。 |
| Docker 官方 apt 仓库的 Docker Engine，用户加入 `docker` 组 | 已有其他来源的 `docker`（Docker Desktop 集成、`docker.io`）时跳过。没有 systemd 时用它的 init 脚本启动。 |
| NVIDIA Container Toolkit（`--gpus all`） | 仅在检测到 NVIDIA GPU 时安装。 |
| inotify 上限（Mutagen、构建工具） | `/etc/sysctl.d/90-compute-node.conf` |
| 让 SSH 会话找到 `nvidia-smi`（WSL 只给本地终端加 `/usr/lib/wsl/lib`） | `/usr/local/bin/nvidia-smi`、`/etc/profile.d/wsl-lib.sh`（仅 WSL） |
| 让 `rx` 会话能用 nvm：`rx` 用 `bash -lc` 执行，而 `~/.bashrc` 在非交互 shell 里开头就返回，nvm 安装时写在那里的加载行不会执行，`node`/`npm` 找不到 | `/etc/profile.d/cnode-user-tools.sh` 在非交互的 bash 登录 shell 里加载 `~/.nvm/nvm.sh`（交互 shell 仍走 `~/.bashrc`） |
| 同步根目录 `/Users`，归节点用户所有 | 对应 macOS 路径。Linux 控制节点请加 `--sync-root /home/<你>`。 |
| `cn-status`、`cn-authorize` | `/usr/local/bin`，设置在 `/etc/compute-node.conf` |
| Windows 宿主（仅 WSL） | `.wslconfig` 合并、开机任务、Hyper-V 防火墙规则、页面文件：见 [Windows 一侧](#windows-一侧wsl-节点)。状态在 `/etc/cnode/{windows.json,windows.env,pending.json}`。 |
| `/etc/sudoers.d/90-cnode-<用户>` | 仅在 `--agent-sudo` 时。 |
| WSL 上的 systemd | `/etc/wsl.conf [boot] systemd=true` 和 `[user] default=`，发行版下次启动时生效；在那之前各服务直接启动，现在不需要重启任何东西。 |

### 控制节点（`scripts/control-setup.sh`、`bin/cnode`）

| 更改 | 说明 |
|---|---|
| `~/.ssh/config` 最顶部的标记块：`Include ~/.config/compute-node/ssh_config` | `Include` 必须在所有 `Host` 之前。旧版单节点安装写的块（`# BEGIN wsl-compute`）会被迁移并删除。 |
| `~/.config/compute-node/` | `nodes`、`default`、生成的 `ssh_config`（每个节点一个 `Host cn-<名字>`，`ControlMaster`/`ControlPersist 30m`，macOS 上用钥匙串）、`known_hosts`（主机密钥：首次使用即信任，或用 `--fingerprint` 预先固定）。 |
| `~/.local/bin/cnode`、`rx`、`wsync`（符号链接）、`~/.local/share/compute-node/cn-status` | 需要时在 shell 配置文件里加 PATH。 |
| `~/.ssh/id_ed25519` | 仅在缺少时新建；有密码短语时存入 macOS 钥匙串。 |
| Mutagen 守护进程、每个节点一个 docker context | 默认 `docker context use <第一个节点>`，`--keep-docker-context` 可跳过。 |
| `~/.claude/CLAUDE.md`（及 `~/.codex/AGENTS.md`）中的 agent 规则块 | 在标记之间，原位替换；`--no-agent-rules` 跳过。 |

## Windows 一侧（WSL 节点）

安装在 WSL 里运行，通过 WSL 互操作访问 Windows（用完整路径 `/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe`，
因为非交互 shell 里 `powershell.exe` 常常不在 PATH 中）。它绝不执行 `wsl --shutdown`，也绝不重启；这些留给你在没有任务运行时去做。

| 步骤 | 方式 | 需要管理员？ |
|---|---|---|
| 读取内存、页面文件、提交限制、磁盘、开机任务、Windows 上的 Tailscale | CIM 查询 | 否 |
| 合并 `%USERPROFILE%\.wslconfig`（先备份为 `.wslconfig.bak-<时间>`；其他键保留）：`[wsl2] memory=<M>GB`、`swap=<ceil(M/4)>GB`、`vmIdleTimeout=-1`（闲置时不停 VM）、`networkingMode=mirrored`（WSL 共用 Windows 的网卡）、`[experimental] autoMemoryReclaim=gradual`（把空闲缓存还给 Windows）。你自己设过的 `memory=` 会保留（高于 M 时给出警告）。`wsl --shutdown` 后生效。 | 改文件 | 否 |
| **开机自启**：计划任务 `WSL Compute Node`，触发器“启动时”，以你的账户运行 `wsl.exe -d <发行版> --exec /bin/sleep infinity`，无论是否有人登录（会问一次 Windows 密码，不是 PIN）；发行版里的 systemd 再拉起 sshd、Docker 和 Tailscale | `Register-ScheduledTask` | 是 |
| Hyper-V 防火墙规则 `WSL-SSH-2222`（mirrored 网络下进入 WSL 的流量） | `New-NetFirewallHyperVRule` | 是 |
| 页面文件太小时设为固定大小（见下文）；需要重启 | `Win32_PageFileSetting` | 是 |
| 当前电源计划会睡眠或休眠时，改为接通电源时永不睡眠、永不休眠（电池设置不变） | `powercfg /change standby-timeout-ac 0`、`hibernate-timeout-ac 0` | 是 |

管理员步骤写入 `%USERPROFILE%\.cnode\windows-admin.ps1`；有人在终端前时，用 `Start-Process -Verb RunAs` 运行（Windows 桌面上
**一次 UAC 提示**）。如果提示被拒绝、无法弹出（没有终端、`--no-elevate`）或某步失败，该步骤会作为**待办**记录在
`/etc/cnode/pending.json`，并附上准确命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\<你>\.cnode\windows-admin.ps1"   # 管理员 PowerShell
```

待办步骤（以及改了 `.wslconfig` 后的 `wsl --shutdown`、改了页面文件后的重启）会在安装结束时打印，并由 `rx nodes --json` 在
`hardware.windows.pending` 中报告，agent 在那里启动重负载前会先告诉用户。重跑安装会刷新它们。

如果 Windows 本身已经运行 Tailscale，安装不会在 WSL 里再加一个 tailnet 节点：mirrored 网络下用 Windows 机器的 Tailscale 名字访问节点。

仍需你在 Windows 上做的：安装 WSL2 和 Debian/Ubuntu 发行版（`wsl --install -d Debian`）、Windows 版 NVIDIA 驱动，以及在待办列表要求时执行 `wsl --shutdown` 或重启。

## 内存与页面文件

Windows 的**提交限制**（commit limit）= 物理内存 + 页面文件。所有提交的内存都算在里面：Windows 及其程序、WSL VM（最多到 `memory=`
上限）、GPU 共享内存。总量碰到上限时 Windows 无法再分配内存，即使“可用内存”看起来还够，机器也可能崩溃或杀掉 WSL VM。所以安装按内存
大小算出三个值：

| | 公式 | 31.1 GB 内存（实例） |
|---|---|---|
| WSL 内存上限 `M` | `floor(RAM - max(6, 0.2 x RAM))` | 31.1 - 6.2 = 24.9 -> **24 GB** |
| WSL swap | `ceil(M / 4)` | **6 GB** |
| 页面文件总量 `P` | `round(RAM) + M`，固定大小（初始 = 最大） | 31 + 24 = **55 GB** |
| 提交限制 | RAM + P | 31.1 + 55 = **约 86 GB** |

这与一台满负载也稳定运行的机器一致：内存 31.1 GB，WSL 内存 24 GB，页面文件 C: 系统管理（已分配 23.5 GB）+ D: 固定 32 GB = 55.5 GB，
提交限制 86 GB。

规则：页面文件放在剩余空间最大的固定磁盘上，放完后该盘要还剩 20 GB；空间不够时上限为“剩余 - 20 GB”，并大声警告（腾出空间或调低
`memory=`）。如果原来是 Windows 自动管理页面文件，会保留 C: 上的系统管理页面文件，再在选定的盘上加固定大小的页面文件。已有页面文件
总量已达到 P 时不做改动（系统管理的按已分配大小计算）。当前状态无需管理员权限即可读取（`Win32_ComputerSystem.AutomaticManagedPagefile`、
`Win32_PageFileSetting`、`Win32_PageFileUsage`、`Win32_OperatingSystem.TotalVirtualMemorySize`/`FreeVirtualMemory`）。

## 节点上的 sudo

agent 不应使用 `sudo`：它会要求输入 agent 无法输入的密码。规则块要求 agent 装到用户空间（`uv`、`pip --user`、`rustup`、`npm --prefix`，
或 `apt download <包>` + `dpkg-deb -x <包>.deb ~/.local/opt/<包>`）；确实需要 root 时，请你在自己的终端里运行 `rx -n <节点> sudo ...`。
`rx` 只在 stdin 和 stdout 都是终端时才分配 TTY，所以你运行时 sudo 正常提示，agent 运行时会立刻失败而不是卡住。

节点安装加 `--agent-sudo` 会写入 `/etc/sudoers.d/90-cnode-<用户>`，给节点用户 `NOPASSWD:ALL`，agent 就能无人值守地用 `sudo`。
**默认关闭**：这等于让所有能以该用户登录节点的人（每个已授权的控制节点、上面的每个 agent）拿到节点的完整 root；在 WSL 上，发行版里的
root 还能通过 `/mnt/c` 访问你的 Windows 文件。不带这个参数重跑安装会删除该文件。

## 安全模型

本工具优先考虑易部署，需要时再加固。

- sshd **密钥登录不限来源，密码登录只接受私有网段、链路本地、本机和 Tailscale 地址**（配置里的 `Match Address`；禁止 root）。
  每个控制节点只需要用一次密码：`cnode add` 用它登录并装好该机的密钥，之后都走密钥。处在公网地址的控制节点改用 `cn-authorize`，
  或者用 `--password-anywhere` 安装节点。所有控制节点都加好后，可以用 `--key-only` 重跑节点安装来关闭密码登录。
- 主机密钥**首次使用即信任**，之后按节点固定在专用 known_hosts 里（`StrictHostKeyChecking yes`），所以密钥**变化**会被拒绝
  （若是预期的变化：先 `cnode remove` 再 `cnode add`）。在不信任的网络里，传入 join 行里的 `--fingerprint`，第一次连接也会被验证。
- 用 Tailscale 时，只有你 tailnet 里的机器能连到 2222 端口；用 `--no-tailscale` 时端口对局域网开放。
- 能运行 `rx` 的人就能以节点用户身份执行任何命令，节点上写的文件也会同步回笔记本。请把节点当作你的另一个账户对待。
- `CN_PASSWORD`（用于脚本化的 `cnode add`）会把密码放进那一条命令的环境变量里；能手动输入就手动输入。

## 网络：默认 Tailscale，或局域网

Tailscale 给每台机器一个固定名字（`<机器名>.<tailnet>.ts.net`），在哪都能连，同一局域网内通常直连。节点安装会在 WSL 发行版或
Linux 机器内部运行它，所以不需要改路由器或 Windows。笔记本上也装 Tailscale 并登录同一个 tailnet。管理后台里给节点选
**Disable key expiry**（否则约 180 天后登录过期），保持 **MagicDNS** 开启。`tailscale ping <主机>` 应显示 `via <局域网IP>`；
`via DERP` 表示走中继（较慢，检查 UDP 41641）。不用 Tailscale 时填节点的局域网 IP（`--no-tailscale`）。

## 限制

- **WSL 内存**：VM 上限为 `M`（见 [内存与页面文件](#内存与页面文件)），并与 Windows 争用内存和提交内存；`rx nodes` 同时显示
  `mem_available_mb` 和 `windows_commit_free_gb`。
- **容器当算力节点**：Docker 或 RunPod 容器可以提供 `rx`/`wsync`（没有 systemd 也会直接启动 sshd 和 tailscaled，Tailscale 用
  userspace 模式），但跑不了 Docker Engine：非特权容器无法创建它需要的命名空间和 cgroup，也无法承载 rootless Docker 所需的用户命名空间。
  这种情况用 `--no-docker`。
- 每次 `rx` 约多 0.1–0.5 秒；正常任务可忽略，不适合成千上万次零碎调用。
- 大文件的瓶颈在网络：数据集直接在节点上下载，不要经同步传。
- 路径必须一致：macOS 控制节点对应节点上的 `/Users/...`；Linux 控制节点需要把自己的家目录路径（如 `/home/alice`）加为节点的同步根目录。
- 算力节点只支持 Debian/Ubuntu 及其衍生版。
- 不调度、agent 之间不加锁：`rx nodes` 显示正在运行的任务，选哪个节点由你或 agent 决定。

## 故障排查

| 现象 | 原因 / 解决 |
|---|---|
| 过一段时间节点就连不上了（WSL） | 发行版或 WSL VM 停了：开机任务注册了吗（`hardware.windows.autostart`）？改 `.wslconfig` 后做过 `wsl --shutdown` 吗（`vmIdleTimeout=-1`）？用 `Start-ScheduledTask "WSL Compute Node"` 或打开 WSL 终端重新启动。 |
| 重负载时整台电脑崩溃或 WSL 退出 | 提交内存耗尽：查看 `hardware.windows.pending`/`warnings` 和 `load.windows_commit_free_gb`；执行页面文件步骤并重启（见 [内存与页面文件](#内存与页面文件)）。 |
| UAC 提示没出现或被拒绝 | 这些步骤成了待办：在管理员 PowerShell 里运行打印出的 `powershell ... windows-admin.ps1` 命令，或从 WSL 终端重跑节点安装。 |
| 改过 Windows 密码 | 开机任务里存着旧密码：删除该任务后再以管理员身份运行 `windows-admin.ps1`，或重跑安装。 |
| `tailscale up` 一直等待 | 打开打印的网址登录，或用 `--authkey` 重跑。用 `tailscale status` 检查。 |
| 通过 SSH 执行时 `nvidia-smi: command not found` | 重跑节点安装（会把 `nvidia-smi` 链接到 `/usr/local/bin`）。 |
| `rx` 或同步卡住、要求输入密码短语 | 密钥的密码短语不在 agent/钥匙串里：`ssh-add --apple-use-keychain ~/.ssh/id_ed25519`（macOS）。 |
| `cnode add` 在密码登录这一步失败 | 密码错误、节点用户没有密码（在节点上 `sudo passwd <用户>`），节点用了 `--key-only`，或本机从公网地址连接（密码只接受私有网段和 Tailscale 地址）：改为在节点上执行 `cnode key` 打印的那一行。 |
| `rx`/`wsync`/`cnode` 提示节点*在 SSH 握手前关闭了连接*；`rx nodes` 显示 `Connection reset by` 或 `Connection closed by` 并附 PerSourcePenalties 说明 | OpenSSH 9.8 及以上（Debian 13）会在认证失败或未认证断开后暂时封锁该来源地址（`PerSourcePenalties`，最长 10 分钟）。节点本身没坏。等一会儿，先解决原因（密钥不对、还没装密钥）再重试一次；在节点上执行 `sshd -T \| grep persourcepenalties` 可查看设置。已有的 SSH 主连接（之前的 `rx` 或 Mutagen 同步建立的）在此期间照常可用。`rx` 用的是 `ssh -q`，这种情况下什么都不打印，所以 ssh 失败（退出码 255）后它会用一次不认证的 `ssh-keyscan` 检查，并打印说明。 |
| 连不上 2222 端口 | 节点在运行吗（两边 `tailscale status`）？在同一个 tailnet 吗？WSL 上不用 Tailscale 时见上文“局域网访问”。 |
| `host key ... CHANGED` / `Host key verification failed` | 节点重装过，或连到了别的机器。在节点上核对（`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`）；若是预期的：`cnode remove <节点>` 后重新添加。 |
| `sudo: a terminal is required` / agent 卡在 sudo | 对 agent 来说是预期行为：你自己运行 `rx -n <节点> sudo ...`，或用 `--agent-sudo` 安装（见 [sudo](#节点上的-sudo)）。 |
| `rx: ... does not exist on <节点>` | 这个目录没有同步到该节点：在项目根运行 `wsync -n <节点>`。 |
| `tailscale ping` 显示 `via DERP` | 走了中继：是否在同一局域网？路由器是否拦了 UDP 41641？ |
| 同步冲突 | 以控制节点为准；用 `wsync -l` 或 `mutagen sync monitor` 查看。 |
| 节点上 docker 报 `permission denied` | 加入组后要重新登录（WSL 上：关掉所有 WSL 终端，或 `wsl --terminate <发行版>`）。 |

## 卸载

控制节点：
```bash
mutagen sync terminate --label-selector compute     # wsync 建立的全部会话
mutagen daemon unregister
docker context use default && docker context rm <节点> ...   # 每个节点一个，见 cnode list
rm -rf ~/.local/bin/{cnode,rx,wsync} ~/.local/share/compute-node ~/.config/compute-node
awk '/^# BEGIN compute-node$/{s=1;next} /^# END compute-node$/{s=0;next} !s' ~/.ssh/config > ~/.ssh/config.new && mv ~/.ssh/config.new ~/.ssh/config
```

算力节点（WSL 或 Linux）：
```bash
sudo rm /etc/ssh/sshd_config.d/10-compute-node.conf /etc/sysctl.d/90-compute-node.conf /etc/compute-node.conf \
        /usr/local/bin/cn-status /usr/local/bin/cn-authorize /etc/profile.d/wsl-lib.sh /usr/local/bin/nvidia-smi
sudo systemctl restart ssh   # 或者停用：sudo systemctl disable --now ssh
sudo tailscale logout; sudo apt-get purge tailscale
sudo rm -rf /etc/cnode /etc/sudoers.d/90-cnode-*
sudo apt-get purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin nvidia-container-toolkit
# /Users 下是同步过来的项目副本，确认不再需要后再手动删除
```

Windows（管理员 PowerShell；只撤销安装添加的内容）：
```powershell
Unregister-ScheduledTask -TaskName 'WSL Compute Node' -Confirm:$false
Remove-NetFirewallHyperVRule -Name WSL-SSH-2222
# 页面文件改回自动管理（重启后生效）：
$cs = Get-CimInstance Win32_ComputerSystem; Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true }
# .wslconfig：需要旧版本时恢复 %USERPROFILE%\.wslconfig.bak-<时间>；删除 %USERPROFILE%\.cnode
```

安装脚本从 `https://raw.githubusercontent.com/lemonadesaltbagel/cnode/main` 下载；用 fork 或某个 tag 时设置 `CN_RAW_URL`。

## 测试

`tests/run.sh [lint|unit|ps|control|node|multinode|all]` 运行全部测试，不触碰真实机器（详见英文 README 的 Tests 一节）：
内存/swap/页面文件公式与 `.wslconfig` 合并的单元测试、生成的 PowerShell 的纯解析检查（从不执行）、控制节点安装（桩替身）、
Debian/Ubuntu 容器里的节点安装（密码与密钥登录、`--key-only`、Tailscale、模拟互操作下的 Windows 一侧：待办步骤、UAC 接受/拒绝、模拟重启、
`pending.json` -> `cn-status --json`、`--agent-sudo`），以及两个节点容器 + 两个控制用户的端到端测试。
Docker 测试使用当前 docker context，引擎可用内存低于 `MIN_AVAILABLE_MB`（7000）时自动跳过，容器有内存上限；不使用 GPU，也不触碰真实的
Windows 宿主（`.wslconfig`、页面文件、计划任务）。

## 许可证

MIT，见 [LICENSE](LICENSE)。
