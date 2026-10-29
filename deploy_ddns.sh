#!/usr/bin/env bash
# ==============================================================================
# Cloudflare IPv6 DDNS 自动化部署与管理脚本
# 支持：原生 Systemd 守护进程 (低占用高兼容) 与 Docker 容器部署
# 特性：兼容 API Token 与 Global API Key、内核智能选路自适应网卡、IPv6 变动秒级推送
# ==============================================================================

set -e

CONFIG_DIR="/etc/cf-ddns"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CACHE_FILE="${CONFIG_DIR}/last_ipv6.txt"
SCRIPT_FILE="/usr/local/bin/cf-ddns.py"
SERVICE_FILE="/etc/systemd/system/cf-ddns.service"
DOCKER_CONTAINER="cf-ddns-ipv6"

GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

log_info() { echo -e "${GREEN}[INFO]${RESET} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
log_err()  { echo -e "${RED}[ERROR]${RESET} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "请使用 root 权限运行此脚本 (例如: sudo $0)"
        exit 1
    fi
}

detect_ipv6() {
    local ip=""
    # 策略 1: 查询前往 Cloudflare DNS 的源路由 IP (微秒级响应，无需指定物理网卡)
    ip=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | grep -oP 'src \K\S+' || true)
    # 策略 2: 备用公网回显 API
    if [[ -z "$ip" ]]; then
        ip=$(curl -6 -s --connect-timeout 3 https://6.ipw.cn 2>/dev/null || curl -6 -s --connect-timeout 3 https://api64.ipify.org 2>/dev/null || true)
    fi
    echo "$ip"
}

install_systemd_core() {
    local token="$1"
    local domain="$2"
    local interval="$3"
    local email="$4"

    log_info "正在配置宿主机环境 (Python3 + Systemd)..."
    if ! command -v python3 &>/dev/null; then
        log_err "未检测到 Python3，请先安装: apt update && apt install -y python3"
        exit 1
    fi

    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"

    cat << JSON > "$CONFIG_FILE"
{
  "token": "${token}",
  "email": "${email}",
  "domain": "${domain}",
  "interval": ${interval}
}
JSON
    chmod 600 "$CONFIG_FILE"

    # 生成 Python 核心守护程序（纯标准库，兼容 Token 与 Global Key）
    cat << 'PYEOF' > "$SCRIPT_FILE"
#!/usr/bin/env python3
import os
import sys
import time
import json
import re
import subprocess
import urllib.request
import urllib.error

CONFIG_PATH = "/etc/cf-ddns/config.json"
CACHE_PATH = "/etc/cf-ddns/last_ipv6.txt"
CF_API_BASE = "https://api.cloudflare.com/client/v4"

def log(msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)

def get_best_ipv6():
    try:
        res = subprocess.run(
            ["ip", "-6", "route", "get", "2606:4700:4700::1111"],
            capture_output=True, text=True, timeout=2
        )
        m = re.search(r"src\s+([0-9a-fA-F:]+)", res.stdout)
        if m:
            ip = m.group(1).strip()
            if not ip.startswith(("fe80:", "fc", "fd", "::1")):
                return ip
    except Exception:
        pass

    for url in ["https://6.ipw.cn", "https://api64.ipify.org", "https://v6.ident.me"]:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "curl/7.88"})
            with urllib.request.urlopen(req, timeout=4) as resp:
                ip = resp.read().decode().strip()
                if ":" in ip and not ip.startswith(("fe80:", "fc", "fd")):
                    return ip
        except Exception:
            continue
    return None

def cf_api(url, method, token, email="", data=None):
    headers = {"Content-Type": "application/json"}
    if email:
        headers["X-Auth-Key"] = token
        headers["X-Auth-Email"] = email
    else:
        headers["Authorization"] = f"Bearer {token}"

    payload = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=payload, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        err = e.read().decode()
        if "6111" in err:
            log(f"Cloudflare 认证失败: Authorization 格式错误。若您使用的是 37 位 Global API Key，必须配置注册邮箱。")
        elif "9103" in err:
            log(f"Cloudflare 认证失败: Global API Key 与邮箱不匹配，请核对。")
        elif "10000" in err:
            log(f"Cloudflare 认证失败: API Token 无效或已过期。")
        else:
            log(f"Cloudflare API 异常 ({e.code}): {err}")
        return None
    except Exception as e:
        log(f"网络异常: {e}")
        return None

def find_zone_id(domain, token, email=""):
    # 智能尝试从后缀提取根 Zone (例如 debian.996668.xyz -> 查找 996668.xyz)
    parts = domain.strip(".").split(".")
    for i in range(len(parts) - 1):
        candidate_zone = ".".join(parts[i:])
        url = f"{CF_API_BASE}/zones?name={candidate_zone}&status=active"
        res = cf_api(url, "GET", token, email)
        if res and res.get("result"):
            return res["result"][0]["id"], candidate_zone
    return None, None

def sync_cloudflare(token, email, domain, new_ip):
    zone_id, zone_name = find_zone_id(domain, token, email)
    if not zone_id:
        log(f"未找到域名 {domain} 对应的有效 Cloudflare Zone，请检查凭据权限或域名是否托管在当前账号下")
        return False

    records = cf_api(f"{CF_API_BASE}/zones/{zone_id}/dns_records?type=AAAA&name={domain}", "GET", token, email)
    record_id = None
    if records and records.get("result"):
        record_id = records["result"][0]["id"]
        remote_ip = records["result"][0]["content"]
        if remote_ip == new_ip:
            log(f"Cloudflare 解析记录已为最新 IP ({new_ip})，跳过同步")
            return True

    payload = {
        "type": "AAAA",
        "name": domain,
        "content": new_ip,
        "ttl": 60,
        "proxied": False
    }

    if record_id:
        res = cf_api(f"{CF_API_BASE}/zones/{zone_id}/dns_records/{record_id}", "PUT", token, email, payload)
    else:
        res = cf_api(f"{CF_API_BASE}/zones/{zone_id}/dns_records", "POST", token, email, payload)

    if res and res.get("success"):
        log(f"[SUCCESS] 解析已成功更新: {domain} -> {new_ip}")
        return True
    else:
        log("[FAILED] 解析更新失败")
        return False

def main():
    if not os.path.exists(CONFIG_PATH):
        log(f"配置文件不存在: {CONFIG_PATH}")
        sys.exit(1)

    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        cfg = json.load(f)

    token = cfg.get("token", "").strip()
    email = cfg.get("email", "").strip()
    domain = cfg.get("domain", "").strip()
    interval = int(cfg.get("interval", 60))

    auth_type = f"Global API Key (账号: {email})" if email else "API Token (Bearer)"
    log(f"CF-DDNS 启动监控: 域名={domain}, 认证={auth_type}, 间隔={interval}s")

    while True:
        try:
            current_ip = get_best_ipv6()
            if current_ip:
                last_ip = ""
                if os.path.exists(CACHE_PATH):
                    with open(CACHE_PATH, "r", encoding="utf-8") as f:
                        last_ip = f.read().strip()

                if current_ip != last_ip:
                    log(f"检测到 IPv6 地址变更: [{last_ip}] -> [{current_ip}]")
                    if sync_cloudflare(token, email, domain, current_ip):
                        with open(CACHE_PATH, "w", encoding="utf-8") as f:
                            f.write(current_ip)
            else:
                log("未能检测到有效的公网 IPv6，将在下个周期重试")
        except Exception as e:
            log(f"主调度异常: {e}")

        time.sleep(interval)

if __name__ == "__main__":
    main()
PYEOF

    chmod +x "$SCRIPT_FILE"

    cat << SYSEOF > "$SERVICE_FILE"
[Unit]
Description=Cloudflare IPv6 Dynamic DNS Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${SCRIPT_FILE}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SYSEOF

    systemctl daemon-reload
    systemctl enable --now cf-ddns.service
    log_info "原生 Systemd 服务已成功启动！"
}

install_docker_core() {
    local token="$1"
    local domain="$2"
    local interval="$3"
    local email="$4"

    log_info "正在配置 Docker 容器化环境..."
    if ! command -v docker &>/dev/null; then
        log_err "当前环境未安装 Docker，请先安装 Docker 或选择原生部署模式"
        exit 1
    fi

    if docker ps -a --format '{{.Names}}' | grep -Eq "^${DOCKER_CONTAINER}\$"; then
        docker stop "${DOCKER_CONTAINER}" >/dev/null 2>&1 || true
        docker rm "${DOCKER_CONTAINER}" >/dev/null 2>&1 || true
    fi

    local env_auth=()
    if [[ -n "$email" ]]; then
        env_auth+=("-e" "CF_ACCOUNT_KEY=${token}" "-e" "CF_ACCOUNT_EMAIL=${email}")
    else
        env_auth+=("-e" "CF_API_TOKEN=${token}")
    fi

    docker run -d \
      --name "${DOCKER_CONTAINER}" \
      --network host \
      --restart unless-stopped \
      "${env_auth[@]}" \
      -e DOMAINS="${domain}" \
      -e IP4_PROVIDER="none" \
      -e IP6_PROVIDER="cloudflare" \
      -e UPDATE_CRON="@every ${interval}s" \
      -e PROXIED="false" \
      favonia/cloudflare-ddns:latest

    log_info "Docker 容器 [${DOCKER_CONTAINER}] 已成功启动！"
}

action_install() {
    echo -e "\n${BLUE}==================================================${RESET}"
    echo -e "${GREEN}           Cloudflare IPv6 DDNS 安装向导          ${RESET}"
    echo -e "${BLUE}==================================================${RESET}"

    local current_ip
    current_ip=$(detect_ipv6)
    if [[ -n "$current_ip" ]]; then
        echo -e "${GREEN}[+] 自动检测到本机 IPv6: ${current_ip}${RESET}\n"
    else
        echo -e "${YELLOW}[!] 当前未检测到公网 IPv6，服务将在后续循环中自动重试。${RESET}\n"
    fi

    # 输入密钥
    read -rp "1. 请输入 Cloudflare API Token 或 Global API Key: " input_token
    input_token=$(echo "$input_token" | tr -d '[:space:]')
    while [[ -z "$input_token" ]]; do
        read -rp "密钥不能为空，请重新输入: " input_token
        input_token=$(echo "$input_token" | tr -d '[:space:]')
    done

    # 智能识别 Global API Key (37 位 Hex 字符)
    local input_email=""
    if [[ ${#input_token} -eq 37 && "$input_token" =~ ^[0-9a-fA-F]+$ ]]; then
        echo -e "${YELLOW}[提示] 检测到您输入的是 37 位 Global API Key（全局密钥）。${RESET}"
        read -rp "   -> 请输入对应的 Cloudflare 注册账号邮箱: " input_email
        input_email=$(echo "$input_email" | tr -d '[:space:]')
        while [[ -z "$input_email" ]]; do
            read -rp "   -> 邮箱不能为空，请重新输入: " input_email
            input_email=$(echo "$input_email" | tr -d '[:space:]')
        done
    fi

    # 输入域名
    read -rp "2. 请输入完整解析域名 (如 debian.996668.xyz): " input_domain
    input_domain=$(echo "$input_domain" | tr -d '[:space:]')
    while [[ -z "$input_domain" ]]; do
        read -rp "域名不能为空，请重新输入: " input_domain
        input_domain=$(echo "$input_domain" | tr -d '[:space:]')
    done

    # 输入检测周期
    read -rp "3. 请输入检测循环周期 (秒) [默认 60]: " input_interval
    input_interval=${input_interval:-60}

    # 选择部署模式
    echo -e "\n${YELLOW}请选择部署模式:${RESET}"
    echo "  [1] 宿主机原生部署 (Systemd 守护, 纯标准库, 内存约 6MB) [默认推荐]"
    echo "  [2] Docker 容器部署 (基于轻量 Go 镜像, 独立容器隔离)"
    read -rp "请输入选项 [1 或 2, 默认 1]: " mode_choice
    mode_choice=${mode_choice:-1}

    if [[ "$mode_choice" == "1" ]]; then
        install_systemd_core "$input_token" "$input_domain" "$input_interval" "$input_email"
        echo -e "\n${GREEN}[✔] 部署完成！${RESET}"
        echo "  - 查看服务状态: systemctl status cf-ddns"
        echo "  - 实时查看日志: journalctl -u cf-ddns -f"
    else
        install_docker_core "$input_token" "$input_domain" "$input_interval" "$input_email"
        echo -e "\n${GREEN}[✔] 部署完成！${RESET}"
        echo "  - 查看容器状态: docker ps -f name=${DOCKER_CONTAINER}"
        echo "  - 实时查看日志: docker logs -f ${DOCKER_CONTAINER}"
    fi
}

action_status() {
    echo -e "${BLUE}=== 宿主机 Systemd 服务状态 ===${RESET}"
    if systemctl is-active --quiet cf-ddns 2>/dev/null; then
        echo -e "${GREEN}● Systemd 服务运行中${RESET}"
        journalctl -u cf-ddns -n 15 --no-pager
    else
        echo -e "${YELLOW}○ Systemd 服务未运行或未安装${RESET}"
    fi

    echo -e "\n${BLUE}=== Docker 容器状态 ===${RESET}"
    if command -v docker &>/dev/null && docker ps --format '{{.Names}}' | grep -Eq "^${DOCKER_CONTAINER}\$"; then
        echo -e "${GREEN}● Docker 容器运行中${RESET}"
        docker logs --tail 15 "${DOCKER_CONTAINER}"
    else
        echo -e "${YELLOW}○ Docker 容器未运行或未创建${RESET}"
    fi
}

action_stop() {
    log_info "正在停止相关服务..."
    if systemctl is-active --quiet cf-ddns 2>/dev/null; then
        systemctl stop cf-ddns
        log_info "已停止 Systemd 服务"
    fi
    if command -v docker &>/dev/null && docker ps -a --format '{{.Names}}' | grep -Eq "^${DOCKER_CONTAINER}\$"; then
        docker stop "${DOCKER_CONTAINER}" >/dev/null 2>&1 || true
        log_info "已停止 Docker 容器"
    fi
}

action_uninstall() {
    log_warn "确认卸载 CF-DDNS 服务及所有相关配置文件吗？(y/N)"
    read -rp "" confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "已取消卸载"
        return
    fi

    action_stop

    if [[ -f "$SERVICE_FILE" ]]; then
        systemctl disable cf-ddns >/dev/null 2>&1 || true
        rm "$SERVICE_FILE" 2>/dev/null || true
        systemctl daemon-reload
    fi
    if [[ -f "$SCRIPT_FILE" ]]; then
        rm "$SCRIPT_FILE" 2>/dev/null || true
    fi
    if [[ -d "$CONFIG_DIR" ]]; then
        rm -r "$CONFIG_DIR" 2>/dev/null || true
    fi
    if command -v docker &>/dev/null && docker ps -a --format '{{.Names}}' | grep -Eq "^${DOCKER_CONTAINER}\$"; then
        docker rm "${DOCKER_CONTAINER}" >/dev/null 2>&1 || true
    fi

    log_info "卸载已完成！"
}

check_root

case "$1" in
    install)
        action_install
        ;;
    status)
        action_status
        ;;
    stop)
        action_stop
        ;;
    uninstall)
        action_uninstall
        ;;
    *)
        echo -e "${BLUE}==================================================${RESET}"
        echo -e "${GREEN}        Cloudflare IPv6 DDNS 综合管理程序        ${RESET}"
        echo -e "${BLUE}==================================================${RESET}"
        echo " 1. 一键安装 / 重新配置 (Install / Reconfigure)"
        echo " 2. 查看服务状态与最近日志 (Status & Logs)"
        echo " 3. 停止当前运行服务 (Stop)"
        echo " 4. 彻底卸载服务与配置 (Uninstall)"
        echo " 0. 退出"
        echo -e "${BLUE}--------------------------------------------------${RESET}"
        read -rp "请选择操作 [0-4]: " choice
        case "$choice" in
            1) action_install ;;
            2) action_status ;;
            3) action_stop ;;
            4) action_uninstall ;;
            0) exit 0 ;;
            *) log_err "无效选项" ; exit 1 ;;
        esac
        ;;
esac
