---
name: frpc-setup
description: 在新设备上一键搭建 frp 内网穿透客户端（frpc）隧道，复用现有 ECS frps 服务端。当用户说"搭建frpc"、"接入frp隧道"、"新设备配置内网穿透"、"复用frp方案"、"把这台设备连到ECS隧道"时使用。只需 ECS 登录信息即可全自动：SSH认证→frps检查/安装→token拉取→端口自动分配→frpc安装→开机自启→端到端验证。支持 macOS 与 Linux。
---

# frpc 隧道一键搭建

本 skill 的核心是同目录下的 `setup_frpc.sh`（自包含、幂等、可脱离 Claude Code 单独运行）。
你的职责是：收集参数 → 执行脚本 → 解读结果 → 向用户汇报。**不要自己手写配置或重实现脚本逻辑。**

## 执行步骤

1. **收集信息**（缺什么问什么，已知则不问）：
   - ECS 公网地址（必需；必须向用户确认，不要默认。本机历史部署参数见 `ENVIRONMENT.local.md`，该文件不入库）
   - ECS 登录用户（默认 root）与 SSH 端口（默认 22）
   - 认证方式，按优先级：
     a. 本机已有可登录该 ECS 的 SSH 密钥 → 直接跑
     b. 交互输入（2026-11-26 起默认兜底）：密钥未授权时脚本在终端提示输入 ECS 密码（不回显、不进 shell 历史），推公钥后全程免密。注意 Claude Code 的 Bash 工具无 TTY，此路径需用户用 `!` 前缀自己跑
     c. 用户愿意手动授权 → 让用户在输入框执行 `! ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<host>`（密码由用户交互输入，不进对话记录）
     d. 自动化场景 → 用环境变量方式传入（见下），并提醒用户密码若已出现在会话中、建议事后修改
   - 需要额外映射的本机端口（可选，如某服务监听 5190 → `--forward 5190`；macOS 屏幕共享/VNC → `--forward 5900/tcp`；默认只映射 SSH）

2. **先 dry-run 预览**（只读，不修改任何东西）：
   ```bash
   bash <skill目录>/setup_frpc.sh --host <HOST> --user <USER> --dry-run [--forward <PORT>]...
   ```
   检查输出的端口分配计划是否合理：新映射的 remotePort 不得与已有映射或其他设备冲突（分配逻辑会自动避开；若发现冲突说明脚本有 bug，先修脚本再部署，不要手写配置绕过）。

3. **正式执行**：
   ```bash
   bash <skill目录>/setup_frpc.sh --host <HOST> --user <USER> [--forward <PORT>]...
   ```
   密码认证场景（仅此场景才用环境变量，避免密码进入命令行参数）：
   ```bash
   FRP_ECS_PASSWORD='<密码>' bash <skill目录>/setup_frpc.sh --host <HOST> ...
   ```
   脚本会自动推送公钥并立即改用密钥认证，密码不落盘、不回显。
   执行可能需要几分钟（下载 frp 包），Bash 超时建议设 300000ms 以上。

4. **解读结果并汇报**：
   - 成功标志：输出 `部署完成`，且每条 TCP 映射有 `PASS | 公网 ...` 行。
   - 若出现 `大概率是云安全组未放行 <port>` 警告：明确告诉用户去阿里云控制台 → ECS → 安全组 → 入方向放行对应端口（TCP/UDP），这是唯一无法自动化的步骤（需要云账号凭证）。放行后重跑脚本即可验证。
   - 若 SSH 认证失败：引导用户走步骤 1b 手动 ssh-copy-id。
   - 向用户复述最终映射表和外网 SSH 命令（脚本末尾已打印）。

## 安全红线（必须遵守）

- token 由脚本运行时从 ECS 拉取，**禁止**把 token 打印到对话、写入其他文件或提交到任何仓库。
- 密码只经 `FRP_ECS_PASSWORD` 环境变量传递；**禁止**写入脚本、配置文件、日志或命令行历史可见的位置。
- 配置文件权限必须是 600（脚本已保证，不要改动）。
- 不要修改 ECS 上已有的 `/etc/frp/frps.toml`（脚本对已有服务端只读复用）。

## 多设备说明

- 每台设备有唯一代理名（设备标签 = 主机名 + 随机后缀，持久化在 `~/frp/device_tag`）。
- 远程端口自动分配：占用集 = ECS 实际监听端口 ∪ 本机已有配置保留的远程端口，既避开其他设备，也避免撞本机已有映射。
  （2026-11-26 修复：旧逻辑把本机保留端口从占用集排除，新映射曾分到已被 SSH 占用的 20022，frps 会拒绝 remotePort 重复的代理。已有映射经幂等复用不走分配逻辑，故保留端口必须留在占用集中。）
  allowPorts 以 frps.toml 实际配置为准；脚本对全新服务端的默认方案为 20022(SSH)、5190、20000-20100，首台设备 SSH 优先 20022，后续设备自动落到空闲端口。
- 重复执行幂等：保留已有映射的名称与端口，只新增 `--forward` 请求的映射。
- 删除映射：手动编辑 `~/frp/frpc.toml` 后重跑脚本。
- **离线端口保护（2026-11-26 加固）**：ECS 端登记簿 `/etc/frp/allocations.tsv`（600 权限）记录各设备分配；占用集 = ECS 实时监听 ∪ 本机保留端口 ∪ 登记簿全部端口，离线设备端口不会被抢占。部署成功后在 flock 下原子更新：保留其他设备记录、重写本机记录（自动清理已删映射）。不修改 frps.toml。
- 残余边界：① 两台设备同时运行脚本仍可能撞号（frps 拒绝后注册失败，重跑即重新分配）；② 设备永久退役后其登记记录需手动清理（编辑 ECS 的 allocations.tsv）；③ 登记簿写入失败只警告，不影响已建成隧道。

## GitHub 分发（公开仓库，2026-11-26 建立）

仓库：`tianxuyuan/frpc-setup`（**公开**，只含通用工具与文档；ECS 地址/映射清单等部署环境参数剥离在各机 `ENVIRONMENT.local.md`，不入库——SPEC1）。

```bash
# 任意新设备一键部署（含下载；首次交互输入 ECS 密码后全自动）
bash <(curl -fsSL https://raw.githubusercontent.com/tianxuyuan/frpc-setup/main/setup_frpc.sh) --host <ECS公网IP> [--forward <端口>[/tcp|/udp|/both]]...
# 有 Claude Code 的设备：克隆为 skill
git clone https://github.com/tianxuyuan/frpc-setup.git ~/.claude/skills/frpc-setup
# 更新到最新版
git -C ~/.claude/skills/frpc-setup pull
```

本机 skill 目录即仓库工作区，修改后 `git add/commit/push` 即可同步给所有设备。**提交前必须扫描环境信息（ECS IP/出口 IP/映射清单/token），git 历史亦不得含敏感内容。**

## 无 Claude Code 的设备

直接把 `setup_frpc.sh` 单文件拷到目标设备执行即可（scp / U盘均可），用法见 `--help`：
```bash
scp ~/.claude/skills/frpc-setup/setup_frpc.sh <device>:~/
ssh <device> 'bash ~/setup_frpc.sh --host <ECS_IP>'
```

## 中继机更换（ECS 迁移，2026-11-26 起支持）

中继无状态：token 重新生成、登记簿随设备重新部署自动重建，旧 ECS 释放不丢数据。

1. 新购 ECS（Linux + systemd，可 root 密码登录），记下新公网 IP。
2. 新 ECS 安全组放行：22、7000（frps bindPort）及远程端口段（默认方案 20022、5190、20000-20100）——唯一手动步骤。
3. 每台设备重跑一行命令（`--host <新IP>`，--forward 参数随意，旧映射会自动全部迁移）：
   脚本自动：新 ECS 无 frps 则全新安装 → 本地旧配置备份为 frpc.toml.bak.* → **迁移模式旧端口原样保留**（新服务器上被占/越界才改，TCP+UDP 成对同号保持）→ 重建隧道 → 更新登记簿。
4. 客户端连接地址**只变 IP、端口不变**（以脚本输出为准）。
5. 建议在旧 ECS 释放前完成迁移（重叠期零停机）；释放后未迁移设备的 frpc 自动重试，无副作用。

本地无冲突保证：旧配置自动备份、服务重新注册、frpc 仅出站连接不占本地端口；dry-run 不产生备份文件。

## 通用环境事实

- macOS 客户端服务名 `com.frpc`（LaunchAgent），Linux 为 `frpc.service`（systemd）。
- macOS 自带 nc 在 stdin EOF 后不等响应，验证 banner 必须用 python3（脚本已处理）。
- 客户端 `loginFailExit = false` + 服务 KeepAlive/Restart=always：服务端短暂失联会自动重连。
- macOS VNC/屏幕共享用 TCP 5900，由 launchd 按需监听（ps 里看不到常驻进程属正常）；同局域网设备直连内网 IP:5900 即可，无需走 frp。非 Apple VNC 客户端还需在 系统设置→共享→屏幕共享ⓘ 勾选"VNC 显示程序可以使用密码控制屏幕"并设强密码（公网暴露时尤其重要）。
- 本机部署环境参数（ECS 地址、allowPorts 实际值、映射清单、事件记录）见 `ENVIRONMENT.local.md`（已 gitignore，不入库）。

## 故障排查：新建连接被定向关闭（2026-11-26 真实案例泛化）

- 症状：ECS SSH 端口 TCP 可连但 `kex_exchange_identification: Connection closed by remote host`；frpc 新登录 `connect to server error: EOF`；隧道访客连接被空响应关闭；**但已建立的控制连接正常、到其他目的地的新连接也正常** → 源 IP 被 ECS 侧安全层定向封锁新建连接。
- 排查顺序：① 换源 IP 测试（手机蜂窝网连隧道端口）区分"源 IP 被封"与"ECS 故障"；② 本机出口若走共享代理/VPN（出口 IP 属云厂商段），可能被云安全中心防暴力破解连坐封禁——断开代理用宽带直连重试；③ 云控制台 Workbench/VNC 登录 ECS（走内部通道不受源 IP 封锁影响）查 sshd 状态、fail2ban、磁盘/内存、云安全中心拦截记录。
- frpc `loginFailExit=false` + KeepAlive：封锁解除后自动重连恢复，无需人工干预。
- 教训：ECS 暴露 root+密码登录会持续被公网爆破，既占满 sshd 未认证连接槽（MaxStartups 丢包），也易触发云安全中心封禁。建议强密码+fail2ban；若不需要一键部署，可收紧安全组 22 到可信 IP 并禁用密码登录。