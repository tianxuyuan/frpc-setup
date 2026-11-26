# frpc-setup

frp 内网穿透客户端一键部署（macOS / Linux），复用已有 frps 服务端。
自包含、幂等、可脱离 Claude Code 单独运行。核心是 `setup_frpc.sh` 单文件。

> 本仓库公开，只含通用工具与文档；部署环境参数（ECS 地址等）运行时经 `--host` 传入，不入库。

## 一键部署（任意新设备，一行命令，永久有效）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tianxuyuan/frpc-setup/main/setup_frpc.sh)
```

命令不含 IP——运行时交互输入**中继机地址**（本机有旧配置可回车保留）、**额外映射端口**（回车跳过仅 SSH），首次再输一次 ECS 密码（不回显、不进历史），之后全自动：端口自动分配（多设备避让）→ 安装 frpc → 开机自启 → 端到端验证 → 打印连接命令。**更换中继机后同一条命令照用**，输新 IP 即自动迁移（旧端口保留）。

预置参数跳过交互（自动化场景）：`bash setup_frpc.sh --host <IP> --forward 5900/tcp`

## 快速开始（已有本地脚本）

```bash
bash setup_frpc.sh --host <ECS公网IP> [--user root] [--forward <本机端口>[/tcp|/udp|/both]]...
# 例：映射本机 VNC(5900) → bash setup_frpc.sh --host <ECS_IP> --forward 5900/tcp
# 先预览（只读不改）：加 --dry-run
```

- 认证：优先 SSH 密钥；未授权时**交互提示输入 ECS 密码**（不回显、不进 shell 历史），自动推公钥后全程免密；自动化场景可用 `FRP_ECS_PASSWORD` 环境变量。推送工具 sshpass / expect / python3 任一即可
- 远程端口在 frps 的 allowPorts 内**自动分配并避让已占用端口**，多设备共用同一中继无需手动规划
- 开机自启：macOS LaunchAgent `com.frpc` / Linux systemd `frpc.service`
- 端到端验证自动完成；唯一可能的手动步骤是云安全组放行新端口（脚本会精确提示）

## 作为 Claude Code skill 使用

```bash
git clone https://github.com/tianxuyuan/frpc-setup.git ~/.claude/skills/frpc-setup   # 安装
git -C ~/.claude/skills/frpc-setup pull                                               # 更新
```

对话中说"搭建 frpc / 接入 frp 隧道 / 复用 frp 方案"即可触发，流程见 SKILL.md。

## 多设备共用一台中继

- 每台设备唯一标签（主机名+随机后缀，持久化在 `~/frp/device_tag`），代理名不冲突
- 端口分配读取 frps allowPorts + ECS 实时监听 + 本机已保留端口 + **ECS 端登记簿**（`/etc/frp/allocations.tsv`），自动避让；离线设备的端口也受保护，不会被新设备抢占
- 登记簿在部署成功后自动创建/更新（flock 原子合并，保留其他设备记录、重写本机记录）
- 残余边界：两台设备同时跑脚本可能撞号（失败方重跑即可）；永久退役设备需手动清理登记簿

## 中继机更换（ECS 迁移）

中继无状态，旧机器释放不丢数据。新购 ECS 后放行安全组（22、7000、远程端口段），每台设备重跑一行命令换 `--host <新IP>` 即可：脚本自动在新 ECS 安装 frps、备份本地旧配置、**旧端口原样保留**（被占/越界才改）、重建隧道。客户端连接地址只变 IP、端口不变。详见 SKILL.md。

## 安全设计

- frps token 运行时从服务端拉取，仅写入 600 权限的 `~/frp/frpc.toml`，不回显、不进日志
- 密码只经环境变量或终端交互输入（不回显、不进历史）；配置文件 600 权限
- 对已有 frps 服务端只读复用，不修改服务端配置
- 公网暴露的服务（如 VNC）务必设置强密码；VNC 明文协议，高安全场景建议改走 SSH 本地转发