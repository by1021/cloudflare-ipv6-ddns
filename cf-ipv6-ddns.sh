#!/usr/bin/env bash
# ==============================================================================
# Cloudflare IPv6 DDNS 自动化部署与管理脚本
# 架构：100% 纯原生 Shell 脚本实现，零 Python 依赖，零第三方库
# 支持：原生 Systemd 守护进程 (内存开销 <2MB) 与 Docker 容器部署
# 特性：兼容 API Token 与 Global API Key、内核智能选路自适应网卡、IPv6 变动秒级推送
# ==============================================================================

set -e

CONFIG_DIR="/etc/cf-ddns"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CACHE_FILE="${CONFIG_DIR}/last_ipv6.txt"
SCRIPT_FILE="/usr/local/bin/cf-ddns-sync.sh"
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
    if command -v ip &>/dev/null; then
        local route_out
        route_out=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null || true)
        ip=$(echo "$route_out" | grep -oE "src[[:space:]]+[0-9a-fA-F:]+" | awk '{print $2}' | head -n 1)
        if [[ -n "$ip" && "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
            case "$ip" in
                fe80:*|fc*|fd*|::1|::) ip="" ;;
            esac
        else
            ip=""
        fi
    fi

    # 策略 2: 备用公网回显 API (通用容灾)
    if [[ -z "$ip" ]]; then
        local urls=("https://6.ipw.cn" "https://api64.ipify.org" "https://v6.ident.me")
        for u in "${urls[@]}"; do
            local cand=""
            if command -v curl &>/dev/null; then
                cand=$(curl -6 -s --connect-timeout 3 -m 5 "$u" 2>/dev/null | tr -d "[:space:]" || true)
            elif command -v wget &>/dev/null; then
                cand=$(wget -6 -qO- --timeout=4 "$u" 2>/dev/null | tr -d "[:space:]" || true)
            fi
            if [[ -n "$cand" && "$cand" == *:* ]]; then
                case "$cand" in
                    fe80:*|fc*|fd*|::1|::) ;;
                    *) ip="$cand"; break ;;
                esac
            fi
        done
    fi

    echo "$ip"
}

install_systemd_core() {
    local token="$1"
    local domain="$2"
    local interval="$3"
    local email="$4"

    log_info "正在配置宿主机环境 (纯原生 Shell + Systemd)..."

    # 检查基础工具依赖
    if ! command -v curl &>/dev/null; then
        log_warn "系统未检测到 curl，尝试自动安装..."
        if command -v apt-get &>/dev/null; then
            apt-get update && apt-get install -y curl
        elif command -v yum &>/dev/null; then
            yum install -y curl
        elif command -v apk &>/dev/null; then
            apk add curl
        elif ! command -v wget &>/dev/null; then
            log_err "未检测到 curl 或 wget，请先安装: apt update && apt install -y curl"
            exit 1
        fi
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

    # 生成纯 Shell 核心守护程序（零 Python 依赖，纯系统基础工具）
    cat << 'SFILE' > "$SCRIPT_FILE"
#!/usr/bin/env bash
# ==============================================================================
# Cloudflare IPv6 DDNS 同步守护进程 (纯原生 Shell 实现，零 Python 依赖)
# ==============================================================================

set -u

CONFIG_PATH="/etc/cf-ddns/config.json"
CACHE_PATH="/etc/cf-ddns/last_ipv6.txt"
CF_API_BASE="https://api.cloudflare.com/client/v4"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 提取 JSON 字段（纯 sed，零外部依赖）
parse_json_val() {
    local key="$1"
    local file="$2"
    sed -n -E 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$file" | head -n 1
}

parse_json_int() {
    local key="$1"
    local file="$2"
    sed -n -E 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$file" | head -n 1
}

# 获取公网最佳 IPv6
get_best_ipv6() {
    local ip=""
    # 策略 1: 内核智能路由表寻路 (微秒级响应，无需指定物理网卡)
    if command -v ip &>/dev/null; then
        local route_out
        route_out=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null || true)
        ip=$(echo "$route_out" | grep -oE 'src[[:space:]]+[0-9a-fA-F:]+' | awk '{print $2}' | head -n 1)
        if [[ -n "$ip" && "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
            case "$ip" in
                fe80:*|fc*|fd*|::1|::) ip="" ;;
            esac
        else
            ip=""
        fi
    fi

    # 策略 2: 备用公网回显 API
    if [[ -z "$ip" ]]; then
        local urls=("https://6.ipw.cn" "https://api64.ipify.org" "https://v6.ident.me")
        for u in "${urls[@]}"; do
            local cand=""
            if command -v curl &>/dev/null; then
                cand=$(curl -6 -s --connect-timeout 3 -m 5 "$u" 2>/dev/null | tr -d '[:space:]' || true)
            elif command -v wget &>/dev/null; then
                cand=$(wget -6 -qO- --timeout=4 "$u" 2>/dev/null | tr -d '[:space:]' || true)
            fi
            if [[ -n "$cand" && "$cand" == *:* ]]; then
                case "$cand" in
                    fe80:*|fc*|fd*|::1|::) ;;
                    *) ip="$cand"; break ;;
                esac
            fi
        done
    fi

    echo "$ip"
}

# 调用 Cloudflare API
cf_api_request() {
    local method="$1"
    local url="$2"
    local token="$3"
    local email="${4:-}"
    local body="${5:-}"

    local headers=(-H "Content-Type: application/json")
    if [[ -n "$email" ]]; then
        headers+=(-H "X-Auth-Key: ${token}" -H "X-Auth-Email: ${email}")
    else
        headers+=(-H "Authorization: Bearer ${token}")
    fi

    if [[ -n "$body" ]]; then
        curl -s -X "$method" "$url" "${headers[@]}" -d "$body" --connect-timeout 8 -m 12 2>/dev/null || true
    else
        curl -s -X "$method" "$url" "${headers[@]}" --connect-timeout 8 -m 12 2>/dev/null || true
    fi
}

# 递归匹配主域名 Zone ID
find_zone_id() {
    local domain="$1"
    local token="$2"
    local email="$3"

    local d="${domain#.}"
    d="${d%.}"

    while [[ "$d" == *.* ]]; do
        local url="${CF_API_BASE}/zones?name=${d}&status=active"
        local resp
        resp=$(cf_api_request "GET" "$url" "$token" "$email")

        if echo "$resp" | grep -q '"success":true'; then
            local zid
            zid=$(echo "$resp" | sed -n -E 's/.*"result"[[:space:]]*:[[:space:]]*\[[[:space:]]*\{[[:space:]]*"id"[[:space:]]*:[[:space:]]*"([a-f0-9]{32})".*/\1/p')
            if [[ -z "$zid" ]]; then
                zid=$(echo "$resp" | grep -oE '"id"[[:space:]]*:[[:space:]]*"[a-f0-9]{32}"' | grep -oE '[a-f0-9]{32}' | head -n 1)
            fi
            if [[ -n "$zid" ]]; then
                echo "$zid"
                return 0
            fi
        fi
        d="${d#*.}"
    done
    return 1
}

# 同步 Cloudflare DNS 解析
sync_cloudflare() {
    local token="$1"
    local email="$2"
    local domain="$3"
    local new_ip="$4"

    local zone_id
    zone_id=$(find_zone_id "$domain" "$token" "$email" || true)
    if [[ -z "$zone_id" ]]; then
        log "未找到域名 ${domain} 对应的有效 Cloudflare Zone，请核对权限或域名托管状态"
        return 1
    fi

    # 查询当前已有 AAAA 记录
    local query_url="${CF_API_BASE}/zones/${zone_id}/dns_records?type=AAAA&name=${domain}"
    local record_resp
    record_resp=$(cf_api_request "GET" "$query_url" "$token" "$email")

    local record_id=""
    local remote_ip=""
    if echo "$record_resp" | grep -q '"success":true'; then
        record_id=$(echo "$record_resp" | sed -n -E 's/.*"result"[[:space:]]*:[[:space:]]*\[[[:space:]]*\{[[:space:]]*"id"[[:space:]]*:[[:space:]]*"([a-f0-9]{32})".*/\1/p')
        remote_ip=$(echo "$record_resp" | grep -oE '"content"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"content"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' | head -n 1)
        if [[ "$remote_ip" == "$new_ip" ]]; then
            log "Cloudflare 解析记录已为最新 IP (${new_ip})，跳过同步"
            return 0
        fi
    fi

    local payload="{\"type\":\"AAAA\",\"name\":\"${domain}\",\"content\":\"${new_ip}\",\"ttl\":60,\"proxied\":false}"
    local update_resp
    if [[ -n "$record_id" ]]; then
        update_resp=$(cf_api_request "PUT" "${CF_API_BASE}/zones/${zone_id}/dns_records/${record_id}" "$token" "$email" "$payload")
    else
        update_resp=$(cf_api_request "POST" "${CF_API_BASE}/zones/${zone_id}/dns_records" "$token" "$email" "$payload")
    fi

    if echo "$update_resp" | grep -q '"success":true'; then
        log "[SUCCESS] 解析已成功更新: ${domain} -> ${new_ip}"
        return 0
    else
        local err_msg
        err_msg=$(echo "$update_resp" | grep -oE '"message"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n 1 || echo "$update_resp")
        log "[FAILED] 解析更新失败: ${err_msg}"
        return 1
    fi
}

run_sync_cycle() {
    if [[ ! -f "$CONFIG_PATH" ]]; then
        log "配置文件不存在: ${CONFIG_PATH}"
        return 1
    fi

    local token email domain interval
    token=$(parse_json_val "token" "$CONFIG_PATH")
    email=$(parse_json_val "email" "$CONFIG_PATH")
    domain=$(parse_json_val "domain" "$CONFIG_PATH")
    interval=$(parse_json_int "interval" "$CONFIG_PATH")
    interval=${interval:-60}

    if [[ -z "$token" || -z "$domain" ]]; then
        log "配置文件中的 token 或 domain 为空，请检查: ${CONFIG_PATH}"
        return 1
    fi

    local current_ip
    current_ip=$(get_best_ipv6)

    if [[ -n "$current_ip" ]]; then
        local last_ip=""
        if [[ -f "$CACHE_PATH" ]]; then
            last_ip=$(cat "$CACHE_PATH" 2>/dev/null | tr -d '[:space:]' || true)
        fi

        if [[ "$current_ip" != "$last_ip" ]]; then
            log "检测到 IPv6 地址变更: [${last_ip}] -> [${current_ip}]"
            if sync_cloudflare "$token" "$email" "$domain" "$current_ip"; then
                echo "$current_ip" > "$CACHE_PATH"
            fi
        fi
    else
        log "未能检测到有效的公网 IPv6 地址，将在下个周期重试"
    fi
}

main() {
    if [[ ! -f "$CONFIG_PATH" ]]; then
        log "配置文件不存在: ${CONFIG_PATH}"
        exit 1
    fi

    local token email domain interval
    token=$(parse_json_val "token" "$CONFIG_PATH")
    email=$(parse_json_val "email" "$CONFIG_PATH")
    domain=$(parse_json_val "domain" "$CONFIG_PATH")
    interval=$(parse_json_int "interval" "$CONFIG_PATH")
    interval=${interval:-60}

    local auth_desc="API Token (Bearer)"
    if [[ -n "$email" ]]; then
        auth_desc="Global API Key (账号: ${email})"
    fi

    log "CF-DDNS 守护进程启动 (原生 Shell 版): 域名=${domain}, 认证=${auth_desc}, 周期=${interval}s"

    if [[ "${1:-}" == "--once" ]]; then
        run_sync_cycle
        exit 0
    fi

    while true; do
        run_sync_cycle || true
        sleep "$interval"
    done
}

main "$@"
SFILE

    chmod +x "$SCRIPT_FILE"

    cat << SYSEOF > "$SERVICE_FILE"
[Unit]
Description=Cloudflare IPv6 Dynamic DNS Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash ${SCRIPT_FILE}
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
    read -rp "1. 请输入 Cloudflare API Token 或 Global Key: " input_token
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
    read -rp "2. 请输入完整解析域名 (如 debian.example.com): " input_domain
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
    echo "  [1] 宿主机原生部署 (Systemd 守护, 纯原生 Shell, 内存 <2MB) [默认推荐]"
    echo "  [2] Docker 容器部署 (基于轻量 Go 镜像, 独立容器隔离)"
    read -rp "请输入选项 [1 或 2, 默认 1]: " mode_choice
    mode_choice=${mode_choice:-1}

    # 固化管理命令到系统 PATH
    local self_path
    self_path="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    if [[ -f "$self_path" && "$self_path" != "/usr/local/bin/cf-ipv6-ddns" ]]; then
        cp -f "$self_path" /usr/local/bin/cf-ipv6-ddns 2>/dev/null || true
        chmod +x /usr/local/bin/cf-ipv6-ddns 2>/dev/null || true
    fi

    if [[ "$mode_choice" == "1" ]]; then
        install_systemd_core "$input_token" "$input_domain" "$input_interval" "$input_email"
        echo -e "\n${GREEN}[✔] 部署完成！${RESET}"
        echo "  - 查看服务状态: systemctl status cf-ddns"
        echo "  - 实时查看日志: journalctl -u cf-ddns -f"
        echo "  - 快捷管理命令: cf-ipv6-ddns (或在当前目录执行: ./cf-ipv6-ddns.sh)"
    else
        install_docker_core "$input_token" "$input_domain" "$input_interval" "$input_email"
        echo -e "\n${GREEN}[✔] 部署完成！${RESET}"
        echo "  - 查看容器状态: docker ps -f name=${DOCKER_CONTAINER}"
        echo "  - 实时查看日志: docker logs -f ${DOCKER_CONTAINER}"
        echo "  - 快捷管理命令: cf-ipv6-ddns (或在当前目录执行: ./cf-ipv6-ddns.sh)"
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

action_restart() {
    log_info "正在重启相关服务..."
    if systemctl is-enabled --quiet cf-ddns 2>/dev/null || systemctl is-active --quiet cf-ddns 2>/dev/null; then
        systemctl restart cf-ddns
        log_info "已重启 Systemd 服务"
    fi
    if command -v docker &>/dev/null && docker ps -a --format '{{.Names}}' | grep -Eq "^${DOCKER_CONTAINER}\$"; then
        docker restart "${DOCKER_CONTAINER}" >/dev/null 2>&1 || true
        log_info "已重启 Docker 容器"
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
        rm -f "$SERVICE_FILE" 2>/dev/null || true
        systemctl daemon-reload
    fi
    if [[ -f "$SCRIPT_FILE" ]]; then
        rm -f "$SCRIPT_FILE" 2>/dev/null || true
    fi
    rm -f "/usr/local/bin/cf-ddns.py" 2>/dev/null || true
    if [[ -d "$CONFIG_DIR" ]]; then
        rm -rf "$CONFIG_DIR" 2>/dev/null || true
    fi
    if command -v docker &>/dev/null && docker ps -a --format '{{.Names}}' | grep -Eq "^${DOCKER_CONTAINER}\$"; then
        docker rm -f "${DOCKER_CONTAINER}" >/dev/null 2>&1 || true
    fi
    if [[ -f "/usr/local/bin/cf-ipv6-ddns" ]]; then
        rm -f "/usr/local/bin/cf-ipv6-ddns" 2>/dev/null || true
    fi

    log_info "卸载已完成！"
}

check_root

case "${1:-}" in
    install)
        action_install
        ;;
    status)
        action_status
        ;;
    restart)
        action_restart
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
        echo " 3. 重启运行服务 (Restart)"
        echo " 4. 停止当前运行服务 (Stop)"
        echo " 5. 彻底卸载服务与配置 (Uninstall)"
        echo " 0. 退出"
        echo -e "${BLUE}--------------------------------------------------${RESET}"
        read -rp "请选择操作 [0-5]: " choice
        case "$choice" in
            1) action_install ;;
            2) action_status ;;
            3) action_restart ;;
            4) action_stop ;;
            5) action_uninstall ;;
            0) exit 0 ;;
            *) log_err "无效选项" ; exit 1 ;;
        esac
        ;;
esac
