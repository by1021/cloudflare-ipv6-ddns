#!/usr/bin/env bash
# ==============================================================================
# Cloudflare IPv6 DDNS 一键在线安装脚本
# 从 GitHub 拉取最新核心脚本至 /usr/local/bin/cf-ipv6-ddns 并启动配置向导
# ==============================================================================

set -e

REPO_RAW_URL="https://raw.githubusercontent.com/by1021/cloudflare-ipv6-ddns/main/cf-ipv6-ddns.sh"
TARGET_FILE="/usr/local/bin/cf-ipv6-ddns"

GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

log_info() { echo -e "${GREEN}[INFO]${RESET} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
log_err()  { echo -e "${RED}[ERROR]${RESET} $1"; }

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    log_err "请使用 root 权限运行此脚本 (例如: sudo bash -c \"\$(curl -fsSL ...)\")"
    exit 1
fi

log_info "正在从 GitHub 获取最新的 Cloudflare IPv6 DDNS 核心脚本..."

# 下载核心管理脚本
DOWNLOAD_SUCCESS=0
if command -v curl &>/dev/null; then
    if curl -fsSL --connect-timeout 10 "$REPO_RAW_URL" -o "$TARGET_FILE"; then
        DOWNLOAD_SUCCESS=1
    fi
elif command -v wget &>/dev/null; then
    if wget -qO "$TARGET_FILE" --timeout=10 "$REPO_RAW_URL"; then
        DOWNLOAD_SUCCESS=1
    fi
else
    log_err "系统未检测到 curl 或 wget，请先安装: apt update && apt install -y curl"
    exit 1
fi

# 备用源（若直连 GitHub 失败则尝试镜像加速）
if [[ $DOWNLOAD_SUCCESS -ne 1 || ! -s "$TARGET_FILE" ]]; then
    log_warn "从 GitHub 官方源下载超时或失败，正在尝试通过加速节点拉取..."
    MIRROR_URL="https://ghfast.top/${REPO_RAW_URL}"
    if command -v curl &>/dev/null; then
        curl -fsSL --connect-timeout 10 "$MIRROR_URL" -o "$TARGET_FILE" || true
    elif command -v wget &>/dev/null; then
        wget -qO "$TARGET_FILE" --timeout=10 "$MIRROR_URL" || true
    fi
fi

if [[ ! -s "$TARGET_FILE" ]]; then
    log_err "拉取脚本失败，请检查网络连接或稍后重试！"
    exit 1
fi

chmod +x "$TARGET_FILE"
log_info "脚本已就绪: ${TARGET_FILE}"

# 启动安装向导
# 若标准输入并非终端（例如通过管道 curl ... | sudo bash 启动），从 /dev/tty 接管输入
if [ ! -t 0 ] && [ -e /dev/tty ]; then
    exec "$TARGET_FILE" install "$@" < /dev/tty
else
    exec "$TARGET_FILE" install "$@"
fi