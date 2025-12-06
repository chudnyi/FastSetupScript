#!/bin/bash
# Fast Setup Script · Debian 12/13 Edition · Ultimate UI
# 包含：中文菜单 + Loading动画 + Root防闪退修复 + 优化排版

set -euo pipefail
# ================== 0. 全局配置 ==================
# 1. 用户名
DEFAULT_USERNAME="${SET_USER:-admin}"

# 2. 密码哈希 (处理 $6 变量冲突)
# 逻辑：优先读 SET_HASH，若为空则使用默认值
DEFAULT_PASSWORD_HASH="${SET_HASH:-}"
if [ -z "$DEFAULT_PASSWORD_HASH" ]; then
    # 注意：默认值必须用单引号，防止 $6 被 Bash 解析
    DEFAULT_PASSWORD_HASH='YourHashedPassWD'
fi

# 3. SSH 公钥
DEFAULT_PUBLIC_KEY="${SET_KEY:-YourSSHPubKey}"

# 4. Cloudflare 配置 (允许注入)
CF_ZONE_ID="${SET_CF_ZONE_ID:-YourZoneID}"
CF_API_ENC="${SET_CF_ENC:-YourEncryptedAPIKey}"

# 5. Cloudflare 解密口令
CF_TOKEN_PASS="${SET_TOKEN_PASS:-}"

# 6. 主机名 (允许环境变量注入)
# 如果命令行没传 --hostname，则尝试读取环境变量 SET_HOSTNAME
HOSTNAME_ARG="${SET_HOSTNAME:-}"
# ================== 1. 参数解析与环境预检 ==================

FOR_REAL=0
WITHOUT_GUM=0
WITH_DNS=0
HOSTNAME_ARG=""
CF_API_TOKEN=""

# 参数解析
while [ $# -gt 0 ]; do
    case "$1" in
        --for-real)
            FOR_REAL=1
            WITHOUT_GUM=1
            ;;
        --without-gum)
            WITHOUT_GUM=1
            ;;
        --with-dns)
            WITH_DNS=1
            ;;
        --hostname)
            shift
            if [ $# -eq 0 ]; then echo "错误: --hostname 需要参数"; exit 1; fi
            HOSTNAME_ARG="$1"
            ;;
        *)
            echo "忽略未知参数: $1"
            ;;
    esac
    shift
done

# [关键修复] Root 环境自动补全依赖
prepare_env() {
    if [ "$EUID" -eq 0 ]; then
        if ! command -v sudo &>/dev/null || ! command -v curl &>/dev/null; then
            echo -e "\033[0;33m⚠ 检测到 Root 环境缺失依赖，正在自动修补 (sudo/curl)...\033[0m"
            apt-get update -y >/dev/null 2>&1
            apt-get install -y sudo curl openssl >/dev/null 2>&1
        fi
    else
        if ! command -v sudo &>/dev/null; then
            echo -e "\033[0;31m错误: 本脚本需要 Root 或 Sudo 权限。\033[0m"
            exit 1
        fi
    fi
}
prepare_env

# ================== 2. 视觉与工具函数 ==================

CURRENT_TIME=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')
HOSTNAME_NOW=$(hostname)
CURRENT_USER=$(whoami)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- 核心动画函数 (Loading -> SUCCESS) ---
show_loading() {
    local pid=$1         # 后台命令 PID
    local message=$2     # 提示信息
    local dots=('.  ' '.. ' '...')
    local i=0

    # 隐藏光标
    tput civis 2>/dev/null || true

    while kill -0 "$pid" 2>/dev/null; do
        # 蓝色文字显示 Loading 状态
        printf "\r${BLUE}%s${NC} %s" "$message" "${dots[i++ % ${#dots[@]}]}"
        sleep 0.3
    done

    wait "$pid"
    local exit_code=$?

    # 清除行并打印结果
    # %-50s 用于对齐
    if [ $exit_code -eq 0 ]; then
        printf "\r%-50s ${GREEN}SUCCESS${NC}\n" "$message"
    else
        printf "\r%-50s ${RED}FAILED${NC}\n" "$message"
        echo -e "${RED}Error:${NC} 命令执行失败 (Exit Code: $exit_code)"
        # 这里不强制退出，由调用者决定
    fi

    # 恢复光标
    tput cnorm 2>/dev/null || true
    return $exit_code
}

# 后台运行包装器
run_bg() {
    local cmd=$1
    local msg=$2
    if [ "$FOR_REAL" -eq 1 ]; then
        # 极速模式：不显示动画，直接显示结果
        bash -c "$cmd" &>/dev/null
        if [ $? -eq 0 ]; then
            printf "%-50s ${GREEN}SUCCESS${NC}\n" "$msg"
        else
            printf "%-50s ${RED}FAILED${NC}\n" "$msg"
        fi
    else
        bash -c "$cmd" &>/dev/null &
        show_loading $! "$msg"
    fi
}

# 静态日志 helper (带空格优化)
log_success() {
    echo -e " ${GREEN}✔ ${NC} $1"
}
log_info() {
    echo -e " ${BLUE}ℹ ${NC} $1"
}
log_warn() {
    echo -e " ${YELLOW}⚠ ${NC} $1"
}

# ================== 3. Gum 兼容层 ==================

export PATH="$HOME/.local/bin:$PATH"

has_gum() {
    [ "$WITHOUT_GUM" -eq 1 ] && return 1
    command -v gum &>/dev/null
}

install_gum_if_needed() {
    [ "$WITHOUT_GUM" -eq 1 ] && return 0
    if has_gum; then return 0; fi

    echo -e "正在检测环境..."

    # 尝试安装 (使用 run_bg 显示动画)
    run_bg "sudo apt update && sudo apt install -y curl gnupg" "正在安装基础依赖"

    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg --yes &>/dev/null || true
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ /" | sudo tee /etc/apt/sources.list.d/charm.list &>/dev/null

    run_bg "sudo apt update && sudo apt install -y gum" "正在安装 gum 交互组件"
}

# --- 交互封装 ---
confirm_gum() {
    local msg="$1"
    if has_gum; then gum confirm "$msg" && return 0 || return 1; else
        read -p " $msg (Y/n): " ans
        [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]
    fi
}

input_gum() {
    local header="$1"
    local placeholder="${2:-}"
    local default_val="${3:-}"
    if has_gum; then
        if [ -n "$default_val" ]; then
            gum input --header "$header" --placeholder "$placeholder" --value "$default_val"
        else
            gum input --header "$header" --placeholder "$placeholder"
        fi
    else
        read -p " $header [默认: $default_val]: " val
        echo "${val:-$default_val}"
    fi
}

password_gum() {
    local header="$1"
    if has_gum; then gum input --header "$header" --password; else
        read -s -p " $header: " val; echo; echo "$val"; fi
}

# ================== 4. 业务逻辑 (中文版) ==================

print_banner() {
    clear
    echo -e "${MAGENTA}"
    cat <<'EOF'
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃  🚀  Fast Setup Script · Debian 12/13 Edition        ┃
┃      "Plug in, breathe, you're root already."        ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
EOF
    echo -e "${NC}"

    local mode="交互模式"
    [ "$FOR_REAL" -eq 1 ] && mode="${RED}⚡ 极速模式 (无交互)${NC}"

    echo -e "  当前模式 : $mode"
    echo -e "  当前用户 : $CURRENT_USER"
    echo -e "  主机名   : $HOSTNAME_NOW"
    echo
}

perform_system_update() {
    echo -e "${CYAN}----- 系统检测阶段 -----${NC}"
    local cmd="sudo DEBIAN_FRONTEND=noninteractive apt update && sudo DEBIAN_FRONTEND=noninteractive apt -y upgrade"

    if [ "$FOR_REAL" -eq 1 ]; then
        run_bg "$cmd" "正在执行系统更新"
    elif confirm_gum "是否执行系统更新？"; then
        run_bg "$cmd" "正在执行系统更新"
    else
        log_warn "跳过系统更新"
    fi
}

setup_user() {
    echo -e "${CYAN}----- 用户创建与权限配置 -----${NC}"
    local target_user="$DEFAULT_USERNAME"

    if [ "$FOR_REAL" -ne 1 ]; then
        target_user=$(input_gum "请输入要创建的用户名" "" "$DEFAULT_USERNAME")
    fi

    # 创建用户
    if id "$target_user" &>/dev/null; then
        log_info "用户 $target_user 已存在，跳过创建"
    else
        sudo useradd -m -s /bin/bash "$target_user"
        log_success "用户 $target_user 已创建"
    fi

# 设置密码
    local pass_hash="$DEFAULT_PASSWORD_HASH"
    
    # [新增检查] 防止使用占位符作为密码
    if [[ "$pass_hash" == "YourHashedPassWD" ]] && [ "$FOR_REAL" -eq 1 ]; then
        echo -e "${RED}错误：极速模式下必须通过 SET_HASH 环境变量传入有效的密码哈希！${NC}"
        exit 1
    fi

    if [ "$FOR_REAL" -ne 1 ]; then
        local p
        p=$(password_gum "请输入用户密码 (留空使用默认哈希)")
        if [ -n "$p" ] && command -v openssl >/dev/null; then
            pass_hash=$(openssl passwd -6 "$p")
        fi
    fi
    
    # [新增检查] 二次确认，如果是交互模式且用户留空，不能使用无效占位符
    if [[ "$pass_hash" == "YourHashedPassWD" ]]; then
         echo -e "${RED}错误：未提供有效密码，且默认值为占位符，无法设置密码。${NC}"
         exit 1
    fi

    echo "$target_user:$pass_hash" | sudo chpasswd -e
    log_success "用户密码已设置"

    # Sudo 权限
    sudo usermod -aG sudo "$target_user" 2>/dev/null || sudo usermod -aG wheel "$target_user" 2>/dev/null
    echo "$target_user ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/$target_user" >/dev/null
    sudo chmod 440 "/etc/sudoers.d/$target_user"
    log_success "用户 $target_user 已配置免密 Sudo"

    TARGET_USERNAME="$target_user"
}

setup_ssh() {
    echo -e "${CYAN}----- SSH 安全加固 -----${NC}"
    local ssh_dir="/home/$TARGET_USERNAME/.ssh"
    local pub_key="$DEFAULT_PUBLIC_KEY"

    if [ "$FOR_REAL" -ne 1 ]; then
        local k
        k=$(input_gum "请输入公钥 (留空使用默认)" "ssh-..." "")
        [ -n "$k" ] && pub_key="$k"
    fi

    sudo mkdir -p "$ssh_dir"
    echo "$pub_key" | sudo tee -a "$ssh_dir/authorized_keys" >/dev/null
    sudo chmod 700 "$ssh_dir"
    sudo chmod 600 "$ssh_dir/authorized_keys"
    sudo chown -R "$TARGET_USERNAME:$TARGET_USERNAME" "$ssh_dir"

    log_success "SSH 公钥已安装"

    # 安全设置
    local disable_root="yes"
    local disable_pass="yes"

    if [ "$FOR_REAL" -ne 1 ]; then
        confirm_gum "是否禁用 Root SSH 登录？" || disable_root="no"
        confirm_gum "是否禁用密码登录 (仅密钥)？" || disable_pass="no"
    fi

    if [ "$disable_root" = "yes" ]; then
        sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
        log_success "Root SSH 登录已禁用"
    fi

    if [ "$disable_pass" = "yes" ]; then
        sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
        log_success "SSH 密码登录已禁用"
    fi

    # 重启 SSH
    if systemctl list-unit-files | grep -q "^ssh\.service"; then
        sudo systemctl restart ssh
    else
        sudo systemctl restart sshd 2>/dev/null || true
    fi
}

setup_hostname() {
    echo -e "${CYAN}----- 主机名配置 -----${NC}"
    local new_host=""

    if [ -n "$HOSTNAME_ARG" ]; then
        new_host="$HOSTNAME_ARG"
        log_info "使用参数传入的主机名: $new_host"
    elif [ "$FOR_REAL" -ne 1 ]; then
        new_host=$(input_gum "请输入新的主机名 (FQDN)" "node1.example.com" "")
    fi

    if [ -n "$new_host" ]; then
        sudo hostnamectl set-hostname "$new_host"
        if ! grep -q "127.0.0.1.*$new_host" /etc/hosts; then
            echo "127.0.0.1 $new_host" | sudo tee -a /etc/hosts >/dev/null
        fi
        log_success "主机名已修改为: $new_host"
    fi
}

setup_dns() {
    if [ "$WITH_DNS" -eq 0 ]; then return; fi
    echo -e "${CYAN}----- Cloudflare DNS 同步 -----${NC}"

    # 1. 解密 Token
    local pass=""
    if [ -n "${CF_TOKEN_PASS:-}" ]; then
        pass="$CF_TOKEN_PASS"
    elif [ "$FOR_REAL" -ne 1 ]; then
        pass=$(password_gum "请输入 Cloudflare Token 解密口令")
    else
        log_warn "无交互模式且未设置口令，跳过 DNS 同步"
        return
    fi

    CF_API_TOKEN=$(echo "$CF_API_ENC" | openssl enc -aes-256-cbc -a -d -pbkdf2 -pass pass:"$pass" 2>/dev/null || true)

    if [ -z "$CF_API_TOKEN" ]; then
        echo -e "${RED}解密失败，请检查口令。${NC}"
        return
    fi

    # 2. 获取 IP
    local ip
    ip=$(curl -4 -s https://ifconfig.io || curl -4 -s https://ipv4.icanhazip.com)
    local fqdn
    fqdn=$(hostname)

    log_info "正在同步: $fqdn -> $ip"

    # 3. 调用 API
    local resp
    resp=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$ip\",\"ttl\":120,\"proxied\":false}")

    if echo "$resp" | grep -q '"success":true'; then
        log_success "Cloudflare DNS 记录添加成功"
    else
        echo -e "${RED}Cloudflare API 调用失败:${NC}"
        echo "$resp" | grep "errors"
    fi
}

# ================== 5. 主流程 ==================

# 0. 环境准备
install_gum_if_needed

# 1. 显示 UI
print_banner

# 2. 执行步骤
perform_system_update
echo
setup_user
echo
setup_ssh
echo
setup_hostname
echo
setup_dns
# 3. 结束
echo -e "${MAGENTA}╔══════════════════════════════════════╗${NC}"

# 修改点：将 %-30s 改为 %-29s
# 这样刚好抵消掉中文和边框计算时的那个“1空格”误差
printf "${MAGENTA}║  用户: %-29s ║${NC}\n" "${TARGET_USERNAME}"
printf "${MAGENTA}║  主机: %-29s ║${NC}\n" "$(hostname)"

echo -e "${MAGENTA}╚══════════════════════════════════════╝${NC}"
log_success "所有步骤执行完毕，欢迎使用新系统。"

echo
echo -e "${GREEN}脚本执行完成，感谢您的使用！${NC}"
echo -e "${GREEN}本脚本在 https://github.com/Bryant-Xue/FastSetupScript 开源，欢迎您提交Issue/PR！${NC}"