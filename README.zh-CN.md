# compute-node

在笔记本上使用一台 GPU 机器（通过 WSL2 的 Windows 电脑，或任意 Debian/Ubuntu 机器），就像它的
CPU 和 GPU 直接插在本机上一样。代码和 AI 编程 agent 都留在笔记本上；重负载命令在算力节点的
**同一绝对路径**下执行，产出再同步回来。

[English](README.md)

```
 控制节点（笔记本：agent + 代码）                      算力节点（CPU / GPU / Docker）
 ┌──────────────────────────────────┐                ┌──────────────────────────────────┐
 │ 编辑、git、grep：在本地，最快    │ Mutagen 双向   │ n1: Windows 11 -> WSL2 (Debian)  │
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

顺序不太重要，通常是：先装算力节点，复制它打印的 **join 行**；用它安装控制节点；再把控制节点打印的
**授权行**粘贴到节点上执行。

下文的 `<raw-url>` 指本仓库的 raw 下载地址（`https://raw.githubusercontent.com/<owner>/<repo>/main`）。

### 1a. Windows 11 上的算力节点（WSL2）

在**管理员** PowerShell 中（右键 > 以管理员身份运行）：

```powershell
irm <raw-url>/install.ps1 | iex
```

带参数（都可选）：

```powershell
& ([scriptblock]::Create((irm <raw-url>/install.ps1))) -Distro Debian -User alice -AuthorizeKey 'ssh-ed25519 AAAA... laptop'
```

它会按需启用 WSL2（之后要求重启，再运行同一条命令）；没有 Debian/Ubuntu 发行版时安装 Debian；合并下文的
`.wslconfig` 设置；在发行版里执行 Linux 端安装；添加 Hyper-V 防火墙规则；插电时不睡眠；注册开机任务，
无需登录即可上线。最后打印 join 行。参数：`-Distro`、`-User`、`-SshPort 2222`、`-MemoryGB`、
`-SyncRoot /Users`、`-AuthorizeKey`、`-NoDocker`、`-AllowLanPassword`、`-InstallTailscale`、
`-SkipWslConfig`、`-SkipPower`、`-SkipTask`、`-SkipFirewall`、`-ResetTask`。

要求：Windows 11 22H2 或更新（mirrored 网络模式）；装 **Windows 版** NVIDIA 驱动（WSL 里不要装 Linux 驱动）。
创建开机任务时会问一次 Windows 账户**密码**（不是 PIN；微软账号就输微软账号密码）。

### 1b. 普通 Linux 上的算力节点（Debian/Ubuntu）

```bash
curl -fsSL <raw-url>/install.sh | sudo bash -s -- node
```

参数：`--user 用户名`（默认是执行 sudo 的用户）、`--create-user`、`--port 2222`、`--sync-root 目录`
（可重复，默认 `/Users`）、`--authorize '公钥'`、`--allow-lan-password`、`--no-docker`、`--gpu auto|yes|no`。
有 GPU 时先装好 NVIDIA 驱动，安装脚本检测到 GPU 会加装 NVIDIA Container Toolkit。

两种方式最后都会打印类似：

```
  join: host=<机器名>.<tailnet>.ts.net user=alice port=2222 fingerprint=SHA256:...
```

### 2. 控制节点（macOS 或 Linux）

```bash
curl -fsSL <raw-url>/install.sh | bash -s -- control --host <主机> --user <用户> --fingerprint SHA256:...
```

它会安装 Mutagen（macOS 用 Homebrew，否则用官方发布的二进制）、docker CLI（macOS + Homebrew）、
没有 SSH 密钥时新建一把、把 `cnode`/`rx`/`wsync` 装到 `~/.local/bin`、为每个节点生成带连接复用的
SSH 别名和 docker context，在 `~/.claude/CLAUDE.md`（若存在 `~/.codex` 则还有 `~/.codex/AGENTS.md`）写入 agent 规则块
（`--agent-rules 文件` 再加文件，`--no-agent-rules` 跳过），并登记该节点（默认名 `wsl`；用 `--name gpu1` 指定）。
`bash -s -- control --help` 查看全部参数。

如果节点还不认识本机的公钥，安装脚本会打印一行，**在节点上**执行：

```bash
cn-authorize 'ssh-ed25519 AAAA... you@laptop-compute-node'
```

（Windows 上：`wsl -d <发行版> -u <用户> -- cn-authorize '...'`。）`cnode key` 可再次打印这一行。

### 3. 验证

```bash
cd ~/某个项目
wsync                  # 把当前目录同步到默认节点
rx nproc               # 在节点的同名路径下执行
rx nvidia-smi          # 能看到 GPU
rx nodes               # 所有节点的状态
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
| `cnode add <名> --host H --user U [--port P] [--fingerprint FP]` | 登记另一个算力节点。 |
| `cnode list` / `cnode default [名]` / `cnode remove <名>` | 管理节点登记表。 |
| `cnode key` | 打印本机的 `cn-authorize` 授权行。 |
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
显存低于任务所需加余量时不要启动）；长任务在节点上用 tmux 起一个唯一名字的会话；从同步目录读结果。见
[templates/agent-rules.zh-CN.md](templates/agent-rules.zh-CN.md)。想在 Claude Code 里免确认调用 `rx`，可以允许
`Bash(rx:*)` 和 `Bash(wsync:*)`；这样 agent 不经确认就能在节点上执行任意命令，它在节点上写的文件也会同步回来。

## 安装脚本做了哪些更改

### Windows（`install.ps1`）

| 更改 | 原因 |
|---|---|
| `%USERPROFILE%\.wslconfig`，合并写入（保留其他键；有变化时备份为 `.wslconfig.bak-<时间>`） | `[wsl2] memory=<内存的 75%>GB` 限制 VM 内存；`networkingMode=mirrored` 让 WSL 共用 Windows 的网卡，访问 `<Windows 主机>:2222` 就到 WSL 里的 sshd；`vmIdleTimeout=-1` 闲置时不关 VM；`[experimental] autoMemoryReclaim=gradual` 逐步把闲置缓存还给 Windows。 |
| Hyper-V 防火墙规则 `WSL-SSH-2222` | mirrored 模式下，进入 WSL 的流量由 Hyper-V 防火墙过滤。 |
| `powercfg`：插电时不睡眠、不休眠 | 睡着的电脑当不了算力节点。 |
| 计划任务 `WSL Compute Node` | 开机时以你的账户运行 `wsl -d <发行版> --exec /bin/sleep infinity`，无需登录；发行版里的 systemd 拉起 sshd 和 Docker。 |
| WSL 本身、Debian 发行版、Linux 用户 | 仅在缺少时安装/创建。 |

### WSL 内 / Linux 上（`scripts/node-setup.sh`）

| 更改 | 位置 |
|---|---|
| sshd 端口 2222（不用 22，避免和 Windows 自带的 OpenSSH 冲突）、只允许密钥、禁止 root、为 agent 调大并发会话 | `/etc/ssh/sshd_config.d/10-compute-node.conf`。Ubuntu 的 `ssh.socket` 会改成 `ssh.service`，端口才生效。`--allow-lan-password` 恢复“私有网段和 Tailscale（`100.64.0.0/10`）来源可用密码”。 |
| Docker 官方 apt 仓库的 Docker Engine，用户加入 `docker` 组 | 已有其他来源的 `docker`（Docker Desktop 集成、`docker.io`）时跳过。 |
| NVIDIA Container Toolkit（`--gpus all`） | 仅在检测到 NVIDIA GPU 时安装。 |
| inotify 上限（Mutagen、构建工具） | `/etc/sysctl.d/90-compute-node.conf` |
| 让 SSH 会话找到 `nvidia-smi`（WSL 只给本地终端加 `/usr/lib/wsl/lib`） | `/usr/local/bin/nvidia-smi`、`/etc/profile.d/wsl-lib.sh`（仅 WSL） |
| 同步根目录 `/Users`，归节点用户所有 | 对应 macOS 路径。Linux 控制节点请加 `--sync-root /home/<你>`。 |
| `cn-status`、`cn-authorize` | `/usr/local/bin`，设置在 `/etc/compute-node.conf` |
| WSL 上的 systemd | `/etc/wsl.conf [boot] systemd=true`（以及 `[user] default=`）；以退出码 10 结束，提示重启发行版（install.ps1 会自动处理）。 |

没有 systemd 时（容器、部分精简系统）会直接启动 sshd，不启动 Docker。

### 控制节点（`scripts/control-setup.sh`、`bin/cnode`）

| 更改 | 说明 |
|---|---|
| `~/.ssh/config` 最顶部的标记块：`Include ~/.config/compute-node/ssh_config` | `Include` 必须在所有 `Host` 之前。旧版单节点安装写的块（`# BEGIN wsl-compute`）会被迁移并删除。 |
| `~/.config/compute-node/` | `nodes`、`default`、生成的 `ssh_config`（每个节点一个 `Host cn-<名字>`，`ControlMaster`/`ControlPersist 30m`，macOS 上用钥匙串）、`known_hosts`（固定的主机密钥）。 |
| `~/.local/bin/cnode`、`rx`、`wsync`（符号链接）、`~/.local/share/compute-node/cn-status` | 需要时在 shell 配置文件里加 PATH。 |
| `~/.ssh/id_ed25519` | 仅在缺少时新建；有密码短语时存入 macOS 钥匙串。 |
| Mutagen 守护进程、每个节点一个 docker context | 默认 `docker context use <第一个节点>`，`--keep-docker-context` 可跳过。 |
| `~/.claude/CLAUDE.md`（及 `~/.codex/AGENTS.md`）中的 agent 规则块 | 在标记之间，原位替换；`--no-agent-rules` 跳过。 |

## 安全模型

- 节点上的 sshd **只接受密钥**（除非 `--allow-lan-password`），禁止 root 登录。控制节点要在节点上执行
  `cn-authorize '<它的公钥>'` 才能登录。
- 主机密钥是**固定的**：`cnode add` 读取节点的主机密钥，只有与 join 行里的 `--fingerprint`（或你已在
  `~/.ssh/known_hosts` 里信任过的密钥）一致才接受。别名使用 `StrictHostKeyChecking yes` 和按别名记录的专用
  known_hosts，所以 IP 变化（局域网/Tailscale）没关系，密钥变化会被拒绝。`--accept-new`（或在终端里回答 `y`）
  是“首次使用即信任”：在自己可控的网络里方便，但第一次连接时如果被冒充也会接受。
- 能运行 `rx` 的人就能以节点用户身份执行任何命令，节点上写的文件也会同步回笔记本。请把节点当作你的另一个账户对待。

## 网络：推荐 Tailscale，或局域网

Tailscale 给每台机器一个固定名字（`<机器名>.<tailnet>.ts.net`），在哪都能连，同一局域网内通常直连。
Windows 节点：安装 Tailscale（或用 `-InstallTailscale`），登录，在托盘菜单里打开 **Run unattended**。笔记本：打开
**Launch at login**。管理后台里给两台机器都选 **Disable key expiry**（否则约 180 天后登录过期），保持 **MagicDNS** 开启。
`tailscale ping <主机>` 应显示 `via <局域网IP>`；`via DERP` 表示走中继（较慢，检查 UDP 41641）。不用 Tailscale 时填节点的
局域网 IP（mirrored 模式下就是 Windows 的 IP）。如果 Windows 的 Tailscale 地址连不到 WSL，可以改在发行版里装 Tailscale。

## 限制

- **WSL 内存**：VM 受 `.wslconfig` 的 `memory=` 限制（默认物理内存的 75%），并与 Windows 争用；节点同时被人日常使用时，
  重负载会让两边都卡。可在 `[wsl2]` 下加 `processors=<N>` 限制核数。
- **容器当算力节点**：Docker 或 RunPod 容器可以提供 `rx`/`wsync`（没有 systemd 也会直接启动 sshd），但跑不了 Docker
  Engine：非特权容器无法创建它需要的命名空间和 cgroup，也无法承载 rootless Docker 所需的用户命名空间。这种情况用 `--no-docker`。
- 每次 `rx` 约多 0.1–0.5 秒；正常任务可忽略，不适合成千上万次零碎调用。
- 大文件的瓶颈在网络：数据集直接在节点上下载，不要经同步传。节点尽量插网线。
- 路径必须一致：macOS 控制节点对应节点上的 `/Users/...`；Linux 控制节点需要把自己的家目录路径（如 `/home/alice`）
  加为节点的同步根目录。
- 不支持 Windows 10（没有 mirrored 网络）。算力节点只支持 Debian/Ubuntu 及其衍生版。
- 不调度、agent 之间不加锁：`rx nodes` 显示正在运行的任务，选哪个节点由你或 agent 决定。

## 故障排查

| 现象 | 原因 / 解决 |
|---|---|
| PowerShell 输出乱码并报 `You cannot call a method on a null-valued expression` | Windows PowerShell 5.1 把无 BOM 的 UTF-8 当本地代码页读。所以 `install.ps1` 只含 ASCII 字符，修改时请保持。 |
| 启动脚本时报 `Unexpected token` | 运行下载的副本要写完整路径：`powershell -ExecutionPolicy Bypass -File <完整路径>\install.ps1`。 |
| 通过 SSH 执行时 `nvidia-smi: command not found` | 重跑节点安装（会把 `nvidia-smi` 链接到 `/usr/local/bin`）。 |
| `rx` 或同步卡住、要求输入密码短语 | 密钥的密码短语不在 agent/钥匙串里：`ssh-add --apple-use-keychain ~/.ssh/id_ed25519`（macOS）。 |
| 连不上 2222 端口 | 在 Windows 上确认：`wsl -l -v` 显示 Running；`.wslconfig` 里是 `networkingMode=mirrored` 且之后执行过 `wsl --shutdown`；`Get-NetFirewallHyperVRule -Name WSL-SSH-2222` 存在；用局域网 IP 试试以排除 Tailscale。 |
| `Host key verification failed` | 节点的主机密钥变了（重装过？）或连到了别的机器。在节点上核对指纹（`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`），再用 `cnode add ... --fingerprint` 重新登记。 |
| `Permission denied (publickey)` | 以节点用户身份在节点上执行 `cnode key` 打印的那一行。 |
| `rx: ... does not exist on <节点>` | 这个目录没有同步到该节点：在项目根运行 `wsync -n <节点>`。 |
| `tailscale ping` 显示 `via DERP` | 走了中继：是否在同一局域网？路由器是否拦了 UDP 41641？ |
| `client version != tailscaled server version` | 只是警告，升级 Tailscale 命令行即可。 |
| 同步冲突 | 以控制节点为准；用 `wsync -l` 或 `mutagen sync monitor` 查看。 |
| 节点上 docker 报 `permission denied` | 加入组后要重新登录：`wsl --shutdown` 后重新启动（或注销再登录）。 |
| `wsl --shutdown` 或崩溃后节点不见了 | `Start-ScheduledTask "WSL Compute Node"`。改过 Windows 密码？用 `-SkipWslConfig -ResetTask` 重跑。 |

## 卸载

控制节点：
```bash
mutagen sync terminate --label-selector compute     # wsync 建立的全部会话
mutagen daemon unregister
docker context use default && docker context rm <节点> ...   # 每个节点一个，见 cnode list
rm -rf ~/.local/bin/{cnode,rx,wsync} ~/.local/share/compute-node ~/.config/compute-node
awk '/^# BEGIN compute-node$/{s=1;next} /^# END compute-node$/{s=0;next} !s' ~/.ssh/config > ~/.ssh/config.new && mv ~/.ssh/config.new ~/.ssh/config
```

Windows（管理员）：
```powershell
Unregister-ScheduledTask -TaskName 'WSL Compute Node' -Confirm:$false
Remove-NetFirewallHyperVRule -Name WSL-SSH-2222
# 想恢复旧的 .wslconfig，就把 %USERPROFILE%\.wslconfig.bak-<时间> 改回 .wslconfig
```

Linux / WSL：
```bash
sudo rm /etc/ssh/sshd_config.d/10-compute-node.conf /etc/sysctl.d/90-compute-node.conf /etc/compute-node.conf \
        /usr/local/bin/cn-status /usr/local/bin/cn-authorize /etc/profile.d/wsl-lib.sh /usr/local/bin/nvidia-smi
sudo systemctl restart ssh   # 或者停用：sudo systemctl disable --now ssh
sudo apt-get purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin nvidia-container-toolkit
# /Users 下是同步过来的项目副本，确认不再需要后再手动删除
```

## 测试

`tests/run.sh [lint|control|node|multinode|ps|all]` 运行所有不需要真实 Windows 安装的测试（详见英文 README 的 Tests 一节）。
Docker 测试使用当前 docker context，引擎可用内存低于 `MIN_AVAILABLE_MB`（6000）时自动跳过；不使用 GPU。

## 许可证

MIT，见 [LICENSE](LICENSE)。
