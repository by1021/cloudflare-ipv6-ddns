#!/usr/bin/env bash
# ==============================================================================
# Cloudflare IPv6 DDNS 一键在线安装脚本
# 从 GitHub 拉取最新核心脚本至当前执行目录与 /usr/local/bin/cf-ipv6-ddns 并启动配置向导
# ==============================================================================

set -e

REPO_RAW_URL="https://raw.githubusercontent.com/by1021/cloudflare-ipv6-ddns/main/cf-ipv6-ddns.sh"
MIRROR_RAW_URL="https://ghfast.top/https://raw.githubusercontent.com/by1021/cloudflare-ipv6-ddns/main/cf-ipv6-ddns.sh"
EXEC_DIR="$(pwd)"
LOCAL_SCRIPT="${EXEC_DIR}/cf-ipv6-ddns.sh"
GLOBAL_SCRIPT="/usr/local/bin/cf-ipv6-ddns"

GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

log_info() { echo -e "${GREEN}[INFO]${RESET} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
log_err()  { echo -e "${RED}[ERROR]${RESET} $1"; }

# 提权检测：若当前非 root 用户，尝试使用 sudo
SUDO=""
if [[ $EUID -ne 0 ]]; then
    if command -v sudo &>/dev/null; then
        SUDO="sudo"
    else
        log_err "当前为非 root 用户且未安装 sudo，请先切换为 root 用户或安装 sudo！"
        exit 1
    fi
fi

log_info "正在从 GitHub 获取最新 Cloudflare IPv6 DDNS 核心脚本..."

# 创建安全临时下载文件
TMP_FILE="$(mktemp /tmp/cf-ipv6-ddns.XXXXXX)"
trap 'rm -f "$TMP_FILE"' EXIT

DOWNLOAD_SUCCESS=0
if command -v curl &>/dev/null; then
    if curl -fsSL --connect-timeout 10 "$REPO_RAW_URL" -o "$TMP_FILE"; then
        DOWNLOAD_SUCCESS=1
    fi
elif command -v wget &>/dev/null; then
    if wget -qO "$TMP_FILE" --timeout=10 "$REPO_RAW_URL"; then
        DOWNLOAD_SUCCESS=1
    fi
else
    log_err "系统未检测到 curl 或 wget，请先安装: apt update && apt install -y curl"
    exit 1
fi

# 备用源（若直连 GitHub 失败则自动尝试国内镜像加速）
if [[ $DOWNLOAD_SUCCESS -ne 1 || ! -s "$TMP_FILE" ]]; then
    log_warn "从 GitHub 官方源下载超时或失败，正在尝试通过加速节点拉取..."
    if command -v curl &>/dev/null; then
        curl -fsSL --connect-timeout 10 "$MIRROR_RAW_URL" -o "$TMP_FILE" || true
    elif command -v wget &>/dev/null; then
        wget -qO "$TMP_FILE" --timeout=10 "$MIRROR_RAW_URL" || true
    fi
fi

if [[ ! -s "$TMP_FILE" ]]; then
    log_err "拉取脚本失败，请检查网络连接或 DNS 解析设置！"
    exit 1
fi

# 1. 保存核心脚本至当前执行目录（默认 root 路径下: /root/cf-ipv6-ddns.sh）
$SUDO cp -f "$TMP_FILE" "$LOCAL_SCRIPT"
$SUDO chmod 755 "$LOCAL_SCRIPT"
if [[ $EUID -ne 0 && -n "${SUDO_USER:-}" ]]; then
    $SUDO chown "${SUDO_USER}:" "$LOCAL_SCRIPT" 2>/dev/null || true
elif [[ $EUID -ne 0 ]]; then
    $SUDO chown "$(id -u):$(id -g)" "$LOCAL_SCRIPT" 2>/dev/null || true
fi
log_info "核心脚本已保存至执行目录: ${LOCAL_SCRIPT}"

# 2. 同步注入系统全局可执行路径，保证任意路径均可调用快捷命令 cf-ipv6-ddns
if [[ "$LOCAL_SCRIPT" != "$GLOBAL_SCRIPT" ]]; then
    $SUDO mkdir -p "$(dirname "$GLOBAL_SCRIPT")"
    $SUDO cp -f "$TMP_FILE" "$GLOBAL_SCRIPT"
    $SUDO chmod 755 "$GLOBAL_SCRIPT"
    log_info "全局快捷命令已就绪: ${GLOBAL_SCRIPT}"
fi

# 启动安装向导
# 若标准输入并非终端（例如通过管道 curl ... | bash 启动），从 /dev/tty 接管输入
if [ ! -t 0 ] && [ -e /dev/tty ]; then
    exec $SUDO "$LOCAL_SCRIPT" install "$@" < /dev/tty
else
    exec $SUDO "$LOCAL_SCRIPT" install "$@"
fi
