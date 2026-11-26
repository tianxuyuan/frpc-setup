#!/bin/bash
# ============================================================================
# setup_frpc.sh — frp 内网穿透客户端一键部署（可复用 / 幂等 / macOS + Linux）
#
# 用法:
#   bash setup_frpc.sh --host <ECS公网IP> [选项]
# 一键部署(新设备,含下载;首次交互输入 ECS 密码后全自动):
#   bash <(curl -fsSL https://raw.githubusercontent.com/tianxuyuan/frpc-setup/main/setup_frpc.sh) --host <ECS公网IP> --forward 5900/tcp
#
# 选项:
#   --host <ip|域名>      ECS 地址（必填）
#   --user <name>         ECS 登录用户（默认 root）
#   --ssh-port <n>        ECS SSH 端口（默认 22）
#   --key <path>          SSH 私钥（默认 ~/.ssh/id_ed25519，不存在则自动生成）
#   --name <tag>          设备标签（默认 主机名-随机4位，用于代理名防冲突）
#   --forward <port>[/tcp|/udp|/both]
#                         额外映射本机端口到公网（可重复；默认 both=TCP+UDP）
#                         远程端口自动分配：同号可用则同号，否则在 allowPorts 内选空闲
#   --server-port <n>     frps bindPort（默认自动从 ECS 的 frps.toml 读取）
#   --dry-run             只输出计划与脱敏配置，不做任何修改
#   -h | --help           帮助
#
# 认证: 优先 SSH 密钥。未授权时: 有 FRP_ECS_PASSWORD 环境变量则直接用;
#       否则交互提示输入密码(不回显、不进 shell 历史)。自动推公钥后全程密钥认证。
#       推送工具: sshpass / expect / python3 任一即可。
#       密码与 token 一律不落盘（除 600 权限的 frpc.toml）、不回显、不进日志。
#
# 幂等: 重复执行保留 frpc.toml 中已有映射（名称/端口不变），只新增 --forward。
#       删除映射请手动编辑 ~/frp/frpc.toml 后重跑本脚本。
# 多设备: 唯一设备标签 + 端口自动避让；ECS 端 /etc/frp/allocations.tsv 登记簿
#       使离线设备的端口也受保护（部署成功后自动创建/更新，不修改 frps.toml）。
#
# 唯一可能的手动步骤: 阿里云安全组放行新分配的远程端口（脚本会检测并提示）。
# ============================================================================
set -euo pipefail
umask 077

FRP_VER="0.72.0"
GH_BASE="https://github.com/fatedier/frp/releases/download/v${FRP_VER}"
MIRROR_BASE="https://ghproxy.net/https://github.com/fatedier/frp/releases/download/v${FRP_VER}"
FRP_DIR="$HOME/frp"
CACHE_DIR="$HOME/Downloads/frp-setup-cache-v${FRP_VER}"

HOST="" RUSER="root" SSH_PORT=22 KEY_FILE="$HOME/.ssh/id_ed25519"
SERVER_PORT="" DEVICE_NAME="" DRY_RUN=0
FORWARDS=()

info() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ---------- 参数解析 ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --host)        HOST="${2:?}"; shift 2;;
    --user)        RUSER="${2:?}"; shift 2;;
    --ssh-port)    SSH_PORT="${2:?}"; shift 2;;
    --key)         KEY_FILE="${2:?}"; shift 2;;
    --name)        DEVICE_NAME="${2:?}"; shift 2;;
    --server-port) SERVER_PORT="${2:?}"; shift 2;;
    --forward)     FORWARDS+=("${2:?}"); shift 2;;
    --dry-run)     DRY_RUN=1; shift;;
    -h|--help)     usage;;
    *) die "未知参数: $1（--help 查看用法）";;
  esac
done
[ -n "$HOST" ] || { usage; }

# ---------- 环境探测 ----------
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
  Darwin) PKG_OS=darwin;;
  Linux)  PKG_OS=linux;;
  *) die "不支持的系统: ${OS}（仅支持 macOS / Linux）";;
esac
case "$ARCH" in
  x86_64|amd64) PKG_ARCH=amd64;;
  arm64|aarch64) PKG_ARCH=arm64;;
  *) die "不支持的架构: $ARCH";;
esac
if command -v shasum >/dev/null 2>&1; then SHA_CMD="shasum -a 256"; else SHA_CMD="sha256sum"; fi
command -v curl >/dev/null 2>&1 || die "缺少 curl"
command -v ssh  >/dev/null 2>&1 || die "缺少 ssh 客户端"
command -v awk  >/dev/null 2>&1 || die "缺少 awk"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/frpc-setup.XXXXXX")"
cleanup() { # 只清理本脚本自建的临时文件，不触碰任何用户数据
  local f
  for f in "$WORK"/*; do [ -f "$f" ] && rm -f "$f"; done
  rmdir "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

TARGET="$RUSER@$HOST"
SSH_OPTS=(-i "$KEY_FILE" -o IdentitiesOnly=yes -p "$SSH_PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes)
rsh() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }

# ---------- [1/7] SSH 认证（密钥优先，必要时用密码推公钥） ----------
info "===== [1/7] SSH 认证: $TARGET ====="
if [ ! -f "$KEY_FILE" ]; then
  info "私钥不存在，自动生成: $KEY_FILE"
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -N "" -f "$KEY_FILE" -C "frpc-setup@$(hostname -s 2>/dev/null || echo device)" >/dev/null
fi
PUB_KEY="$(cat "$KEY_FILE.pub")"

push_key_with_password() {
  local push_cmd="umask 077; mkdir -p ~/.ssh; grep -qxF '$PUB_KEY' ~/.ssh/authorized_keys 2>/dev/null || echo '$PUB_KEY' >> ~/.ssh/authorized_keys"
  if command -v sshpass >/dev/null 2>&1; then
    SSHPASS="$FRP_ECS_PASSWORD" sshpass -e ssh -p "$SSH_PORT" \
      -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
      -o PreferredAuthentications=password -o PubkeyAuthentication=no \
      "$TARGET" "$push_cmd" >/dev/null 2>&1
  elif command -v expect >/dev/null 2>&1; then
    FRP_ECS_PASSWORD="$FRP_ECS_PASSWORD" PUSH_CMD="$push_cmd" ECS_TARGET="$TARGET" ECS_PORT="$SSH_PORT" \
    expect <<'EXPECT_EOF' >/dev/null 2>&1
set timeout 25
spawn ssh -p $env(ECS_PORT) -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no $env(ECS_TARGET) $env(PUSH_CMD)
expect {
  -re "(?i)password:" { send "$env(FRP_ECS_PASSWORD)\r"; exp_continue }
  timeout { exit 2 }
  eof
}
EXPECT_EOF
  elif command -v python3 >/dev/null 2>&1; then
    FRP_ECS_PASSWORD="$FRP_ECS_PASSWORD" python3 - "$TARGET" "$SSH_PORT" "$push_cmd" <<'PY' >/dev/null 2>&1
import os, pty, select, sys, time
target, port, cmd = sys.argv[1:4]
pw = os.environ["FRP_ECS_PASSWORD"].encode()
pid, fd = pty.fork()
if pid == 0:
    try:
        os.execvp("ssh", ["ssh", "-p", port, "-o", "StrictHostKeyChecking=accept-new",
            "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
            "-o", "NumberOfPasswordPrompts=1", target, cmd])
    except Exception:
        os._exit(127)
buf, sent, eof = b"", False, False
deadline = time.time() + 25
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 1)
    if not r:
        continue
    try:
        data = os.read(fd, 4096)
    except OSError:
        eof = True; break
    if not data:
        eof = True; break
    buf += data
    if not sent and b"assword:" in buf:
        os.write(fd, pw + b"\n"); sent = True
if not eof:
    os.kill(pid, 9)
_, status = os.waitpid(pid, 0)
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
PY
  else
    return 1
  fi
}

if rsh true 2>/dev/null; then
  info "密钥认证: OK"
else
  if [ -z "${FRP_ECS_PASSWORD:-}" ] && [ "$DRY_RUN" = 0 ]; then
    # 交互兜底：从终端读密码（不回显、不进 shell 历史），支持 curl 一键部署
    if [ -t 0 ]; then PW_SRC=/dev/stdin
    elif ( : < /dev/tty ) 2>/dev/null; then PW_SRC=/dev/tty
    else PW_SRC=""; fi
    if [ -n "$PW_SRC" ]; then
      info "密钥未授权，请输入 $TARGET 的 SSH 密码（不回显、不落盘，仅用于推送公钥）:"
      IFS= read -rs FRP_ECS_PASSWORD < "$PW_SRC" || true
      printf '\n'
    fi
  fi
  if [ -n "${FRP_ECS_PASSWORD:-}" ]; then
    info "使用密码推送公钥（密码不回显）..."
    push_key_with_password || true
    unset FRP_ECS_PASSWORD SSHPASS 2>/dev/null || true
    rsh true 2>/dev/null || die "公钥推送失败：请检查密码/端口，或手动执行 ssh-copy-id -i $KEY_FILE.pub -p $SSH_PORT $TARGET 后重跑"
    info "公钥推送成功，已切换为密钥认证"
  else
    die "无法免密登录 ${TARGET}。请先手动执行: ssh-copy-id -i $KEY_FILE.pub -p $SSH_PORT $TARGET  然后重跑本脚本；或设置环境变量 FRP_ECS_PASSWORD 后重跑（自动推公钥）。"
  fi
fi
unset FRP_ECS_PASSWORD SSHPASS 2>/dev/null || true

RSUDO=""
if [ "$RUSER" != "root" ]; then
  rsh "sudo -n true" 2>/dev/null || die "非 root 用户需要 NOPASSWD sudo 权限（安装/管理 frps 服务）"
  RSUDO="sudo -n"
fi

# ---------- [2/7] ECS 端 frps（已存在则复用；全新 ECS 自动安装） ----------
info ""
info "===== [2/7] 检查 ECS 端 frps ====="
FRPS_CONF=""
if rsh "test -f /etc/frp/frps.toml" 2>/dev/null; then
  FRPS_CONF="$(rsh "$RSUDO cat /etc/frp/frps.toml")"
  if ! rsh "test -x /usr/local/bin/frps" 2>/dev/null; then
    die "ECS 有 /etc/frp/frps.toml 但缺少 /usr/local/bin/frps，请先修复服务端"
  fi
  ACTIVE="$(rsh "systemctl is-active frps 2>/dev/null || true")"
  if [ "$ACTIVE" != "active" ]; then
    [ "$DRY_RUN" = 1 ] || { rsh "$RSUDO systemctl start frps" && info "frps 未运行，已启动"; }
  fi
  info "frps 已存在，复用现有配置（token 不回显）"
else
  info "ECS 未安装 frps，将自动安装 frp v${FRP_VER} + systemd 自启"
fi

# 下载并 SHA256 强校验（缓存目录可复用；校验失败拒绝安装）
fetch_verified() { # fetch_verified <file>
  local f="$1"
  mkdir -p "$CACHE_DIR"
  if [ ! -s "$CACHE_DIR/frp_sha256_checksums.txt" ]; then
    curl --http1.1 -fSL --connect-timeout 15 --retry 3 --retry-all-errors \
      -o "$CACHE_DIR/frp_sha256_checksums.txt" "$GH_BASE/frp_sha256_checksums.txt" 2>/dev/null \
    || curl --http1.1 -fSL --connect-timeout 15 --retry 3 --retry-all-errors \
      -o "$CACHE_DIR/frp_sha256_checksums.txt" "$MIRROR_BASE/frp_sha256_checksums.txt" 2>/dev/null \
    || die "下载 SHA256 校验清单失败（GitHub 与镜像均不可达）"
  fi
  if [ -s "$CACHE_DIR/$f" ] && grep -- "$f\$" "$CACHE_DIR/frp_sha256_checksums.txt" | (cd "$CACHE_DIR" && $SHA_CMD -c - >/dev/null 2>&1); then
    return 0
  fi
  rm -f "$CACHE_DIR/$f"
  curl --http1.1 -fSL --connect-timeout 15 --retry 3 --retry-all-errors \
    -o "$CACHE_DIR/$f" "$GH_BASE/$f" 2>/dev/null \
  || curl --http1.1 -fSL --connect-timeout 15 --retry 3 --retry-all-errors \
    -o "$CACHE_DIR/$f" "$MIRROR_BASE/$f" 2>/dev/null \
  || die "下载失败: $f"
  grep -- "$f\$" "$CACHE_DIR/frp_sha256_checksums.txt" | (cd "$CACHE_DIR" && $SHA_CMD -c -) \
    || die "SHA256 校验失败: ${f}（拒绝安装）"
}

if [ -z "$FRPS_CONF" ] && [ "$DRY_RUN" = 0 ]; then
  ECS_ARCH="$(rsh "uname -m")"
  case "$ECS_ARCH" in
    x86_64|amd64) E_PKG_ARCH=amd64;;
    arm64|aarch64) E_PKG_ARCH=arm64;;
    *) die "ECS 架构不支持: $ECS_ARCH";;
  esac
  E_PKG="frp_${FRP_VER}_linux_${E_PKG_ARCH}.tar.gz"
  info "下载并校验 $E_PKG ..."
  fetch_verified "$E_PKG"
  tar xzf "$CACHE_DIR/$E_PKG" -C "$CACHE_DIR"
  scp -i "$KEY_FILE" -o IdentitiesOnly=yes -P "$SSH_PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
    "$CACHE_DIR/frp_${FRP_VER}_linux_${E_PKG_ARCH}/frps" "$TARGET:/tmp/frps.upload.$$"
  rsh "$RSUDO sh -c 'mv /tmp/frps.upload.$$ /usr/local/bin/frps && chmod +x /usr/local/bin/frps'"
  # 注意: 外层已是单引号，内部脚本原样书写即可（远端 login shell 单引号内不展开，
  #       $TOKEN 等由远端 sh -c 内的非引号 heredoc 展开）
  rsh "$RSUDO sh -c '
    set -e
    mkdir -p /etc/frp
    if [ ! -f /etc/frp/frps.toml ]; then
      if command -v openssl >/dev/null 2>&1; then TOKEN=$(openssl rand -hex 24);
      else TOKEN=$(od -An -tx1 -N24 /dev/urandom | tr -d " \n"); fi
      umask 077
      cat > /etc/frp/frps.toml <<EOF
bindPort = 7000
auth.method = "token"
auth.token = "$TOKEN"
allowPorts = [
  { start = 20022, end = 20022 },
  { start = 5190, end = 5190 },
  { start = 20000, end = 20100 }
]
EOF
      chmod 600 /etc/frp/frps.toml
    fi
    cat > /etc/systemd/system/frps.service <<EOF
[Unit]
Description=frps service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.toml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now frps
  '"
  FRPS_CONF="$(rsh "$RSUDO cat /etc/frp/frps.toml")"
  info "frps 安装完成并已启动"
fi

# 从 frps 配置提取参数（token 只进变量/600权限文件，绝不回显）
if [ -n "$FRPS_CONF" ]; then
  TOKEN="$(printf '%s\n' "$FRPS_CONF" | sed -n 's/^auth\.token *= *"\(.*\)" *$/\1/p')"
  [ -n "$TOKEN" ] || die "无法从 frps.toml 提取 auth.token"
  BIND_PORT="$(printf '%s\n' "$FRPS_CONF" | sed -n 's/^bindPort *= *\([0-9][0-9]*\).*/\1/p')"
  SERVER_PORT="${SERVER_PORT:-${BIND_PORT:-7000}}"
  printf '%s\n' "$FRPS_CONF" | tr '\n' ' ' \
    | grep -oE 'start *= *[0-9]+ *, *end *= *[0-9]+' \
    | sed -E 's/start *= *([0-9]+) *, *end *= *([0-9]+)/\1 \2/' > "$WORK/ranges.txt" || true
else
  TOKEN="" SERVER_PORT="${SERVER_PORT:-7000}"
  printf '20022 20022\n5190 5190\n20000 20100\n' > "$WORK/ranges.txt"
fi
[ -s "$WORK/ranges.txt" ] || printf '1 65535\n' > "$WORK/ranges.txt"  # 未配置 allowPorts = 不限制
info "frps bindPort=$SERVER_PORT, allowPorts 范围: $(tr '\n' ';' < "$WORK/ranges.txt")"

# ECS 当前已占用端口（含其他设备 frpc 注册的映射）
rsh "ss -tlnH 2>/dev/null | awk '{print \$4}' | sed 's/.*://'" | sort -un > "$WORK/used_tcp.txt" || true
rsh "ss -ulnH 2>/dev/null | awk '{print \$4}' | sed 's/.*://'" | sort -un > "$WORK/used_udp.txt" || true

# 端口分配登记簿（多设备加固：离线设备的端口也受保护；首次部署成功后自动创建）
REGISTRY="/etc/frp/allocations.tsv"
rsh "cat $REGISTRY 2>/dev/null" > "$WORK/registry.tsv" || true
if [ -s "$WORK/registry.tsv" ]; then
  info "端口登记簿: $(wc -l < "$WORK/registry.tsv" | tr -d ' ') 条记录（含离线设备保留端口）"
else
  info "端口登记簿: 尚未创建（部署成功后自动创建）"
fi

# ---------- [3/7] 本机 SSH 服务 ----------
info ""
info "===== [3/7] 检查本机 SSH 服务 (127.0.0.1:22) ====="
local_ssh_up() { nc -z -w 2 127.0.0.1 22 >/dev/null 2>&1; }
if local_ssh_up; then
  info "本机 sshd: OK"
else
  warn "本机 22 端口未监听"
  if [ "$DRY_RUN" = 0 ]; then
    if [ "$OS" = Darwin ]; then
      sudo -n systemsetup -f -setremotelogin on >/dev/null 2>&1 \
        && info "已开启 macOS 远程登录" \
        || warn "无法自动开启（需要 sudo）。请手动: 系统设置 → 通用 → 共享 → 远程登录"
    else
      for u in ssh sshd; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^$u.service"; then
          sudo -n systemctl enable --now "$u" >/dev/null 2>&1 && break || true
        fi
      done
      local_ssh_up && info "已启动本机 sshd" || warn "请手动安装/启动 openssh-server（否则隧道可通但 SSH 连不上）"
    fi
  fi
fi

# ---------- [4/7] 端口分配 + 生成 frpc.toml ----------
info ""
info "===== [4/7] 分配远程端口并生成配置 ====="
mkdir -p "$FRP_DIR"
CONF="$FRP_DIR/frpc.toml"

# 设备标签（首次生成后持久化，保证代理名跨设备唯一且本机稳定）
if [ -z "$DEVICE_NAME" ]; then
  if [ -f "$FRP_DIR/device_tag" ]; then
    DEVICE_NAME="$(cat "$FRP_DIR/device_tag")"
  else
    HN="$(hostname -s 2>/dev/null || echo device)"
    HN="$(printf '%s' "$HN" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | cut -c1-20)"
    DEVICE_NAME="${HN:-device}-$(openssl rand -hex 2 2>/dev/null || printf '%04x' $((RANDOM % 65536)))"
    [ "$DRY_RUN" = 1 ] || printf '%s\n' "$DEVICE_NAME" > "$FRP_DIR/device_tag"
  fi
fi
info "设备标签: $DEVICE_NAME"

# 解析已有配置（仅当指向同一服务器时保留，实现幂等）
: > "$WORK/existing.tsv"
if [ -f "$CONF" ]; then
  OLD_ADDR="$(sed -n 's/^serverAddr *= *"\(.*\)" *$/\1/p' "$CONF")"
  if [ "$OLD_ADDR" = "$HOST" ]; then
    awk '
      function val(l){ sub(/^[^=]*= */,"",l); gsub(/"/,"",l); sub(/ *$/,"",l); return l }
      function flush(){ if(name!="") printf "%s\t%s\t%s\t%s\n",name,type,lp,rp }
      /^\[\[proxies\]\]/ { flush(); name="";type="";lp="";rp=""; next }
      /^name[ \t]*=/       { name=val($0) }
      /^type[ \t]*=/       { type=val($0) }
      /^localPort[ \t]*=/  { lp=val($0) }
      /^remotePort[ \t]*=/ { rp=val($0) }
      END { flush() }
    ' "$CONF" > "$WORK/existing.tsv"
    info "检测到已有配置（同一服务器），保留全部现有映射"
  else
    cp "$CONF" "$CONF.bak.$(date +%Y%m%d%H%M%S)"
    warn "已有配置指向其他服务器($OLD_ADDR)，已备份为 $CONF.bak.*，按新设备处理"
  fi
fi

# 已占用 = ECS 实际监听端口 ∪ 本机已有配置保留的远程端口 ∪ 登记簿全部端口（含离线设备）。
# 已有映射经 existing_rp 幂等复用、不走 pick_port，故本机保留端口必须留在占用集中，
# 否则新映射会分配到与现有映射相同的 remotePort（frps 拒绝端口重复的代理）。
awk -F'\t' '{print $4}' "$WORK/existing.tsv" | sort -un > "$WORK/ours.txt"
awk -F'\t' 'NF>=4{print $4}' "$WORK/registry.tsv" | sort -un > "$WORK/registry_ports.txt"
sort -un "$WORK/used_tcp.txt" "$WORK/used_udp.txt" "$WORK/ours.txt" "$WORK/registry_ports.txt" > "$WORK/taken_all.txt"
# 分配策略: 端口号被任一设备的 TCP 或 UDP 占用即不再分配给新映射，
#           避免跨协议/跨设备同号歧义；同一服务的 TCP+UDP 成对分配同号。

in_ranges() { awk -v p="$1" '$1<=p && p<=$2{f=1} END{exit !f}' "$WORK/ranges.txt"; }
port_taken() { grep -qxF "$1" "$WORK/taken_all.txt"; }
pick_port() { # pick_port <preferred> → 输出可用端口
  local pref="$1" p
  if [ -n "$pref" ] && in_ranges "$pref" && ! port_taken "$pref"; then
    printf '%s\n' "$pref"; return 0
  fi
  while read -r lo hi; do
    p="$lo"
    while [ "$p" -le "$hi" ]; do
      if ! port_taken "$p"; then printf '%s\n' "$p"; return 0; fi
      p=$((p+1))
    done
  done < "$WORK/ranges.txt"
  return 1
}
existing_rp() { # existing_rp <type> <localPort> → 已有映射的 remotePort（无则空）
  awk -F'\t' -v t="$1" -v l="$2" '$2==t && $3==l {print $4; exit}' "$WORK/existing.tsv"
}
existing_name() {
  awk -F'\t' -v t="$1" -v l="$2" '$2==t && $3==l {print $1; exit}' "$WORK/existing.tsv"
}

# 待生成代理列表: name|type|localPort|remotePort
: > "$WORK/proxies.txt"
add_proxy() { # add_proxy <type> <localPort> <preferredRP> <defaultName>
  local type="$1" lp="$2" pref="$3" dname="$4" rp name
  rp="$(existing_rp "$type" "$lp")"
  if [ -n "$rp" ]; then
    name="$(existing_name "$type" "$lp")"
  else
    rp="$(pick_port "$pref")" || die "allowPorts 范围内没有空闲端口可分配（${type}/${lp}）"
    name="$dname"
    printf '%s\n' "$rp" >> "$WORK/ours.txt"
    printf '%s\n' "$rp" >> "$WORK/taken_all.txt"
  fi
  printf '%s|%s|%s|%s\n' "$name" "$type" "$lp" "$rp" >> "$WORK/proxies.txt"
}

# SSH 映射（始终提供）
add_proxy tcp 22 20022 "ssh-$DEVICE_NAME"
# 额外映射
for f in ${FORWARDS[@]+"${FORWARDS[@]}"}; do
  lp="${f%%/*}"; proto="${f#*/}"
  [ "$proto" = "$f" ] && proto=both
  case "$lp" in (*[!0-9]*|'') die "--forward 端口非法: $f";; esac
  [ "$lp" -ge 1 ] && [ "$lp" -le 65535 ] || die "--forward 端口越界: $f"
  case "$proto" in
    tcp)  add_proxy tcp "$lp" "$lp" "p$lp-tcp-$DEVICE_NAME";;
    udp)  add_proxy udp "$lp" "$lp" "p$lp-udp-$DEVICE_NAME";;
    both)
      if [ -n "$(existing_rp tcp "$lp")" ] || [ -n "$(existing_rp udp "$lp")" ]; then
        # 已有任一协议映射: 各自按幂等规则复用
        add_proxy tcp "$lp" "$lp" "p$lp-tcp-$DEVICE_NAME"
        add_proxy udp "$lp" "$lp" "p$lp-udp-$DEVICE_NAME"
      else
        # 全新映射: TCP+UDP 成对分配同一端口号
        rp="$(pick_port "$lp")" || die "allowPorts 范围内没有空闲端口可分配（both/${lp}）"
        printf '%s\n' "$rp" >> "$WORK/taken_all.txt"
        printf 'p%s-tcp-%s|tcp|%s|%s\n' "$lp" "$DEVICE_NAME" "$lp" "$rp" >> "$WORK/proxies.txt"
        printf 'p%s-udp-%s|udp|%s|%s\n' "$lp" "$DEVICE_NAME" "$lp" "$rp" >> "$WORK/proxies.txt"
      fi;;
    *) die "--forward 协议非法: ${f}（可选 /tcp /udp /both）";;
  esac
done
# 保留已有配置中本次未请求的映射（幂等，不丢映射）
while IFS=$'\t' read -r name type lp rp; do
  [ -n "$name" ] || continue
  grep -q "^$name|" "$WORK/proxies.txt" || printf '%s|%s|%s|%s\n' "$name" "$type" "$lp" "$rp" >> "$WORK/proxies.txt"
done < "$WORK/existing.tsv"

# 生成配置（token 脱敏显示）
{
  printf 'serverAddr = "%s"\n' "$HOST"
  printf 'serverPort = %s\n' "$SERVER_PORT"
  printf 'auth.token = "%s"\n' "$TOKEN"
  printf 'loginFailExit = false\n'
  while IFS='|' read -r name type lp rp; do
    printf '\n[[proxies]]\nname = "%s"\ntype = "%s"\nlocalIP = "127.0.0.1"\nlocalPort = %s\nremotePort = %s\n' \
      "$name" "$type" "$lp" "$rp"
  done < "$WORK/proxies.txt"
} > "$WORK/frpc.toml.new"

info "计划生成的 frpc.toml（token 已脱敏）:"
sed 's/^auth\.token = .*/auth.token = "***已脱敏***"/' "$WORK/frpc.toml.new"

if [ "$DRY_RUN" = 1 ]; then
  info ""
  info "[dry-run] 未做任何修改。去掉 --dry-run 重新执行即可部署。"
  exit 0
fi

[ -n "$TOKEN" ] || die "token 为空（frps 未就绪？）"
cp "$WORK/frpc.toml.new" "$CONF"
chmod 600 "$CONF"

# ---------- [5/7] 安装 frpc 二进制 ----------
info ""
info "===== [5/7] 安装 frpc v${FRP_VER} ($PKG_OS/$PKG_ARCH) ====="
mkdir -p "$FRP_DIR/bin"
if [ -x "$FRP_DIR/bin/frpc" ] && [ "$("$FRP_DIR/bin/frpc" -v 2>/dev/null || true)" = "$FRP_VER" ]; then
  info "frpc 已安装且版本一致，跳过下载"
else
  PKG="frp_${FRP_VER}_${PKG_OS}_${PKG_ARCH}.tar.gz"
  fetch_verified "$PKG"
  tar xzf "$CACHE_DIR/$PKG" -C "$CACHE_DIR"
  cp "$CACHE_DIR/frp_${FRP_VER}_${PKG_OS}_${PKG_ARCH}/frpc" "$FRP_DIR/bin/frpc"
  chmod +x "$FRP_DIR/bin/frpc"
  if [ "$OS" = Darwin ]; then
    xattr -dr com.apple.quarantine "$FRP_DIR/bin/frpc" 2>/dev/null || true
  fi
  info "frpc 版本: $("$FRP_DIR/bin/frpc" -v)"
fi

# ---------- [6/7] 注册自启服务并启动 ----------
info ""
info "===== [6/7] 注册开机自启服务 ====="
LOG="$FRP_DIR/frpc.log"
PRE_LINES="$(wc -l < "$LOG" 2>/dev/null | tr -d ' ' || echo 0)"
PRE_LINES="${PRE_LINES:-0}"

if [ "$OS" = Darwin ]; then
  PLIST="$HOME/Library/LaunchAgents/com.frpc.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.frpc</string>
  <key>ProgramArguments</key>
  <array>
    <string>$FRP_DIR/bin/frpc</string>
    <string>-c</string>
    <string>$CONF</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/com.frpc" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST"
  info "LaunchAgent com.frpc 已注册（RunAtLoad + KeepAlive）"
else
  UNIT="[Unit]
Description=frpc service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$FRP_DIR/bin/frpc -c $CONF
Restart=always
RestartSec=5s
StandardOutput=append:$LOG
StandardError=append:$LOG

[Install]
WantedBy=multi-user.target"
  if sudo -n true 2>/dev/null; then
    printf '%s\n' "$UNIT" | sudo -n tee /etc/systemd/system/frpc.service >/dev/null
    sudo -n systemctl daemon-reload
    sudo -n systemctl enable frpc >/dev/null 2>&1
    sudo -n systemctl restart frpc
    info "systemd 系统服务 frpc 已注册并启动"
  else
    mkdir -p "$HOME/.config/systemd/user"
    printf '%s\n' "$UNIT" | sed '/^WantedBy=/s/multi-user/default/' > "$HOME/.config/systemd/user/frpc.service"
    systemctl --user daemon-reload
    systemctl --user enable --now frpc >/dev/null 2>&1 || die "无法注册 systemd 服务（无 sudo 且 user service 不可用）"
    systemctl --user restart frpc
    loginctl enable-linger "$USER" >/dev/null 2>&1 || warn "enable-linger 失败：注销后 user service 可能停止，建议配置 sudo 后重跑"
    info "systemd 用户服务 frpc 已注册并启动"
  fi
fi

# ---------- [7/7] 验证 ----------
info ""
info "===== [7/7] 端到端验证 ====="
NPROXY="$(wc -l < "$WORK/proxies.txt" | tr -d ' ')"
ok=""
for i in $(seq 1 40); do
  sleep 1
  NEWLOG="$(tail -n +"$((PRE_LINES+1))" "$LOG" 2>/dev/null || true)"
  if printf '%s' "$NEWLOG" | grep -q "login to server success"; then
    if printf '%s' "$NEWLOG" | grep -qE "proxy already exists|port already used|port not allowed|token mismatch"; then
      printf '%s\n' "$NEWLOG" | grep -E "proxy already exists|port already used|port not allowed|token mismatch" >&2
      die "代理注册失败（端口/名称冲突或 token 不符），见上方日志"
    fi
    NSUC="$(printf '%s' "$NEWLOG" | grep -c "start proxy success" || true)"
    if [ "$NSUC" -ge "$NPROXY" ]; then ok=1; break; fi
  fi
done
[ -n "$ok" ] || { tail -15 "$LOG" >&2; die "40 秒内未看到全部代理注册成功，见上方日志"; }
info "frpc 登录成功，$NPROXY 条代理全部注册"

# ---------- 更新端口登记簿（多设备加固） ----------
# 保留其他设备记录、重写本机记录（自动清理已删映射）；在 ECS 上 flock 下合并，防并发覆盖。
# 仅在全部代理注册成功后写入，保证登记簿与实际一致；失败只警告，不影响已建成的隧道。
REG_TMP="/etc/frp/.allocations.upload.$$"
{ printf '%s\n' "$DEVICE_NAME"
  awk -F'|' -v d="$DEVICE_NAME" '{printf "%s\t%s\t%s\t%s\n", d, $2, $3, $4}' "$WORK/proxies.txt"
} > "$WORK/registry.upload"
if rsh "cat > $REG_TMP && chmod 600 $REG_TMP" < "$WORK/registry.upload" \
  && rsh "TMP='$REG_TMP' REG='$REGISTRY' bash -s" <<'REMOTE'
set -eu
DEV="$(head -n1 "$TMP")"
tail -n +2 "$TMP" > "$TMP.rows"
if command -v flock >/dev/null 2>&1; then exec 9>/etc/frp/.allocations.lock; flock 9; fi
awk -F'\t' -v d="$DEV" 'NF>=4 && $1!=d' "$REG" 2>/dev/null > "$TMP.merged" || true
cat "$TMP.rows" >> "$TMP.merged"
mv "$TMP.merged" "$REG"
chmod 600 "$REG"
rm -f "$TMP" "$TMP.rows"
REMOTE
then
  info "端口登记簿已更新: ${REGISTRY}（本机 $NPROXY 条；离线设备端口亦受保护）"
else
  warn "端口登记簿更新失败（不影响本次隧道；重跑脚本可重试）"
fi

# 公网可达性（python3 优先；macOS 自带 nc 在 EOF 后不等响应，读 banner 必须用 python3）
SG_WARN=""
while IFS='|' read -r name type lp rp; do
  if [ "$type" = tcp ]; then
    if command -v python3 >/dev/null 2>&1; then
      RES="$(python3 - "$HOST" "$rp" <<'PY'
import socket, sys
try:
    s = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=8)
    s.settimeout(4)
    try: data = s.recv(128)
    except socket.timeout: data = b""
    s.close()
    print("OK " + data.decode(errors="replace").strip())
except Exception as e:
    print("FAIL " + str(e))
PY
)" || RES="FAIL unknown"
    else
      nc -z -w 5 "$HOST" "$rp" >/dev/null 2>&1 && RES="OK (no banner check)" || RES="FAIL connect"
    fi
    case "$RES" in
      OK*) info "PASS | 公网 $HOST:$rp → 本机:$lp  [$name]  ${RES#OK }";;
      *)   warn "公网 $HOST:$rp 连不通，但 frps 已注册该代理 → 大概率是云安全组未放行 $rp/tcp"
           SG_WARN="$SG_WARN $rp/tcp";;
    esac
  else
    info "INFO | UDP 映射 $HOST:$rp → 本机:$lp/udp  [$name]（UDP 无法从客户端可靠探测，如不通请检查安全组 $rp/udp）"
  fi
done < "$WORK/proxies.txt"

SSH_RP="$(awk -F'|' '$2=="tcp" && $3==22 {print $4; exit}' "$WORK/proxies.txt")"
info ""
info "===================== 部署完成 ====================="
info "设备标签:   $DEVICE_NAME"
info "配置文件:   $CONF (600)"
info "日志:       $LOG"
if [ "$OS" = Darwin ]; then
  info "服务管理:   launchctl kickstart -k gui/$(id -u)/com.frpc   # 重启"
else
  info "服务管理:   systemctl restart frpc   # 重启（user 服务加 --user）"
fi
info "外网 SSH:   ssh -p $SSH_RP $(whoami)@$HOST"
if [ -n "$SG_WARN" ]; then
  warn "以下步骤需手动完成: 阿里云控制台 → ECS → 安全组 → 入方向放行:${SG_WARN}（及对应 UDP），然后重跑本脚本验证"
fi
info "新增映射:   重跑本脚本并追加 --forward <本机端口>[/tcp|/udp|/both]"
info "===================================================="