<!-- BEGIN compute-node -->
## 远程算力节点（rx / wsync）
- 编辑、git、grep、读文件 → 在本机做。重负载（编译、测试套件、训练/推理、需要 CUDA/GPU、大量依赖安装、Linux 专属工具）→ 用 `rx` 交给算力节点。
- 本机没有项目依赖（`.venv`、`node_modules` 等只在节点上），不要在本机直接跑 python/pytest 等，一律走 `rx`。
- 派发重负载前先运行 `rx nodes --json` 选节点：
  - `reachable` 必须为 true。
  - 按 `hardware` 里的硬件匹配任务：`cpu_model`、`cpus_effective`（已考虑 cgroup 配额）、`mem_total_mb`，以及每块 GPU 的 `name`、`mem_total_mb`、`cuda`、`compute_cap`。
  - 再看实时的 `load`：`mem_available_mb`、每块 GPU 的 `mem_free_mb` 和 `util_pct`、`loadavg`、磁盘 `free_mb`、正在运行的 `tmux` 会话。
- **不要假定节点空闲**：节点由多人/多个 agent 共用。保留内存余量：节点的 `mem_available_mb`（或 GPU 的 `mem_free_mb`）低于任务所需再加余量（约 10–20%，至少 2 GB）时，不要在上面启动任务，换节点或等待。除非数字允许，不要在同一节点同时跑多个吃内存的任务。
- `rx -n <节点> <命令>`：先推送本地改动，在该节点的同名绝对路径下执行（登录 shell），等节点产出同步回来再返回。不加 `-n` 时用默认节点（`cnode list`）。含 shell 语法时整条加单引号，让它在节点上展开：`rx -n <节点> 'make -j$(nproc)'`。
- 项目第一次用某个节点：在项目根运行 `wsync -n <节点>`；`wsync -l` 查看同步状态。依赖目录（node_modules、.venv、target 等）不同步，在节点上安装，例如 `rx -n <节点> uv sync`。
- 超过几分钟的任务不要前台阻塞：在节点上用 tmux 后台运行，会话名要唯一：`rx -n <节点> 'mkdir -p logs && tmux new -d -s <名> "<命令> 2>&1 | tee logs/<名>.log"'`，之后读本地 `logs/<名>.log`（会同步回来）或 `rx -n <节点> tmux ls`。不要杀不是自己启动的 tmux 会话。
- 节点写出的结果会出现在同步目录里，直接在本地读取。
- 节点上的 Docker：`docker --context <节点> ...`；构建用 `rx -n <节点> docker build .`；挂载用 `-v "$PWD:$PWD" -w "$PWD"`（两边路径一致）。
- 访问节点上的服务：`ssh -N -L 8000:localhost:8000 cn-<节点>`。
<!-- END compute-node -->
