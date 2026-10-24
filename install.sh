#!/bin/bash

# 限制脚本仅支持基于 Debian/Ubuntu 的系统
if ! command -v apt-get &> /dev/null; then
    echo -e "\033[31m此脚本仅支持 Debian/Ubuntu 系统，请在支持 apt-get 和 .deb 内核包的系统上运行！\033[0m"
    echo -e "\033[33mAlpine Linux 等非 Debian 系统暂不支持安装本项目内核包。\033[0m"
    exit 1
fi

# 在 root 环境且未安装 sudo 时提供兼容包装，避免命令直接失败
if ! command -v sudo &> /dev/null; then
    if [[ "$(id -u)" -eq 0 ]]; then
        sudo() { "$@"; }
    else
        echo -e "\033[31m缺少依赖：sudo。请先安装 sudo 后重试。\033[0m"
        exit 1
    fi
fi

# 检查并安装必要的依赖
REQUIRED_CMDS=("curl" "wget" "dpkg" "awk" "sed" "sysctl" "jq")
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "\033[33m缺少依赖：$cmd，正在安装...\033[0m"
        sudo apt-get update && sudo apt-get install -y $cmd > /dev/null 2>&1
    fi
done

# 检测系统架构
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" && "$ARCH" != "x86_64" ]]; then
    echo -e "\033[31m(￣□￣)哇！这个脚本只支持 ARM 和 x86_64 架构哦~ 您的系统架构是：$ARCH\033[0m"
    exit 1
fi

# 获取当前 BBR 状态
CURRENT_ALGO=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
CURRENT_QDISC=$(sysctl net.core.default_qdisc | awk '{print $3}')

# sysctl 配置文件路径
SYSCTL_CONF="/etc/sysctl.d/99-joeyblog.conf"
# 模块自动加载配置文件路径
MODULES_CONF="/etc/modules-load.d/joeyblog-qdisc.conf"
# IPv6 开关使用独立文件，恢复时不改用户自己的 sysctl 配置
IPV6_CONF="/etc/sysctl.d/99-joeyblog-ipv6.conf"
IPV6_PROC_DIR="/proc/sys/net/ipv6/conf"
IPV6_STATE_FILE="/var/lib/joeyblog/ipv6-before-disable"
BOOT_DIR="/boot"
BOOT_BACKUP_DIR="/var/backups/joeyblog-kernel"
DKMS_STATE_DIR="/var/lib/dkms"
DMI_VENDOR_FILE="/sys/class/dmi/id/sys_vendor"
# 安全加固配置（Dirty Frag 风险面收敛）
SECURITY_MODPROBE_CONF="/etc/modprobe.d/99-joeyblog-security.conf"
# 脚本远程入口和本地快捷命令
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/main/install.sh"
QUICK_COMMAND_PATH="/usr/local/bin/b"
# 可选：提升 GitHub API 限额（支持 GITHUB_TOKEN / GH_TOKEN）
GITHUB_API_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
SPEEDTEST_BIN="speedtest"
OOKLA_SPEEDTEST_VERSION="1.2.0"

gh_api_get() {
    local url="$1"
    if [[ -n "$GITHUB_API_TOKEN" ]]; then
        curl -fsSL \
            -H "Authorization: Bearer $GITHUB_API_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            "$url"
    else
        curl -fsSL "$url"
    fi
}

check_release_api_response() {
    local response="$1"
    local api_message=""
    api_message=$(echo "$response" | jq -r 'if type=="object" then .message // "" else "" end')

    if [[ -n "$api_message" ]]; then
        echo -e "\033[31mGitHub API 返回错误：$api_message\033[0m"
        if echo "$api_message" | grep -qi "rate limit exceeded"; then
            echo -e "\033[33m提示：可先执行 export GITHUB_TOKEN=你的令牌，再重新运行脚本。\033[0m"
        fi
        return 1
    fi

    if ! echo "$response" | jq -e 'type=="array"' > /dev/null 2>&1; then
        echo -e "\033[31mGitHub API 返回数据格式异常，无法继续。\033[0m"
        return 1
    fi
}

install_quick_command() {
    if [[ "${BBRV3_SKIP_QUICK_COMMAND:-0}" == "1" ]]; then
        return 0
    fi

    if sudo tee "$QUICK_COMMAND_PATH" > /dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
export BBRV3_SKIP_QUICK_COMMAND=1
exec bash <(curl -fsSL "$INSTALL_SCRIPT_URL")
EOF
    then
        sudo chmod 755 "$QUICK_COMMAND_PATH"
    else
        echo -e "\033[33m提示：快捷命令 b 安装失败，不影响当前脚本运行。\033[0m"
    fi
}

version_ge() {
    local current="$1"
    local required="$2"
    [[ "$(printf '%s\n' "$required" "$current" | sort -V | head -n 1)" == "$required" ]]
}

# 当前 SSH 走 IPv6 时绝不直接断开连接；本地控制台也须有 IPv4 出口。
assert_safe_ipv6_disable() {
    local ssh_client="${SSH_CONNECTION:-}"
    ssh_client="${ssh_client%% *}"
    if [[ -z "$ssh_client" ]]; then
        ssh_client="${SSH_CLIENT:-}"
        ssh_client="${ssh_client%% *}"
    fi
    if [[ "$ssh_client" == *:* ]]; then
        echo -e "\033[31m当前 SSH 连接使用 IPv6，禁用会立即断线。请改用 IPv4 SSH 或云控制台后重试。\033[0m"
        return 1
    fi
    if ! command -v ip >/dev/null 2>&1 \
        || ! ip -4 route show default 2>/dev/null | grep -q '^default'; then
        echo -e "\033[31m未检测到 IPv4 默认路由，已拒绝禁用 IPv6，避免机器失联。\033[0m"
        return 1
    fi
}

validate_ipv6_snapshot() {
    awk -F '\t' '
        NF != 2 || $1 !~ /^[a-zA-Z0-9_.:-]+$/ || $2 !~ /^[01]$/ || seen[$1]++ {bad=1}
        END {exit (bad || !seen["all"] || !seen["default"])}
    '
}

save_ipv6_snapshot() {
    local snapshot_file switch_file iface value
    if sudo test -f "$IPV6_STATE_FILE"; then
        sudo cat "$IPV6_STATE_FILE" | validate_ipv6_snapshot
        return $?
    fi
    snapshot_file=$(mktemp) || return 1
    for switch_file in "$IPV6_PROC_DIR"/*/disable_ipv6; do
        [[ -f "$switch_file" ]] || continue
        iface="${switch_file%/disable_ipv6}"
        iface="${iface##*/}"
        value=$(cat "$switch_file") || { rm -f "$snapshot_file"; return 1; }
        printf '%s\t%s\n' "$iface" "$value" >> "$snapshot_file"
    done
    if ! validate_ipv6_snapshot < "$snapshot_file" \
        || ! sudo install -d -m 700 "${IPV6_STATE_FILE%/*}" \
        || ! sudo install -m 600 "$snapshot_file" "$IPV6_STATE_FILE"; then
        rm -f "$snapshot_file"
        echo -e "\033[31m无法保存原有 IPv6 设置，未执行禁用。\033[0m"
        return 1
    fi
    rm -f "$snapshot_file"
}

disable_ipv6() {
    local answer=""
    assert_safe_ipv6_disable || return 1
    if ! sysctl -n net.ipv6.conf.all.disable_ipv6 >/dev/null 2>&1; then
        echo -e "\033[31m当前内核没有可用的 IPv6 开关。\033[0m"
        return 1
    fi
    echo -e "\033[33m禁用后所有 IPv6 连接、监听和隧道都会中断；重启后仍保持禁用。\033[0m"
    echo -n -e "\033[36m确认禁用 IPv6？输入 y 继续：\033[0m"
    read -r answer
    [[ "$answer" == "y" || "$answer" == "Y" ]] || return 0
    save_ipv6_snapshot || return 1

    printf '%s\n' '# 由 Actions-bbr-v3 管理；使用菜单恢复 IPv6' \
        'net.ipv6.conf.all.disable_ipv6 = 1' \
        'net.ipv6.conf.default.disable_ipv6 = 1' \
        | sudo tee "$IPV6_CONF" >/dev/null || return 1
    if ! sudo sysctl -p "$IPV6_CONF"; then
        echo -e "\033[31mIPv6 设置未全部应用，请检查上面的错误；配置文件位于 $IPV6_CONF。\033[0m"
        return 1
    fi
    echo -e "\033[1;32mIPv6 已禁用。需要恢复时选择菜单 14。\033[0m"
}

restore_ipv6() {
    local snapshot iface value switch_file default_value disabled=""
    if ! sudo test -f "$IPV6_STATE_FILE"; then
        if [[ -f "$IPV6_CONF" ]]; then
            echo -e "\033[31m缺少禁用前的 IPv6 状态快照，无法安全还原逐接口设置，请先人工检查。\033[0m"
            return 1
        fi
        echo -e "\033[33m没有本脚本写入的 IPv6 禁用配置。若系统自行禁用了 IPv6，请检查其他 sysctl 配置及 ipv6.disable=1 启动参数。\033[0m"
        return 0
    fi
    snapshot=$(sudo cat "$IPV6_STATE_FILE") || return 1
    if ! printf '%s\n' "$snapshot" | validate_ipv6_snapshot; then
        echo -e "\033[31mIPv6 状态快照无效，未改动当前设置。\033[0m"
        return 1
    fi
    sudo rm -f "$IPV6_CONF" || return 1
    # all 会同时覆盖现有接口，必须先恢复它，再恢复各接口的原值。
    for iface in all default; do
        value=$(printf '%s\n' "$snapshot" | awk -F '\t' -v name="$iface" '$1 == name {print $2}')
        printf '%s\n' "$value" | sudo tee "$IPV6_PROC_DIR/$iface/disable_ipv6" >/dev/null || return 1
    done
    default_value=$(printf '%s\n' "$snapshot" | awk -F '\t' '$1 == "default" {print $2}')
    for switch_file in "$IPV6_PROC_DIR"/*/disable_ipv6; do
        [[ -f "$switch_file" ]] || continue
        iface="${switch_file%/disable_ipv6}"
        iface="${iface##*/}"
        [[ "$iface" == all || "$iface" == default ]] && continue
        value=$(printf '%s\n' "$snapshot" | awk -F '\t' -v name="$iface" '$1 == name {print $2}')
        printf '%s\n' "${value:-$default_value}" | sudo tee "$switch_file" >/dev/null || return 1
    done
    # 在原有运行态上重载持久规则，不删除管理员的其他配置。
    sudo sysctl --system >/dev/null 2>&1 || true
    sudo rm -f "$IPV6_STATE_FILE" || return 1
    for switch_file in "$IPV6_PROC_DIR"/*/disable_ipv6; do
        [[ -f "$switch_file" ]] || continue
        if [[ "$(cat "$switch_file")" == 1 ]]; then
            iface="${switch_file%/disable_ipv6}"
            disabled="$disabled ${iface##*/}"
        fi
    done
    echo -e "\033[1;32m已撤回本脚本的 IPv6 禁用，恢复禁用前设置并重新加载系统规则。\033[0m"
    [[ -z "$disabled" ]] || echo -e "\033[33m以下开关仍禁用 IPv6（原有设置或其他持久规则）：$disabled\033[0m"
    echo -e "\033[33m地址和默认路由可能需要网络服务重新配置或重启后恢复。\033[0m"
}

debian_version_from_codename() {
    case "${1:-}" in
        bookworm) echo "12" ;;
        trixie) echo "13" ;;
        forky) echo "14" ;;
        sid|unstable) echo "999" ;;
        *) return 1 ;;
    esac
}

# 函数：限制旧系统安装 7.x 主线内核，避免启动失败或 kernel panic
assert_supported_kernel_install_system() {
    local os_id=""
    local os_version=""
    local os_codename=""
    local os_name=""
    local min_version=""
    local distro_name=""

    if [[ ! -r /etc/os-release ]]; then
        echo -e "\033[31m无法识别当前系统版本，已拒绝安装 7.x 主线内核。\033[0m"
        echo -e "\033[33m最低支持：Ubuntu 24.04+ / Debian 12+；推荐系统：Ubuntu 24.04+ / Debian 12。\033[0m"
        return 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
    os_version="${VERSION_ID:-}"
    os_codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    os_name="${PRETTY_NAME:-${NAME:-未知系统}}"

    case "$os_id" in
        ubuntu)
            min_version="24.04"
            distro_name="Ubuntu"
            ;;
        debian)
            min_version="12"
            distro_name="Debian"
            if [[ -z "$os_version" ]]; then
                os_version="$(debian_version_from_codename "$os_codename" || true)"
            fi
            ;;
        *)
            echo -e "\033[31m当前系统为 $os_name，不在 7.x 主线内核安装白名单内。\033[0m"
            echo -e "\033[33m最低支持：Ubuntu 24.04+ / Debian 12+；推荐系统：Ubuntu 24.04+ / Debian 12。旧系统/衍生系统可能因用户态、initramfs 或引导链路过旧导致 kernel panic。\033[0m"
            return 1
            ;;
    esac

    if [[ -z "$os_version" ]] || ! version_ge "$os_version" "$min_version"; then
        echo -e "\033[31m当前系统版本过旧：$os_name。已拒绝安装 7.x 主线内核。\033[0m"
        echo -e "\033[33m最低要求：${distro_name} ${min_version}+。推荐使用 Ubuntu 24.04+ 或 Debian 12+。请先升级系统，再重新运行安装脚本。\033[0m"
        echo -e "\033[33m你仍可使用本脚本的状态检查、网络调优、清空优化或卸载功能。\033[0m"
        return 1
    fi
}

# 函数：清理 sysctl.d 中的旧配置
clean_sysctl_conf() {
    sudo touch "$SYSCTL_CONF"
    sudo sed -i '/net.core.default_qdisc/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_congestion_control/d' "$SYSCTL_CONF"
}

# 函数：清理智能带宽优化配置
clean_smart_tuning_conf() {
    sudo touch "$SYSCTL_CONF"
    sudo sed -i '/net.core.rmem_max/d' "$SYSCTL_CONF"
    sudo sed -i '/net.core.wmem_max/d' "$SYSCTL_CONF"
    sudo sed -i '/net.core.optmem_max/d' "$SYSCTL_CONF"
    sudo sed -i '/net.core.netdev_max_backlog/d' "$SYSCTL_CONF"
    sudo sed -i '/net.core.somaxconn/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_wmem/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_rmem/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_limit_output_bytes/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_slow_start_after_idle/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_notsent_lowat/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_autocorking/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_no_metrics_save/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_mtu_probing/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_fastopen/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_window_scaling/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_moderate_rcvbuf/d' "$SYSCTL_CONF"
    sudo sed -i '/net.ipv4.tcp_ecn/d' "$SYSCTL_CONF"
}

# 函数：清理亚太线路调优配置
clean_apac_tuning_conf() {
    clean_smart_tuning_conf
}

# 函数：应用亚太机器 TCP 调优
apply_apac_tuning() {
    echo -e "\033[36m正在应用亚太机器 TCP 调优...\033[0m"

    if sudo sysctl -w net.ipv4.tcp_wmem="4096 16384 12582912" > /dev/null \
        && sudo sysctl -w net.ipv4.tcp_rmem="4096 131072 33554432" > /dev/null \
        && sudo sysctl -w net.ipv4.tcp_limit_output_bytes="4194304" > /dev/null \
        && sudo sysctl -w net.ipv4.tcp_slow_start_after_idle="0" > /dev/null; then
        echo -e "\033[1;32m✔ 亚太机器 TCP 调优已立即生效\033[0m"
    else
        echo -e "\033[31m✘ 亚太机器 TCP 调优应用失败，请检查当前内核是否支持这些 sysctl 项。\033[0m"
        return 1
    fi

    clean_apac_tuning_conf
    {
        echo "net.ipv4.tcp_wmem = 4096 16384 12582912"
        echo "net.ipv4.tcp_rmem = 4096 131072 33554432"
        echo "net.ipv4.tcp_limit_output_bytes = 4194304"
        echo "net.ipv4.tcp_slow_start_after_idle = 0"
    } | sudo tee -a "$SYSCTL_CONF" > /dev/null

    echo -e "\033[1;32m✔ 亚太机器 TCP 调优已永久写入：$SYSCTL_CONF\033[0m"
    echo -e "\033[36m  tcp_wmem:                 \033[1;32m$(sysctl -n net.ipv4.tcp_wmem)\033[0m"
    echo -e "\033[36m  tcp_rmem:                 \033[1;32m$(sysctl -n net.ipv4.tcp_rmem)\033[0m"
    echo -e "\033[36m  tcp_limit_output_bytes:   \033[1;32m$(sysctl -n net.ipv4.tcp_limit_output_bytes)\033[0m"
    echo -e "\033[36m  tcp_slow_start_after_idle:\033[1;32m $(sysctl -n net.ipv4.tcp_slow_start_after_idle)\033[0m"
}

# 函数：判断是否为正数
is_positive_number() {
    awk -v value="$1" 'BEGIN { exit !(value > 0) }'
}

# 函数：按内存容量限制智能优化 buffer，单位：MB
get_tcp_buffer_cap_mb() {
    local mem_kb
    mem_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)

    if ! [[ "$mem_kb" =~ ^[0-9]+$ ]]; then
        echo 64
    elif (( mem_kb < 524288 )); then
        echo 16
    elif (( mem_kb < 1048576 )); then
        echo 32
    else
        echo 64
    fi
}

# 函数：按带宽和地区映射智能优化 buffer，单位：MB
calculate_smart_buffer_mb() {
    local bandwidth="$1"
    local region="$2"
    local cap_mb="$3"
    local buffer_mb=16

    bandwidth="${bandwidth%.*}"
    if ! [[ "$bandwidth" =~ ^[0-9]+$ ]] || (( bandwidth <= 0 )); then
        bandwidth=1000
    fi

    if [[ "$region" == "overseas" ]]; then
        if (( bandwidth < 500 )); then
            buffer_mb=16
        elif (( bandwidth < 1000 )); then
            buffer_mb=48
        else
            buffer_mb=64
        fi
    else
        if (( bandwidth < 500 )); then
            buffer_mb=8
        elif (( bandwidth < 1000 )); then
            buffer_mb=12
        elif (( bandwidth < 2000 )); then
            buffer_mb=16
        elif (( bandwidth < 5000 )); then
            buffer_mb=24
        elif (( bandwidth < 10000 )); then
            buffer_mb=28
        else
            buffer_mb=32
        fi
    fi

    if (( buffer_mb > cap_mb )); then
        buffer_mb="$cap_mb"
    fi
    echo "$buffer_mb"
}

# 函数：获取 Ookla 官方 speedtest 下载地址
get_ookla_speedtest_download_url() {
    local cpu_arch
    cpu_arch=$(uname -m)
    case "$cpu_arch" in
        x86_64)
            echo "https://install.speedtest.net/app/cli/ookla-speedtest-${OOKLA_SPEEDTEST_VERSION}-linux-x86_64.tgz"
            ;;
        aarch64)
            echo "https://install.speedtest.net/app/cli/ookla-speedtest-${OOKLA_SPEEDTEST_VERSION}-linux-aarch64.tgz"
            ;;
        *)
            echo -e "\033[33m⚠ 当前架构 $cpu_arch 暂无内置 Ookla speedtest 下载地址。\033[0m" >&2
            return 1
            ;;
    esac
}

# 函数：检测当前 speedtest 是否为 Ookla 官方 CLI
is_ookla_speedtest() {
    local bin_path="${1:-}"
    [[ -n "$bin_path" ]] || return 1
    "$bin_path" --version 2>&1 | grep -q "Speedtest by Ookla ${OOKLA_SPEEDTEST_VERSION}"
}

# 函数：移除 speedtest-cli，避免误用 Python 版导致输出解析失败
remove_speedtest_cli() {
    local speedtest_path=""
    local version_output=""

    speedtest_path=$(command -v speedtest 2>/dev/null || true)
    if [[ -n "$speedtest_path" ]] && ! is_ookla_speedtest "$speedtest_path"; then
        version_output=$($speedtest_path --version 2>&1 || true)
        if echo "$version_output" | grep -qi "speedtest-cli\|python" || dpkg -S "$speedtest_path" 2>/dev/null | grep -q '^speedtest-cli:'; then
            echo -e "\033[33m检测到非 Ookla 官方 speedtest，正在移除 speedtest-cli...\033[0m"
            sudo apt-get remove --purge -y speedtest-cli > /dev/null 2>&1 || true
        fi

        if [[ "$speedtest_path" != "/usr/local/bin/speedtest" ]]; then
            sudo rm -f "$speedtest_path" 2>/dev/null || true
        fi
    fi

    if dpkg -l speedtest-cli 2>/dev/null | awk 'NR>5 && $1 ~ /^ii/ {found=1} END {exit !found}'; then
        echo -e "\033[33m检测到 speedtest-cli 软件包，正在移除...\033[0m"
        sudo apt-get remove --purge -y speedtest-cli > /dev/null 2>&1 || true
    fi

    hash -r 2>/dev/null || true
}

# 函数：安装指定版本 Ookla 官方 speedtest
install_ookla_speedtest() {
    local download_url

    download_url=$(get_ookla_speedtest_download_url) || return 1

    echo -e "\033[33m正在安装 Ookla speedtest ${OOKLA_SPEEDTEST_VERSION}...\033[0m"
    (
        cd /tmp || exit 1
        rm -rf speedtest speedtest.tgz speedtest.5 speedtest.md
        wget -q "$download_url" -O speedtest.tgz
        tar -xzf speedtest.tgz
        sudo mv speedtest /usr/local/bin/speedtest
        sudo chmod +x /usr/local/bin/speedtest
        rm -f speedtest.tgz speedtest.5 speedtest.md
    ) || return 1

    SPEEDTEST_BIN="/usr/local/bin/speedtest"
    hash -r 2>/dev/null || true

    if ! is_ookla_speedtest "$SPEEDTEST_BIN"; then
        echo -e "\033[31mOokla speedtest 安装后校验失败。\033[0m"
        return 1
    fi
}

# 函数：确保 Ookla 官方 speedtest 可用
ensure_ookla_speedtest() {
    remove_speedtest_cli

    if command -v speedtest > /dev/null 2>&1; then
        SPEEDTEST_BIN=$(command -v speedtest)
        if is_ookla_speedtest "$SPEEDTEST_BIN"; then
            return 0
        fi
    fi

    if command -v speedtest > /dev/null 2>&1; then
        SPEEDTEST_BIN=$(command -v speedtest)
        if is_ookla_speedtest "$SPEEDTEST_BIN"; then
            return 0
        fi
    fi

    install_ookla_speedtest
}

# 函数：执行一次 Speedtest 测速并解析带宽
run_speedtest_once() {
    local servers_list
    local speedtest_output=""
    local attempt=0

    servers_list=$("$SPEEDTEST_BIN" --accept-license --accept-gdpr --servers 2>/dev/null | sed -nE 's/^[[:space:]]*([0-9]+).*/\1/p' | head -n 10)
    if [[ -z "$servers_list" ]]; then
        servers_list="auto"
    fi

    for server_id in $servers_list; do
        attempt=$((attempt + 1))
        if (( attempt > 5 )); then
            break
        fi

        if [[ "$server_id" == "auto" ]]; then
            speedtest_output=$("$SPEEDTEST_BIN" --accept-license --accept-gdpr 2>&1)
        else
            speedtest_output=$("$SPEEDTEST_BIN" --accept-license --accept-gdpr --server-id="$server_id" 2>&1)
        fi

        SPEEDTEST_DOWNLOAD=$(echo "$speedtest_output" | sed -nE 's/.*[Dd]ownload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)
        SPEEDTEST_UPLOAD=$(echo "$speedtest_output" | sed -nE 's/.*[Uu]pload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)

        if is_positive_number "$SPEEDTEST_UPLOAD" && ! echo "$speedtest_output" | grep -qi "FAILED\|error"; then
            return 0
        fi

        SPEEDTEST_DOWNLOAD=""
        SPEEDTEST_UPLOAD=""
    done

    return 1
}

# 函数：运行 Ookla Speedtest 并解析 Download/Upload，不展示测速节点延迟
run_speedtest_measurement() {
    SPEEDTEST_DOWNLOAD=""
    SPEEDTEST_UPLOAD=""

    ensure_ookla_speedtest || return 1

    echo -e "\033[36m正在运行 Ookla Speedtest 测速，请稍候...\033[0m"
    echo -e "\033[33m测速只用于估算带宽；测速节点延迟不会显示，也不会用于 RTT 计算。\033[0m"

    if ! run_speedtest_once; then
        echo -e "\033[33m⚠ Speedtest 输出解析失败，正在清理 speedtest-cli 并重装 Ookla 官方版本后重试...\033[0m"
        remove_speedtest_cli
        install_ookla_speedtest || return 1
        run_speedtest_once || true
    fi

    if is_positive_number "$SPEEDTEST_UPLOAD"; then
        echo -e "\033[36m  Download: \033[1;32m${SPEEDTEST_DOWNLOAD:-0} Mbit/s\033[0m"
        echo -e "\033[36m  Upload:   \033[1;32m${SPEEDTEST_UPLOAD} Mbit/s\033[0m"
        return 0
    fi

    echo -e "\033[33m⚠ Speedtest 输出解析失败，将改为手动输入带宽。\033[0m"
    return 1
}

# 函数：读取正数输入
read_positive_value() {
    local prompt="$1"
    local default_value="$2"
    local value=""

    while true; do
        echo -n -e "$prompt" >&2
        read -r value
        value="${value:-$default_value}"
        if is_positive_number "$value"; then
            echo "$value"
            return 0
        fi
        echo -e "\033[31m请输入有效的正数。\033[0m" >&2
    done
}

# 函数：读取必填正数输入
read_required_positive_value() {
    local prompt="$1"
    local value=""

    while true; do
        echo -n -e "$prompt" >&2
        read -r value
        if is_positive_number "$value"; then
            echo "$value"
            return 0
        fi
        echo -e "\033[31m请输入有效的正数，不能留空。\033[0m" >&2
    done
}

# 函数：选择地区/RTT 模式
select_tuning_rtt() {
    local choice=""
    local buffer_choice=""

    while true; do
        echo -e "\033[36m请选择 buffer 档位模式，并填写真实链接延迟：\033[0m"
        echo -e "\033[33m 1. 亚太档位（通常 RTT < 100ms）\033[0m"
        echo -e "\033[33m 2. 美欧档位（通常 RTT 150-300ms）\033[0m"
        echo -e "\033[33m 3. 手动 RTT + 手动档位\033[0m"
        echo -n -e "\033[36m请选择 (1-3): \033[0m"
        read -r choice

        case "$choice" in
            1)
                SMART_REGION="亚太"
                SMART_REGION_CODE="asia"
                SMART_RTT_MS=$(read_required_positive_value "\033[36m请输入真实链接延迟(ms，v2rayN 测出来的即可): \033[0m")
                return 0
                ;;
            2)
                SMART_REGION="美欧"
                SMART_REGION_CODE="overseas"
                SMART_RTT_MS=$(read_required_positive_value "\033[36m请输入真实链接延迟(ms，v2rayN 测出来的即可): \033[0m")
                return 0
                ;;
            3)
                SMART_RTT_MS=$(read_required_positive_value "\033[36m请输入真实链接延迟(ms，v2rayN 测出来的即可): \033[0m")
                while true; do
                    echo -e "\033[36m请选择 buffer 档位模式：\033[0m"
                    echo -e "\033[33m 1. 亚太档位\033[0m"
                    echo -e "\033[33m 2. 美欧档位\033[0m"
                    echo -n -e "\033[36m请选择 (1-2): \033[0m"
                    read -r buffer_choice
                    case "$buffer_choice" in
                        1)
                            SMART_REGION="手动 RTT / 亚太档"
                            SMART_REGION_CODE="asia"
                            return 0
                            ;;
                        2)
                            SMART_REGION="手动 RTT / 美欧档"
                            SMART_REGION_CODE="overseas"
                            return 0
                            ;;
                        *)
                            echo -e "\033[31m请输入 1 或 2 选择 buffer 档位。\033[0m"
                            ;;
                    esac
                done
                ;;
            *)
                echo -e "\033[31m请输入 1、2 或 3 选择线路模式。\033[0m"
                ;;
        esac
    done
}

# 函数：应用 BBR v3 智能带宽优化
apply_smart_bandwidth_tuning() {
    local upload_mbps=""
    local download_mbps=""
    local cap_mb=""
    local buffer_mb=""
    local buffer_bytes=""
    local output_bytes="4194304"
    local smart_algo="bbr"
    local smart_qdisc="fq"

    echo -e "\033[36m正在准备 BBR v3 智能带宽优化...\033[0m"
    load_qdisc_module "$smart_qdisc"

    if sudo sysctl -w net.core.default_qdisc="$smart_qdisc" > /dev/null \
        && sudo sysctl -w net.ipv4.tcp_congestion_control="$smart_algo" > /dev/null; then
        echo -e "\033[1;32m✔ 已启用 BBR + FQ\033[0m"
    else
        echo -e "\033[31m✘ BBR + FQ 启用失败，请确认当前内核支持 BBR 和 fq。\033[0m"
        return 1
    fi

    if run_speedtest_measurement; then
        upload_mbps="${SPEEDTEST_UPLOAD%.*}"
        download_mbps="${SPEEDTEST_DOWNLOAD%.*}"
    else
        upload_mbps=$(read_positive_value "\033[36m请输入上传带宽(Mbit/s，默认 1000): \033[0m" "1000")
        download_mbps="$upload_mbps"
    fi

    if ! [[ "$upload_mbps" =~ ^[0-9]+$ ]] || (( upload_mbps <= 0 )); then
        upload_mbps="1000"
    fi
    if ! [[ "$download_mbps" =~ ^[0-9]+$ ]] || (( download_mbps <= 0 )); then
        download_mbps="$upload_mbps"
    fi

    select_tuning_rtt

    cap_mb=$(get_tcp_buffer_cap_mb)
    buffer_mb=$(calculate_smart_buffer_mb "$upload_mbps" "$SMART_REGION_CODE" "$cap_mb")
    buffer_bytes=$((buffer_mb * 1024 * 1024))

    if sudo sysctl -w net.core.rmem_max="$buffer_bytes" > /dev/null \
        && sudo sysctl -w net.core.wmem_max="$buffer_bytes" > /dev/null \
        && sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 $buffer_bytes" > /dev/null \
        && sudo sysctl -w net.ipv4.tcp_rmem="4096 87380 $buffer_bytes" > /dev/null \
        && sudo sysctl -w net.ipv4.tcp_limit_output_bytes="$output_bytes" > /dev/null \
        && sudo sysctl -w net.ipv4.tcp_slow_start_after_idle="0" > /dev/null; then
        echo -e "\033[1;32m✔ BBR v3 智能带宽优化已立即生效\033[0m"
    else
        echo -e "\033[31m✘ BBR v3 智能带宽优化应用失败，请检查当前内核是否支持这些 sysctl 项。\033[0m"
        return 1
    fi

    clean_sysctl_conf
    clean_smart_tuning_conf
    {
        echo "net.core.default_qdisc=$smart_qdisc"
        echo "net.ipv4.tcp_congestion_control=$smart_algo"
        echo "net.core.rmem_max = $buffer_bytes"
        echo "net.core.wmem_max = $buffer_bytes"
        echo "net.ipv4.tcp_wmem = 4096 65536 $buffer_bytes"
        echo "net.ipv4.tcp_rmem = 4096 87380 $buffer_bytes"
        echo "net.ipv4.tcp_limit_output_bytes = $output_bytes"
        echo "net.ipv4.tcp_slow_start_after_idle = 0"
    } | sudo tee -a "$SYSCTL_CONF" > /dev/null

    echo -e "\033[1;32m✔ 智能优化配置已永久写入：$SYSCTL_CONF\033[0m"
    echo -e "\033[36m  线路模式：               \033[1;32m$SMART_REGION\033[0m"
    echo -e "\033[36m  手动 RTT：                \033[1;32m${SMART_RTT_MS} ms\033[0m"
    echo -e "\033[36m  上传/下载：               \033[1;32m${upload_mbps}/${download_mbps} Mbit/s\033[0m"
    echo -e "\033[36m  推荐缓冲区：             \033[1;32m${buffer_mb}MB\033[0m"
    echo -e "\033[36m  内存保护上限：           \033[1;32m${cap_mb}MB\033[0m"
    echo -e "\033[36m  队列算法：               \033[1;32m$(sysctl -n net.core.default_qdisc)\033[0m"
    echo -e "\033[36m  拥塞控制：               \033[1;32m$(sysctl -n net.ipv4.tcp_congestion_control)\033[0m"
    echo -e "\033[36m  tcp_wmem:                 \033[1;32m$(sysctl -n net.ipv4.tcp_wmem)\033[0m"
    echo -e "\033[36m  tcp_rmem:                 \033[1;32m$(sysctl -n net.ipv4.tcp_rmem)\033[0m"
    echo -e "\033[36m  tcp_limit_output_bytes:   \033[1;32m$(sysctl -n net.ipv4.tcp_limit_output_bytes)\033[0m"
    echo -e "\033[36m  tcp_slow_start_after_idle:\033[1;32m $(sysctl -n net.ipv4.tcp_slow_start_after_idle)\033[0m"
}

# 函数：应用极限测速挑战模式
apply_extreme_speedtest_tuning() {
    local extreme_algo="bbr"
    local extreme_qdisc="fq"
    local buffer_bytes="1073741824"
    local output_bytes="268435456"
    local backlog="1000000"
    local txqueuelen="100000"
    local iface

    echo -e "\033[36m正在应用 BBR v3 疯批模式...\033[0m"
    echo -e "\033[33m该模式只适合自有链路极限测速，不适合日常使用。\033[0m"
    echo -e "\033[33m它会优先压榨吞吐，可能显著增加重传、抖动、排队延迟和内存占用。\033[0m"

    load_qdisc_module "$extreme_qdisc"

    if sudo sysctl -w net.core.default_qdisc="$extreme_qdisc" > /dev/null \
        && sudo sysctl -w net.ipv4.tcp_congestion_control="$extreme_algo" > /dev/null; then
        echo -e "\033[1;32m✔ 已启用 BBR + FQ\033[0m"
    else
        echo -e "\033[31m✘ BBR + FQ 启用失败，请确认当前内核支持 BBR 和 fq。\033[0m"
        return 1
    fi

    apply_qdisc_to_active_interfaces "$extreme_qdisc" || true

    if ensure_iproute2_tools; then
        while IFS= read -r iface; do
            [[ -z "$iface" ]] && continue
            if sudo ip link set dev "$iface" txqueuelen "$txqueuelen" 2>/dev/null; then
                echo -e "\033[1;32m✔ 当前网卡 $iface 的 txqueuelen 已拉高到 $txqueuelen\033[0m"
            else
                echo -e "\033[33m⚠ 当前网卡 $iface 设置 txqueuelen 失败，继续应用 TCP 参数\033[0m"
            fi
        done < <(get_default_route_interfaces)
    fi

    if sudo sysctl -w net.core.rmem_max="$buffer_bytes" > /dev/null \
        && sudo sysctl -w net.core.wmem_max="$buffer_bytes" > /dev/null \
        && sudo sysctl -w net.ipv4.tcp_wmem="4096 1048576 $buffer_bytes" > /dev/null \
        && sudo sysctl -w net.ipv4.tcp_rmem="4096 1048576 $buffer_bytes" > /dev/null \
        && sudo sysctl -w net.ipv4.tcp_limit_output_bytes="$output_bytes" > /dev/null \
        && sudo sysctl -w net.ipv4.tcp_slow_start_after_idle="0" > /dev/null; then
        echo -e "\033[1;32m✔ 核心极限测速参数已立即生效\033[0m"
    else
        echo -e "\033[31m✘ 疯批模式核心参数应用失败，请检查当前内核是否支持这些 sysctl 项。\033[0m"
        return 1
    fi

    sudo sysctl -w net.core.netdev_max_backlog="$backlog" > /dev/null 2>&1 || true
    sudo sysctl -w net.core.optmem_max="$buffer_bytes" > /dev/null 2>&1 || true
    sudo sysctl -w net.core.somaxconn="65535" > /dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_notsent_lowat="4294967295" > /dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_autocorking="0" > /dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_no_metrics_save="1" > /dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_mtu_probing="1" > /dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_fastopen="3" > /dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_window_scaling="1" > /dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_moderate_rcvbuf="1" > /dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_ecn="0" > /dev/null 2>&1 || true

    clean_sysctl_conf
    clean_smart_tuning_conf
    {
        echo "net.core.default_qdisc=$extreme_qdisc"
        echo "net.ipv4.tcp_congestion_control=$extreme_algo"
        echo "net.core.rmem_max = $buffer_bytes"
        echo "net.core.wmem_max = $buffer_bytes"
        echo "net.core.optmem_max = $buffer_bytes"
        echo "net.core.netdev_max_backlog = $backlog"
        echo "net.core.somaxconn = 65535"
        echo "net.ipv4.tcp_wmem = 4096 1048576 $buffer_bytes"
        echo "net.ipv4.tcp_rmem = 4096 1048576 $buffer_bytes"
        echo "net.ipv4.tcp_limit_output_bytes = $output_bytes"
        echo "net.ipv4.tcp_slow_start_after_idle = 0"
        echo "net.ipv4.tcp_notsent_lowat = 4294967295"
        echo "net.ipv4.tcp_autocorking = 0"
        echo "net.ipv4.tcp_no_metrics_save = 1"
        echo "net.ipv4.tcp_mtu_probing = 1"
        echo "net.ipv4.tcp_fastopen = 3"
        echo "net.ipv4.tcp_window_scaling = 1"
        echo "net.ipv4.tcp_moderate_rcvbuf = 1"
        echo "net.ipv4.tcp_ecn = 0"
    } | sudo tee -a "$SYSCTL_CONF" > /dev/null

    echo -e "\033[1;32m✔ 疯批模式配置已永久写入：$SYSCTL_CONF\033[0m"
    echo -e "\033[36m  队列算法：               \033[1;32m$(sysctl -n net.core.default_qdisc)\033[0m"
    echo -e "\033[36m  拥塞控制：               \033[1;32m$(sysctl -n net.ipv4.tcp_congestion_control)\033[0m"
    echo -e "\033[36m  tcp_wmem:                 \033[1;32m$(sysctl -n net.ipv4.tcp_wmem)\033[0m"
    echo -e "\033[36m  tcp_rmem:                 \033[1;32m$(sysctl -n net.ipv4.tcp_rmem)\033[0m"
    echo -e "\033[36m  tcp_limit_output_bytes:   \033[1;32m$(sysctl -n net.ipv4.tcp_limit_output_bytes)\033[0m"
    echo -e "\033[36m  tcp_slow_start_after_idle:\033[1;32m $(sysctl -n net.ipv4.tcp_slow_start_after_idle)\033[0m"
}

# 函数：清空本脚本写入的网络优化配置
clear_network_optimizations() {
    echo -e "\033[36m正在清空本脚本写入的网络优化配置...\033[0m"
    clean_sysctl_conf
    clean_smart_tuning_conf
    sudo rm -f "$MODULES_CONF"
    sudo sysctl --system > /dev/null 2>&1 || true

    echo -e "\033[1;32m✔ 已清空网络优化持久配置\033[0m"
    echo -e "\033[36m  已清理：$SYSCTL_CONF 中的 BBR/qdisc/TCP buffer 参数\033[0m"
    echo -e "\033[36m  已删除：$MODULES_CONF\033[0m"
    echo -e "\033[33m  当前运行态参数可能要到重启后完全恢复为系统默认值。\033[0m"
}

# 函数：加载队列调度模块
load_qdisc_module() {
    local qdisc_name="$1"
    local module_name="sch_$qdisc_name"
    local previous_qdisc
    local applied_qdisc

    previous_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)

    if ! lsmod | grep -q "^${module_name//-/_}"; then
        sudo modprobe "$module_name" 2>/dev/null || true
    fi

    if sudo sysctl -w net.core.default_qdisc="$qdisc_name" > /dev/null 2>&1; then
        applied_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
        if [[ -n "$previous_qdisc" ]]; then
            sudo sysctl -w net.core.default_qdisc="$previous_qdisc" > /dev/null 2>&1 || true
        fi
        if [[ "$applied_qdisc" == "$qdisc_name" ]]; then
            return 0
        fi
    fi

    echo -e "\033[36m正在加载内核模块 $module_name...\033[0m"
    if sudo modprobe "$module_name" 2>/dev/null; then
        if sudo sysctl -w net.core.default_qdisc="$qdisc_name" > /dev/null 2>&1; then
            applied_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
            if [[ -n "$previous_qdisc" ]]; then
                sudo sysctl -w net.core.default_qdisc="$previous_qdisc" > /dev/null 2>&1 || true
            fi
            if [[ "$applied_qdisc" == "$qdisc_name" ]]; then
                echo -e "\033[1;32m✔ 队列算法 $qdisc_name 可用\033[0m"
                return 0
            fi
        fi
    fi

    echo -e "\033[33m⚠ 队列算法 $qdisc_name 不可用，可能当前内核缺少 $module_name\033[0m"
    return 1
}

# 函数：确保可以操作当前网卡队列
ensure_iproute2_tools() {
    if command -v ip > /dev/null 2>&1 && command -v tc > /dev/null 2>&1; then
        return 0
    fi

    echo -e "\033[36m正在安装 iproute2，用于立即切换当前网卡队列算法...\033[0m"
    sudo apt-get update > /dev/null 2>&1 || true
    if sudo apt-get install -y iproute2 > /dev/null 2>&1; then
        return 0
    fi

    echo -e "\033[33m⚠ iproute2 安装失败，当前网卡队列无法立即替换；仍会写入 default_qdisc。\033[0m"
    return 1
}

# 函数：获取默认路由出口网卡
get_default_route_interfaces() {
    {
        ip -o route show default 2>/dev/null || true
        ip -o -6 route show default 2>/dev/null || true
    } | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}' | sort -u
}

# 函数：让当前默认出口网卡立即切换队列算法
apply_qdisc_to_active_interfaces() {
    local qdisc_name="$1"
    local interfaces=()
    local iface
    local applied=0
    local failed=0

    if ! ensure_iproute2_tools; then
        return 0
    fi

    while IFS= read -r iface; do
        [[ -n "$iface" ]] && interfaces+=("$iface")
    done < <(get_default_route_interfaces)

    if [[ ${#interfaces[@]} -eq 0 ]]; then
        echo -e "\033[33m⚠ 未找到默认路由出口网卡，已仅设置 default_qdisc。\033[0m"
        return 0
    fi

    for iface in "${interfaces[@]}"; do
        if sudo tc qdisc replace dev "$iface" root "$qdisc_name" 2>/dev/null; then
            echo -e "\033[1;32m✔ 当前网卡 $iface 已切换为 $qdisc_name\033[0m"
            applied=1
        else
            echo -e "\033[33m⚠ 当前网卡 $iface 切换 $qdisc_name 失败\033[0m"
            failed=1
        fi
    done

    if [[ "$applied" -eq 1 ]]; then
        return 0
    fi

    [[ "$failed" -eq 1 ]] && return 1
    return 0
}

# 函数：根据队列算法是否为模块，决定是否写入开机加载
persist_qdisc_module() {
    local qdisc_name="$1"
    local module_name="sch_$qdisc_name"

    if [[ "$qdisc_name" == "fq" ]]; then
        sudo rm -f "$MODULES_CONF"
        echo -e "\033[1;32m(☆^ー^☆) 更改已永久保存啦~\033[0m"
        return 0
    fi

    if modinfo "$module_name" > /dev/null 2>&1 || lsmod | grep -q "^${module_name//-/_}"; then
        echo "$module_name" | sudo tee "$MODULES_CONF" > /dev/null
        echo -e "\033[1;32m(☆^ー^☆) 更改已永久保存，模块 $module_name 将在开机时自动加载~\033[0m"
    else
        sudo rm -f "$MODULES_CONF"
        echo -e "\033[1;32m(☆^ー^☆) 更改已永久保存；$qdisc_name 可能为内置队列，无需写入模块加载配置~\033[0m"
    fi
}

# 函数：确保安全规则存在（不存在则追加）
ensure_security_rule() {
    local rule="$1"
    local changed_var="$2"
    if ! grep -Fqx "$rule" "$SECURITY_MODPROBE_CONF" 2>/dev/null; then
        echo "$rule" | sudo tee -a "$SECURITY_MODPROBE_CONF" > /dev/null
        eval "$changed_var=1"
    fi
}

current_kernel_disables_aead() {
    local kernel_release
    local boot_config

    kernel_release=$(uname -r)
    boot_config="/boot/config-$kernel_release"

    if [[ -r "$boot_config" ]]; then
        grep -Fqx "# CONFIG_CRYPTO_USER_API_AEAD is not set" "$boot_config"
        return $?
    fi

    if [[ -r /proc/config.gz ]] && command -v gzip >/dev/null 2>&1; then
        gzip -dc /proc/config.gz 2>/dev/null | grep -Fqx "# CONFIG_CRYPTO_USER_API_AEAD is not set"
        return $?
    fi

    return 1
}

# 函数：应用安全缓解（Dirty Frag）
apply_security_mitigations() {
    local changed=0

    sudo touch "$SECURITY_MODPROBE_CONF"
    if ! grep -Fqx "# Managed by Actions-bbr-v3" "$SECURITY_MODPROBE_CONF" 2>/dev/null; then
        echo "# Managed by Actions-bbr-v3" | sudo tee -a "$SECURITY_MODPROBE_CONF" > /dev/null
        changed=1
    fi

    # The latest kernel builds disable CONFIG_CRYPTO_USER_API_AEAD, so remove
    # legacy algif_aead runtime blacklists written by older script versions.
    if grep -Eq '^(blacklist algif_aead|install algif_aead /bin/false)$' "$SECURITY_MODPROBE_CONF" 2>/dev/null; then
        if current_kernel_disables_aead; then
            sudo sed -i '/^blacklist algif_aead$/d' "$SECURITY_MODPROBE_CONF"
            sudo sed -i '/^install algif_aead \/bin\/false$/d' "$SECURITY_MODPROBE_CONF"
            changed=1
            echo -e "\033[1;32m✔ 已移除旧的 algif_aead 黑名单；CVE-2026-31431 风险由当前内核配置侧收敛\033[0m"
        else
            echo -e "\033[33m⚠ 当前运行内核尚未确认关闭 CRYPTO_USER_API_AEAD，暂保留旧的 algif_aead 黑名单\033[0m"
        fi
    fi

    # Dirty Frag mitigation
    ensure_security_rule "blacklist esp4" changed
    ensure_security_rule "install esp4 /bin/false" changed
    ensure_security_rule "blacklist esp6" changed
    ensure_security_rule "install esp6 /bin/false" changed
    ensure_security_rule "blacklist rxrpc" changed
    ensure_security_rule "install rxrpc /bin/false" changed

    for mod in esp4 esp6 rxrpc; do
        if lsmod | grep -q "^$mod"; then
            if sudo modprobe -r "$mod" 2>/dev/null; then
                echo -e "\033[1;32m✔ 已卸载 $mod 模块，当前会话已完成缓解\033[0m"
            else
                echo -e "\033[33m⚠ $mod 当前被占用，已写入黑名单，重启后将生效\033[0m"
            fi
        fi
    done

    if [[ "$changed" -eq 1 ]]; then
        echo -e "\033[1;32m✔ 已写入安全策略：$SECURITY_MODPROBE_CONF\033[0m"
    fi
}

# 函数：询问是否永久保存更改
ask_to_save() {
    # 首先尝试加载队列调度模块
    load_qdisc_module "$QDISC"
    
    # 立即应用设置
    echo -e "\033[36m正在应用配置...\033[0m"
    sudo sysctl -w net.core.default_qdisc="$QDISC" > /dev/null 2>&1
    sudo sysctl -w net.ipv4.tcp_congestion_control="$ALGO" > /dev/null 2>&1
    apply_qdisc_to_active_interfaces "$QDISC" || return 1
    
    # 验证是否生效
    NEW_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    NEW_ALGO=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    
    if [[ "$NEW_QDISC" == "$QDISC" && "$NEW_ALGO" == "$ALGO" ]]; then
        echo -e "\033[1;32m✔ 配置已立即生效！\033[0m"
        echo -e "\033[36m  当前队列算法：\033[1;32m$NEW_QDISC\033[0m"
        echo -e "\033[36m  当前拥塞控制：\033[1;32m$NEW_ALGO\033[0m"
    else
        echo -e "\033[31m✘ 配置应用失败！\033[0m"
        echo -e "\033[33m  队列算法期望：$QDISC，实际：$NEW_QDISC\033[0m"
        echo -e "\033[33m  拥塞控制期望：$ALGO，实际：$NEW_ALGO\033[0m"
        echo -e "\033[33m  可能原因：当前内核不支持 $QDISC 队列算法\033[0m"
        return 1
    fi
    
    echo -n -e "\033[36m(｡♥‿♥｡) 要将这些配置永久保存到 $SYSCTL_CONF 吗？(y/n): \033[0m"
    read -r SAVE
    if [[ "$SAVE" == "y" || "$SAVE" == "Y" ]]; then
        clean_sysctl_conf
        echo "net.core.default_qdisc=$QDISC" | sudo tee -a "$SYSCTL_CONF" > /dev/null
        echo "net.ipv4.tcp_congestion_control=$ALGO" | sudo tee -a "$SYSCTL_CONF" > /dev/null
        sudo sysctl --system > /dev/null 2>&1

        persist_qdisc_module "$QDISC"
    else
        echo -e "\033[33m(⌒_⌒;) 好吧，没有永久保存，重启后会恢复原设置呢~\033[0m"
    fi
}

# 函数：获取已安装的 joeyblog 内核版本
get_installed_version() {
    local profile="${1:-any}"
    local versions

    versions=$(dpkg -l 2>/dev/null | awk '/^ii/ && $2 ~ /^linux-image-/ && $2 ~ /joeyblog/ {sub(/^linux-image-/, "", $2); print $2}')
    case "$profile" in
        standard)
            echo "$versions" | grep -E -- '-joeyblog-bbrv3$' | sort -V | tail -n 1
            ;;
        max)
            echo "$versions" | grep -E -- '-joeyblog-bbrv3-max$' | sort -V | tail -n 1
            ;;
        *)
            echo "$versions" | sort -V | tail -n 1
            ;;
    esac
}

get_arch_filter() {
    if [[ "$ARCH" == "aarch64" ]]; then
        echo "arm64"
    elif [[ "$ARCH" == "x86_64" ]]; then
        echo "x86_64"
    fi
}

get_profile_label() {
    case "${1:-standard}" in
        max) echo "BBR v3 Max（激进吞吐内核）" ;;
        *) echo "BBR v3 标准版" ;;
    esac
}

get_expected_installed_version() {
    local tag="$1"
    local profile="${2:-standard}"
    local version

    version="${tag#x86_64-}"
    version="${version#arm64-}"
    version="${version%-max}"

    if [[ "$profile" == "max" ]]; then
        echo "${version}-joeyblog-bbrv3-max"
    else
        echo "${version}-joeyblog-bbrv3"
    fi
}

select_kernel_profile() {
    KERNEL_PROFILE="standard"

    echo -e "\033[36m请选择要安装的内核类型：\033[0m"
    echo -e "\033[33m 1. BBR v3 标准版（推荐日常使用）\033[0m"
    echo -e "\033[33m 2. BBR v3 Max 激进吞吐版（自有链路测速实验）\033[0m"
    echo -n -e "\033[36m请输入选项 (1-2，默认 1): \033[0m"
    read -r PROFILE_CHOICE

    case "${PROFILE_CHOICE:-1}" in
        1)
            KERNEL_PROFILE="standard"
            ;;
        2)
            KERNEL_PROFILE="max"
            echo -e "\033[31m警告：BBR v3 Max 会提高探测和窗口策略的进攻性，但仍保留 loss/ECN/inflight 反馈闭环；只适合自有链路吞吐测试，不建议日常生产使用。\033[0m"
            ;;
        *)
            echo -e "\033[31m输入无效，取消安装。\033[0m"
            return 1
            ;;
    esac
}

# 检查已知不兼容的 DKMS 模块，不能用跳过 postinst 的方式假装安装成功。
assert_compatible_dkms() {
    local status=""
    if command -v dkms >/dev/null 2>&1; then
        if ! status=$(sudo dkms status 2>&1); then
            echo -e "\033[31m无法读取 DKMS 状态，已停止安装：\033[0m\n$status"
            return 1
        fi
    fi
    if printf '%s\n' "$status" | grep -Eq '^mimic(/|,[[:space:]]*)0\.7\.1([,/[:space:]]|$)'; then
        echo -e "\033[31m检测到 mimic/0.7.1：已有在本项目 7.1.8 内核上 DKMS 编译失败的报告，尚未确认目标内核兼容，已保护性停止。\033[0m"
        echo -e "\033[33m请先升级为已确认支持目标内核的 mimic，或继续使用发行版内核。本脚本不会删除该模块或跳过 DKMS。\033[0m"
        echo -e "\033[33m已有失败的详细日志：$DKMS_STATE_DIR/mimic/0.7.1/build/make.log。\033[0m"
        return 1
    fi
}

is_hyperv_system() {
    [[ -d /sys/bus/vmbus ]] \
        || grep -qi 'Microsoft' "$DMI_VENDOR_FILE" 2>/dev/null \
        || { command -v systemd-detect-virt >/dev/null 2>&1 \
            && [[ "$(systemd-detect-virt 2>/dev/null)" == "microsoft" ]]; }
}

assert_cloud_kernel_config() {
    local config_file="$1"
    local symbol
    is_hyperv_system || return 0
    local symbols='HYPERV HYPERV_STORAGE HYPERV_NET PCI_HYPERV BLK_DEV_SD'
    # 以目标配置识别独立 VMBus 开关，避免按内核版本猜测布局。
    if grep -Eq '^(CONFIG_HYPERV_VMBUS=|# CONFIG_HYPERV_VMBUS is not set$)' "$config_file"; then
        symbols="$symbols HYPERV_VMBUS"
    fi
    for symbol in $symbols; do
        if ! grep -Eq "^CONFIG_${symbol}=[ym]$" "$config_file"; then
            echo -e "\033[31m当前为 Hyper-V/Azure，目标内核缺少 CONFIG_${symbol}，重启可能无法挂载磁盘或联网。已拒绝安装。\033[0m"
            return 1
        fi
    done
}

# 使用下载包的元数据识别内核，不信任标签或 /tmp 中的其他文件。
validate_kernel_packages() {
    local package_dir="$1"
    local deb_file package_name package_arch image_file="" headers_found=0
    local host_arch
    host_arch=$(dpkg --print-architecture) || return 1
    KERNEL_DEB_FILES=()
    KERNEL_PACKAGE_RELEASE=""
    for deb_file in "$package_dir"/*.deb; do
        [[ -f "$deb_file" ]] || continue
        if ! dpkg-deb -I "$deb_file" >/dev/null 2>&1; then
            echo -e "\033[31m无法读取安装包：$deb_file；请检查下载是否完整及 dpkg 版本。\033[0m"
            return 1
        fi
        package_name=$(dpkg-deb -f "$deb_file" Package) || return 1
        package_arch=$(dpkg-deb -f "$deb_file" Architecture) || return 1
        if [[ "$package_arch" != "$host_arch" ]]; then
            echo -e "\033[31m安装包架构 $package_arch 与系统 $host_arch 不一致。\033[0m"
            return 1
        fi
        case "$package_name" in
            linux-image-*-joeyblog-bbrv3|linux-image-*-joeyblog-bbrv3-max)
                [[ -z "$image_file" ]] || { echo '安装目录包含多个内核镜像，已停止。'; return 1; }
                image_file="$deb_file"
                KERNEL_PACKAGE_RELEASE="${package_name#linux-image-}"
                ;;
            linux-headers-*-joeyblog-bbrv3|linux-headers-*-joeyblog-bbrv3-max)
                headers_found=$((headers_found + 1))
                ;;
            *) echo "拒绝安装不属于目标内核的包：$package_name"; return 1 ;;
        esac
        KERNEL_DEB_FILES+=("$deb_file")
    done
    if [[ -z "$image_file" || "$headers_found" -ne 1 ]]; then
        echo -e "\033[31m必须完整下载一个内核镜像包和对应 headers 包。\033[0m"
        return 1
    fi
    for deb_file in "${KERNEL_DEB_FILES[@]}"; do
        package_name=$(dpkg-deb -f "$deb_file" Package) || return 1
        if [[ "${package_name#linux-headers-}" != "$KERNEL_PACKAGE_RELEASE" \
            && "${package_name#linux-image-}" != "$KERNEL_PACKAGE_RELEASE" ]]; then
            echo '镜像与 headers 的内核版本不一致，已停止。'
            return 1
        fi
    done
    if ! (set -o pipefail; dpkg-deb --fsys-tarfile "$image_file" \
        | tar -xOf - "./boot/config-$KERNEL_PACKAGE_RELEASE") > "$package_dir/kernel.config"; then
        echo -e "\033[31m无法从内核包读取启动配置，已停止安装。\033[0m"
        return 1
    fi
    assert_cloud_kernel_config "$package_dir/kernel.config"
}

backup_bootloader_state() {
    local backup_dir="$1"
    local name
    sudo mkdir -p "$backup_dir" || return 1
    for name in grub.cfg grubenv; do
        if sudo test -f "$BOOT_DIR/grub/$name"; then
            sudo cp -p "$BOOT_DIR/grub/$name" "$backup_dir/$name" || return 1
        fi
    done
}

restore_bootloader_state() {
    local backup_dir="$1"
    local name restored=0
    for name in grub.cfg grubenv; do
        if sudo test -f "$backup_dir/$name"; then
            sudo cp -p "$backup_dir/$name" "$BOOT_DIR/grub/$name" || return 1
            restored=1
        fi
    done
    if [[ "$restored" == 1 ]]; then
        echo -e "\033[33m已恢复安装前的 GRUB 配置，保留原有默认引导和旧内核。请先修复软件包状态，不要重启。\033[0m"
    else
        echo -e "\033[33m未找到可恢复的 GRUB 快照，请通过云控制台检查引导配置，暂勿重启。\033[0m"
    fi
}

assert_kernel_boot_ready() {
    local release="$1"
    local config_file="$2"
    local initrd_file="$BOOT_DIR/initrd.img-$release"
    local symbol module module_list
    if [[ "$(dpkg-query -W -f='${Status}' "linux-image-$release" 2>/dev/null)" != "install ok installed" ]] \
        || [[ ! -s "$BOOT_DIR/vmlinuz-$release" || ! -s "$initrd_file" ]]; then
        echo -e "\033[31m内核包未完成配置，或缺少内核镜像/initramfs，不能重启。\033[0m"
        return 1
    fi
    is_hyperv_system || return 0
    assert_cloud_kernel_config "$config_file" || return 1
    if grep -Eq '^CONFIG_(HYPERV|HYPERV_VMBUS|HYPERV_STORAGE|HYPERV_NET|PCI_HYPERV|BLK_DEV_SD)=m$' "$config_file"; then
        if ! command -v lsinitramfs >/dev/null 2>&1 \
            || ! module_list=$(sudo lsinitramfs "$initrd_file"); then
            echo -e "\033[31m无法检查 Azure 启动所需的 initramfs 驱动，已停止重启流程。\033[0m"
            return 1
        fi
        for symbol in HYPERV HYPERV_VMBUS HYPERV_STORAGE HYPERV_NET PCI_HYPERV BLK_DEV_SD; do
            grep -qx "CONFIG_${symbol}=m" "$config_file" || continue
            case "$symbol" in
                HYPERV)
                    # 独立 VMBus 开关存在时，以它决定驱动是否为模块。
                    grep -Eq '^CONFIG_HYPERV_VMBUS=[ym]$' "$config_file" && continue
                    module='hv[-_]vmbus'
                    ;;
                HYPERV_VMBUS) module='hv[-_]vmbus' ;;
                HYPERV_STORAGE) module='hv[-_]storvsc' ;;
                HYPERV_NET) module='hv[-_]netvsc' ;;
                PCI_HYPERV) module='pci[-_]hyperv' ;;
                BLK_DEV_SD) module='sd[-_]mod' ;;
            esac
            if ! printf '%s\n' "$module_list" | grep -Eq "/${module}\.ko(\.(xz|gz|zst))?$"; then
                echo -e "\033[31minitramfs 缺少 Azure 必需模块 ${module}，不能重启。\033[0m"
                return 1
            fi
        done
    fi
}

# 函数：更新已知的引导加载程序；未知引导链不能宣称可以安全重启。
update_bootloader() {
    echo -e "\033[36m正在更新引导加载程序...\033[0m"
    if command -v update-grub &> /dev/null; then
        echo -e "\033[33m检测到 GRUB，正在执行 update-grub...\033[0m"
        if sudo update-grub; then
            echo -e "\033[1;32mGRUB 更新成功！\033[0m"
            return 0
        else
            echo -e "\033[1;31mGRUB 更新失败！\033[0m"
            return 1
        fi
    else
        echo -e "\033[33m未找到 'update-grub'。您的系统可能使用 U-Boot 或其他引导程序。\033[0m"
        echo -e "\033[33m软件包可能已运行自己的引导钩子，但本脚本无法确认当前引导链。请先在控制台核对引导配置，暂勿重启。\033[0m"
        return 1
    fi
}

# 函数：安全地安装下载的包
install_packages() {
    local package_dir="$1"
    local audit_output backup_dir
    assert_compatible_dkms || return 1
    audit_output=$(sudo dpkg --audit) || return 1
    if [[ -n "$audit_output" ]]; then
        echo -e "\033[31m系统已有未完成配置的软件包，请先修复；本次未安装新内核：\033[0m\n$audit_output"
        return 1
    fi
    validate_kernel_packages "$package_dir" || return 1
    sudo mkdir -p "$BOOT_BACKUP_DIR" || return 1
    backup_dir=$(sudo mktemp -d "$BOOT_BACKUP_DIR/install.XXXXXX") || return 1
    backup_bootloader_state "$backup_dir" || return 1
    echo -e "\033[36m引导配置快照：$backup_dir\033[0m"
    echo -e "\033[36m开始安装新内核；保留现有内核，供引导失败时回退...\033[0m"
    if sudo dpkg -i "${KERNEL_DEB_FILES[@]}" \
        && assert_kernel_boot_ready "$KERNEL_PACKAGE_RELEASE" "$package_dir/kernel.config" \
        && update_bootloader; then
        echo -e "\033[1;32m内核软件包和引导配置已完成；当前仍在运行 $(uname -r)，重启后才能验证新内核。\033[0m"
        echo -n -e "\033[33m需要重启系统来加载新内核。是否立即重启？ (y/n): \033[0m"
        read -r REBOOT_NOW
        if [[ "$REBOOT_NOW" == "y" || "$REBOOT_NOW" == "Y" ]]; then
            echo -e "\033[36m系统即将重启...\033[0m"
            sudo reboot
        else
            echo -e "\033[33m操作完成。请记得稍后手动重启 ('sudo reboot') 来应用新内核。\033[0m"
        fi
    else
        echo -e "\033[1;31m内核安装或引导验证失败。本次未完成，禁止直接重启。\033[0m"
        restore_bootloader_state "$backup_dir" || echo '恢复 GRUB 快照失败，请立即通过控制台检查引导配置。'
        echo -e "\033[33m请查看上面的 dpkg/DKMS 错误；不要用跳过 DKMS 的方式强行完成安装。\033[0m"
        return 1
    fi
}

# 每次安装只使用本次下载的 image/headers，不替换发行版的 linux-libc-dev。
download_and_install_release() (
    local release_data="$1"
    local tag="$2"
    local package_dir asset_urls url
    asset_urls=$(printf '%s\n' "$release_data" | jq -r --arg tag "$tag" '
        .[] | select(.tag_name == $tag) | .assets[]
        | select(.name | test("^linux-(image|headers)-.*\\.deb$"))
        | select(.name | test("(-dbg_|-dbgsym_)"; "i") | not)
        | .browser_download_url
    ') || return 1
    if [[ -z "$asset_urls" ]]; then
        echo -e "\033[31m该版本没有可安装的内核包。\033[0m"
        return 1
    fi
    package_dir=$(mktemp -d "${TMPDIR:-/tmp}/bbrv3.XXXXXX") || return 1
    trap 'rm -rf "$package_dir"' EXIT
    while IFS= read -r url; do
        echo -e "\033[36m正在下载：$url\033[0m"
        wget -q --show-progress "$url" -O "$package_dir/${url##*/}" || return 1
    done <<< "$asset_urls"
    install_packages "$package_dir"
)

# 函数：检查并安装最新版本
install_latest_version() {
    local profile="${1:-standard}"
    local profile_label
    local arch_filter
    local expected_version

    assert_supported_kernel_install_system || return 1
    profile_label=$(get_profile_label "$profile")

    echo -e "\033[36m正在从 GitHub 获取 ${profile_label} 最新版本信息...\033[0m"
    BASE_URL="https://api.github.com/repos/byJoey/Actions-bbr-v3/releases"
    RELEASE_DATA=$(gh_api_get "$BASE_URL")
    if [[ -z "$RELEASE_DATA" ]]; then
        echo -e "\033[31m从 GitHub 获取版本信息失败。请检查网络连接或 API 状态。\033[0m"
        return 1
    fi
    check_release_api_response "$RELEASE_DATA" || return 1

    arch_filter=$(get_arch_filter)
    LATEST_TAG_NAME=$(echo "$RELEASE_DATA" | jq -r --arg filter "$arch_filter" --arg profile "$profile" '
      map(
        select(.tag_name | test("^" + $filter + "-[0-9]"; "i"))
        | select(if $profile == "max" then (.tag_name | endswith("-max")) else ((.tag_name | endswith("-max")) | not) end)
      )
      | sort_by(.published_at)
      | .[-1].tag_name
    ')

    if [[ -z "$LATEST_TAG_NAME" || "$LATEST_TAG_NAME" == "null" ]]; then
        echo -e "\033[31m未找到适合当前架构 ($ARCH) 的 ${profile_label} 最新版本。\033[0m"
        return 1
    fi
    echo -e "\033[36m检测到最新版本：\033[0m\033[1;32m$LATEST_TAG_NAME\033[0m"

    INSTALLED_VERSION=$(get_installed_version "$profile")
    echo -e "\033[36m当前已安装版本：\033[0m\033[1;32m${INSTALLED_VERSION:-"未安装"}\033[0m"

    expected_version=$(get_expected_installed_version "$LATEST_TAG_NAME" "$profile")

    if [[ -n "$INSTALLED_VERSION" && "$INSTALLED_VERSION" == "$expected_version" ]]; then
        # 修复了此处的颜文字，将反引号 ` 替换为单引号 '
        echo -e "\033[1;32m(o'▽'o) 您已安装最新 ${profile_label}，无需更新！\033[0m"
        return 0
    fi

    echo -e "\033[33m发现新版本或未安装内核，准备下载...\033[0m"
    download_and_install_release "$RELEASE_DATA" "$LATEST_TAG_NAME"
}

# 函数：安装指定版本
install_specific_version() {
    local profile="${1:-standard}"
    local profile_label
    local arch_filter

    assert_supported_kernel_install_system || return 1
    profile_label=$(get_profile_label "$profile")

    BASE_URL="https://api.github.com/repos/byJoey/Actions-bbr-v3/releases"
    RELEASE_DATA=$(gh_api_get "$BASE_URL")
    if [[ -z "$RELEASE_DATA" ]]; then
        echo -e "\033[31m从 GitHub 获取版本信息失败。请检查网络连接或 API 状态。\033[0m"
        return 1
    fi
    check_release_api_response "$RELEASE_DATA" || return 1

    arch_filter=$(get_arch_filter)
    MATCH_TAGS=$(echo "$RELEASE_DATA" | jq -r --arg filter "$arch_filter" --arg profile "$profile" '
      .[]
      | select(.tag_name | test("^" + $filter + "-[0-9]"; "i"))
      | select(if $profile == "max" then (.tag_name | endswith("-max")) else ((.tag_name | endswith("-max")) | not) end)
      | .tag_name
    ')

    if [[ -z "$MATCH_TAGS" ]]; then
        echo -e "\033[31m未找到适合当前架构的 ${profile_label} 版本。\033[0m"
        return 1
    fi

    echo -e "\033[36m以下为适用于当前架构的 ${profile_label} 版本：\033[0m"
    IFS=$'\n' read -rd '' -a TAG_ARRAY <<<"$MATCH_TAGS"

    for i in "${!TAG_ARRAY[@]}"; do
        echo -e "\033[33m $((i+1)). ${TAG_ARRAY[$i]}\033[0m"
    done

    echo -n -e "\033[36m请输入要安装的版本编号（例如 1）：\033[0m"
    read -r CHOICE
    
    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#TAG_ARRAY[@]} )); then
        echo -e "\033[31m输入无效编号，取消操作。\033[0m"
        return 1
    fi
    
    INDEX=$((CHOICE-1))
    SELECTED_TAG="${TAG_ARRAY[$INDEX]}"
    echo -e "\033[36m已选择版本：\033[0m\033[1;32m$SELECTED_TAG\033[0m"

    download_and_install_release "$RELEASE_DATA" "$SELECTED_TAG"
}

# 美化输出的分隔线
print_separator() {
    echo -e "\033[34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
}

# --- 主要执行流程 ---

clear
install_quick_command
apply_security_mitigations
print_separator
echo -e "\033[1;35m(☆ω☆)✧*｡ 欢迎来到 BBR 管理脚本世界哒！ ✧*｡(☆ω☆)\033[0m"
print_separator
echo -e "\033[36m当前 TCP 拥塞控制算法：\033[0m\033[1;32m$CURRENT_ALGO\033[0m"
echo -e "\033[36m当前队列管理算法：    \033[0m\033[1;32m$CURRENT_QDISC\033[0m"
print_separator
echo -e "\033[1;33m作者：Joey  |  博客：https://joeyblog.net  |  反馈群组：https://t.me/+ft-zI76oovgwNmRh\033[0m"
print_separator

echo -e "\033[1;33m╭( ･ㅂ･)و ✧ 你可以选择以下操作哦：\033[0m"
echo -e "\033[33m 1. 🚀 安装或更新 BBR v3 (最新版)\033[0m"
echo -e "\033[33m 2. 📚 指定版本安装\033[0m"
echo -e "\033[33m 3. 🔍 检查 BBR v3 状态\033[0m"
echo -e "\033[33m 4. ⚡ 启用 BBR + FQ\033[0m"
echo -e "\033[33m 5. ⚡ 启用 BBR + FQ_CODEL\033[0m"
echo -e "\033[33m 6. ⚡ 启用 BBR + FQ_PIE\033[0m"
echo -e "\033[33m 7. ⚡ 启用 BBR + CAKE\033[0m"
echo -e "\033[33m 8. 🌏 亚太机器 TCP 调优\033[0m"
echo -e "\033[33m 9. 🗑️  卸载 BBR 内核\033[0m"
echo -e "\033[33m10. 🧠 BBR v3 智能带宽优化\033[0m"
echo -e "\033[33m11. 🧹 清空网络优化配置\033[0m"
echo -e "\033[33m12. 🧨 BBR v3 疯批模式（极限测速挑战）\033[0m"
echo -e "\033[33m13. 禁用 IPv6（保留 IPv4）\033[0m"
echo -e "\033[33m14. 恢复 IPv6\033[0m"
print_separator
echo -n -e "\033[36m请选择一个操作 (1-14) (｡･ω･｡): \033[0m"
read -r ACTION

case "$ACTION" in
    1)
        echo -e "\033[1;32m٩(｡•́‿•̀｡)۶ 您选择了安装或更新 BBR v3！\033[0m"
        select_kernel_profile && install_latest_version "$KERNEL_PROFILE"
        ;;
    2)
        echo -e "\033[1;32m(｡･∀･)ﾉﾞ 您选择了安装指定版本的 BBR！\033[0m"
        select_kernel_profile && install_specific_version "$KERNEL_PROFILE"
        ;;
    3)
        echo -e "\033[1;32m(｡･ω･｡) 检查是否为 BBR v3...\033[0m"
        BBR_MODULE_INFO=$(modinfo tcp_bbr 2>/dev/null)
        if [[ -z "$BBR_MODULE_INFO" ]]; then
            echo -e "\033[36m正在刷新模块依赖...\033[0m"
            depmod -a
            BBR_MODULE_INFO=$(modinfo tcp_bbr 2>/dev/null)
        fi
        if [[ -z "$BBR_MODULE_INFO" ]]; then
            echo -e "\033[31m(⊙﹏⊙) 未加载 tcp_bbr 模块，无法检查版本。请先安装内核并重启。\033[0m"
            exit 1
        fi
        BBR_VERSION=$(echo "$BBR_MODULE_INFO" | awk '/^version:/ {print $2}')
        if [[ "$BBR_VERSION" == "3" ]]; then
            echo -e "\033[36m✔ BBR 模块版本：\033[0m\033[1;32m$BBR_VERSION (v3)\033[0m"
        else
            echo -e "\033[33m(￣﹃￣) 检测到 BBR 模块，但版本是：$BBR_VERSION，不是 v3！\033[0m"
        fi
        
        CURRENT_ALGO=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
        if [[ "$CURRENT_ALGO" == "bbr" ]]; then
            echo -e "\033[36m✔ TCP 拥塞控制算法：\033[0m\033[1;32m$CURRENT_ALGO\033[0m"
        else
            echo -e "\033[31m(⊙﹏⊙) 当前算法不是 bbr，而是：$CURRENT_ALGO\033[0m"
        fi

        if [[ "$BBR_VERSION" == "3" && "$CURRENT_ALGO" == "bbr" ]]; then
            echo -e "\033[1;32mヽ(✿ﾟ▽ﾟ)ノ 检测完成，BBR v3 已正确安装并生效！\033[0m"
        else
            echo -e "\033[33mBBR v3 未完全生效。请确保已安装内核并重启，然后使用选项 4-7 启用。\033[0m"
        fi

        if grep -Eq '^\s*blacklist\s+esp4' "$SECURITY_MODPROBE_CONF" 2>/dev/null \
           && grep -Eq '^\s*blacklist\s+esp6' "$SECURITY_MODPROBE_CONF" 2>/dev/null \
           && grep -Eq '^\s*blacklist\s+rxrpc' "$SECURITY_MODPROBE_CONF" 2>/dev/null; then
            echo -e "\033[1;32m✔ Dirty Frag 缓解状态：已启用（esp4/esp6/rxrpc 已黑名单）\033[0m"
        else
            echo -e "\033[31m✘ Dirty Frag 缓解状态：未启用\033[0m"
            echo -e "\033[33m  建议重新运行脚本，或手动写入 $SECURITY_MODPROBE_CONF\033[0m"
        fi
        ;;
    4)
        echo -e "\033[1;32m(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧ 使用 BBR + FQ 加速！\033[0m"
        ALGO="bbr"
        QDISC="fq"
        ask_to_save
        ;;
    5)
        echo -e "\033[1;32m(๑•̀ㅂ•́)و✧ 使用 BBR + FQ_CODEL 加速！\033[0m"
        ALGO="bbr"
        QDISC="fq_codel"
        ask_to_save
        ;;
    6)
        echo -e "\033[1;32m٩(•‿•)۶ 使用 BBR + FQ_PIE 加速！\033[0m"
        ALGO="bbr"
        QDISC="fq_pie"
        ask_to_save
        ;;
    7)
        echo -e "\033[1;32m(ﾉ≧∀≦)ﾉ 使用 BBR + CAKE 加速！\033[0m"
        ALGO="bbr"
        QDISC="cake"
        ask_to_save
        ;;
    8)
        echo -e "\033[1;32m(๑•̀ㅂ•́)و✧ 您选择了亚太机器 TCP 调优！\033[0m"
        apply_apac_tuning
        ;;
    9)
        echo -e "\033[1;32mヽ(・∀・)ノ 您选择了卸载 BBR 内核！\033[0m"
        PACKAGES_TO_REMOVE=$(dpkg -l | grep "joeyblog" | awk '{print $2}' | tr '\n' ' ')
        if [[ -n "$PACKAGES_TO_REMOVE" ]]; then
            echo -e "\033[36m将要卸载以下内核包: \033[33m$PACKAGES_TO_REMOVE\033[0m"
            sudo apt-get remove --purge $PACKAGES_TO_REMOVE -y
            update_bootloader
            echo -e "\033[1;32m内核包已卸载。请记得重启系统。\033[0m"
        else
            echo -e "\033[33m未找到由本脚本安装的 'joeyblog' 内核包。\033[0m"
        fi
        ;;
    10)
        echo -e "\033[1;32m(๑•̀ㅂ•́)و✧ 您选择了 BBR v3 智能带宽优化！\033[0m"
        apply_smart_bandwidth_tuning
        ;;
    11)
        echo -e "\033[1;32m(๑•̀ㅂ•́)و✧ 您选择了清空网络优化配置！\033[0m"
        clear_network_optimizations
        ;;
    12)
        echo -e "\033[1;32m(╯°□°）╯ 您选择了 BBR v3 疯批模式！\033[0m"
        apply_extreme_speedtest_tuning
        ;;
    13)
        disable_ipv6
        ;;
    14)
        restore_ipv6
        ;;
    *)
        echo -e "\033[31m(￣▽￣)ゞ 无效的选项，请输入 1-14 之间的数字哦~\033[0m"
        ;;
esac
