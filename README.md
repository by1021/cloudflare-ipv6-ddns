# cloudflare-ipv6-ddns

> 专为 Linux 环境设计的极简、高性能 Cloudflare IPv6 动态域名解析 (DDNS) 自动化部署方案。

具备**零第三方依赖、全自动内核寻路（无需指定物理网卡）、极低资源占用（~6MB 内存）与秒级变动同步**特性，全面适配 Debian、Ubuntu、CentOS、Rocky Linux、Alpine 等所有主流发行版。

---

## 方案核心特性

1. **双认证体系兼容（API Token 与 Global API Key）**：
   - 优先推荐 Cloudflare 精细化 **40 位 API Token**（只需 DNS 权限，更安全）。
   - 完美兼容历史常用的 **37 位 Global API Key（全局密钥）**，脚本自动识别并引导输入绑定邮箱。
2. **内核智能寻路（无需手动指定物理网卡）**：
   - 告别传统脚本必须硬编码 `eth0`、`ens18` 等网卡名的痛点，物理机与虚拟机迁移零改动。
   - 直接通过 Linux 内核路由表（`ip -6 route get 2606:4700:4700::1111`）微秒级获取通往外部互联网的最佳公网 IPv6 地址，同时内置多节点公网 API 容灾回退。
3. **极致轻量低开销**：
   - **原生 Systemd 模式**：基于纯 Python3 标准库开发（零第三方 pip 依赖），常驻后台休眠时内存仅约 **6MB**，CPU 消耗 **0.0%**。
   - **Docker 容器模式**：基于精简 Go 镜像，内存占用约 **5MB**，开箱即用。
4. **域名与 Zone 智能匹配**：
   - 仅需填写目标完整解析域名（如 `ddns.example.com`），程序自动通过 API 向上递归匹配其所属顶级 Zone ID，省去手动检索 Zone ID 的繁琐步骤。
5. **变动即时响应与防刷机制**：
   - 本地基于缓存文件智能比对。IP 未变动时**不发起任何写请求**（杜绝触发 Cloudflare 速率限制）；一旦本地公网 IPv6 发生重分配，**在下一个检测周期内瞬间完成 DNS 更新**。

---

## Cloudflare 凭证准备（二选一）

### 推荐方式：创建 40 位 API 令牌 (API Token)
1. 登录 [Cloudflare 控制台](https://dash.cloudflare.com/)。
2. 点击右上角头像 -> **我的个人资料 (My Profile)** -> **API 令牌 (API Tokens)**。
3. 点击 **创建令牌 (Create Token)**，选择 **编辑区域 DNS (Edit zone DNS)** 模板，点击 **使用模板**。
4. 确认权限包含：
   - `区域 (Zone)` - `DNS` - `编辑 (Edit)`
   - `区域 (Zone)` - `区域 (Zone)` - `读取 (Read)`
5. 区域资源选择 `包括 (Include)` -> `所有区域 (All zones)`（或指定您的域名）。
6. 点击创建并复制生成的 **40 位字符令牌**（格式如 `V-8qK9_...`）。
> **说明**：使用 API Token 时**无需提供 Cloudflare 邮箱**。

---

### 兼容方式：使用 37 位全局密钥 (Global API Key)
若您使用的是账户默认的 Global API Key（37 位十六进制字符串，如 `f9a54530...`）：
- 按照 Cloudflare 官方鉴权规范，**Global API Key 必须配合注册账号邮箱**才能调用 API。
- 运行安装脚本输入该密钥时，脚本会自动检测并提示您输入**绑定的 Cloudflare 邮箱**。

---

## 快速开始：一键部署

### 方式一：一键在线极速安装（推荐，无需手动克隆）

在 Linux 终端执行以下任意一条命令，将自动从 GitHub 拉取脚本并启动交互向导：

**使用 curl（官方源）：**
```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/by1021/Cloudflare_ddns/main/install.sh)"
```

**使用 wget（官方源）：**
```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/by1021/Cloudflare_ddns/main/install.sh)"
```

**国内服务器加速通道（免翻墙）：**
```bash
sudo bash -c "$(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/by1021/Cloudflare_ddns/main/install.sh)"
```

> **说明**：安装脚本会自动将核心管理程序写入 `/usr/local/bin/cf-ipv6-ddns`，安装完成后可在系统任意位置直接输入 `sudo cf-ipv6-ddns` 唤出管理菜单。

---

### 方式二：手动克隆仓库部署

适合需要审计或二次定制源码的用户：

```bash
# 克隆仓库
git clone https://github.com/by1021/Cloudflare_ddns.git
cd Cloudflare_ddns

# 赋予执行权限并启动交互向导
chmod +x cf-ipv6-ddns.sh
sudo ./cf-ipv6-ddns.sh
```

### 交互配置向导步骤

| 步骤 | 说明 |
| :--- | :--- |
| **1. 凭证输入** | 输入 **API Token** 或 **Global API Key** |
| **2. 邮箱输入** | *（仅当输入 37 位 Global API Key 时触发）* 输入 Cloudflare 注册邮箱 |
| **3. 完整域名** | 输入需要动态解析的完整域名（如 `ddns.example.com`） |
| **4. 检测周期** | 检测本地 IPv6 的时间间隔（默认 `60` 秒，直接回车即可） |
| **5. 运行模式** | 输入 `1` 宿主机原生部署 (Systemd)；输入 `2` Docker 部署 |

---

## 配置文件手动管理

安装完成后，配置文件存储于 `/etc/cf-ddns/config.json`：

### 1. 使用 API Token 的配置示例
```json
{
  "token": "你的40位APIToken",
  "email": "",
  "domain": "ddns.example.com",
  "interval": 60
}
```

### 2. 使用 Global API Key 的配置示例
```json
{
  "token": "你的37位GlobalAPIKey",
  "email": "user@example.com",
  "domain": "ddns.example.com",
  "interval": 60
}
```

修改配置文件后，重启服务即可生效：
```bash
sudo systemctl restart cf-ddns
```

---

## 快捷管理与常用运维命令

### 全局快捷命令
安装完成后，可在任意路径直接使用 `cf-ipv6-ddns` 进行日常管理：

```bash
# 打开交互管理菜单（配置/状态/重启/停止/卸载）
sudo cf-ipv6-ddns

# 查看服务状态与最近日志
sudo cf-ipv6-ddns status

# 重启 DDNS 同步服务
sudo cf-ipv6-ddns restart

# 停止 DDNS 服务
sudo cf-ipv6-ddns stop

# 彻底卸载服务与配置文件
sudo cf-ipv6-ddns uninstall
```

### 原生排错命令
```bash
# 查看 Systemd 服务实时运行状态
sudo systemctl status cf-ddns

# 跟踪查看动态解析实时日志
sudo journalctl -u cf-ddns -f

# 通过公共 DNS 验证 AAAA 解析是否已生效
dig @[IP] AAAA ddns.example.com +short
```

---

## License

MIT License
