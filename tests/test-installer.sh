#!/usr/bin/env bash
set -euo pipefail

# 加载真实函数，避免执行菜单、安装依赖或修改宿主机。
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
eval "$(awk '/^gh_api_get\(\)/ {capture=1} /^# --- 主要执行流程 ---/ {exit} capture' "$ROOT_DIR/install.sh")"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { echo "失败：$*" >&2; return 1; }
expect_failure() { if "$@"; then fail "预期被拒绝，但执行成功：$*"; fi; }

# 只模拟外部系统命令，安装、包校验、回退和 IPv6 管理均执行真实函数。
setup_fixture() {
    CASE_DIR=$(mktemp -d "$TEST_DIR/case.XXXXXX")
    BOOT_DIR="$CASE_DIR/boot"
    BOOT_BACKUP_DIR="$CASE_DIR/backups"
    DKMS_STATE_DIR="$CASE_DIR/dkms"
    IPV6_CONF="$CASE_DIR/99-joeyblog-ipv6.conf"
    IPV6_PROC_DIR="$CASE_DIR/proc-ipv6"
    IPV6_STATE_FILE="$CASE_DIR/state/ipv6-before-disable"
    PACKAGE_DIR="$CASE_DIR/packages"
    COMMAND_LOG="$CASE_DIR/commands"
    RELEASE='7.3.1-joeyblog-bbrv3'
    MOCK_DPKG_FAILURE=0
    MOCK_AUDIT=''
    MOCK_HYPERV=0
    MOCK_PACKAGE_ARCH='amd64'
    MOCK_PACKAGE_STATUS='install ok installed'
    MOCK_GRUB_FAILURE=0
    MOCK_MISSING_INITRD=0
    MOCK_DKMS_STATUS=''
    MOCK_DKMS_FAILURE=0
    MOCK_RESTORE_FAILURE=0
    MOCK_IPV4_ROUTE='default via 192.0.2.1 dev eth0'
    SSH_CONNECTION=''
    SSH_CLIENT=''
    mkdir -p "$BOOT_DIR/grub" "$PACKAGE_DIR" "$DKMS_STATE_DIR" "$CASE_DIR/payload/boot"
    echo original-grub > "$BOOT_DIR/grub/grub.cfg"
    echo original-env > "$BOOT_DIR/grub/grubenv"
    echo old-kernel > "$BOOT_DIR/vmlinuz-old"
    : > "$COMMAND_LOG"
    : > "$CASE_DIR/modules"
    touch "$PACKAGE_DIR/linux-image-$RELEASE.deb" "$PACKAGE_DIR/linux-headers-$RELEASE.deb"
    printf '%s\n' 'CONFIG_HYPERV=y' 'CONFIG_HYPERV_VMBUS=y' 'CONFIG_HYPERV_STORAGE=y' \
        'CONFIG_HYPERV_NET=y' 'CONFIG_PCI_HYPERV=y' 'CONFIG_BLK_DEV_SD=y' > "$CASE_DIR/payload/boot/config-$RELEASE"
    tar -cf "$CASE_DIR/payload.tar" -C "$CASE_DIR/payload" .
    local iface
    for iface in all default a0 eth0; do
        mkdir -p "$IPV6_PROC_DIR/$iface"
        echo 0 > "$IPV6_PROC_DIR/$iface/disable_ipv6"
    done
    echo 1 > "$IPV6_PROC_DIR/a0/disable_ipv6"
    sudo() {
        if [[ "$1" == tee && "${2:-}" == "$IPV6_PROC_DIR/a0/disable_ipv6" && "$MOCK_RESTORE_FAILURE" == 1 ]]; then
            return 1
        fi
        if [[ "$1" == tee && "${2:-}" == "$IPV6_PROC_DIR/all/disable_ipv6" ]]; then
            local value switch_file
            value=$(cat)
            for switch_file in "$IPV6_PROC_DIR"/*/disable_ipv6; do
                [[ "$switch_file" == "$IPV6_PROC_DIR/default/disable_ipv6" ]] && continue
                printf '%s\n' "$value" > "$switch_file"
            done
            printf '%s\n' "$value"
        else
            "$@"
        fi
    }
    apt-get() { printf 'apt-get %s\n' "$*" >> "$COMMAND_LOG"; return 1; }
    dkms() { printf '%s\n' "$MOCK_DKMS_STATUS"; [[ "$MOCK_DKMS_FAILURE" == 0 ]]; }
    dpkg() {
        case "$1" in
            --print-architecture) echo amd64 ;;
            --audit) printf '%s' "$MOCK_AUDIT" ;;
            -i)
                printf 'dpkg %s\n' "$*" >> "$COMMAND_LOG"
                # postinst 即使报错，也可能已经重写引导配置。
                echo new-grub > "$BOOT_DIR/grub/grub.cfg"
                echo new-env > "$BOOT_DIR/grub/grubenv"
                echo new-kernel > "$BOOT_DIR/vmlinuz-$RELEASE"
                if [[ "$MOCK_MISSING_INITRD" == 0 ]]; then echo initrd > "$BOOT_DIR/initrd.img-$RELEASE"; fi
                [[ "$MOCK_DPKG_FAILURE" == 0 ]]
                ;;
            *) fail "未预期的 dpkg 操作：$*" ;;
        esac
    }
    dpkg-deb() {
        case "$1" in
            -I) return 0 ;;
            -f)
                case "$3" in
                    Package) local filename="${2##*/}"; echo "${filename%.deb}" ;;
                    Architecture) echo "$MOCK_PACKAGE_ARCH" ;;
                    *) return 1 ;;
                esac
                ;;
            --fsys-tarfile) cat "$CASE_DIR/payload.tar" ;;
            *) return 1 ;;
        esac
    }
    dpkg-query() { printf '%s' "$MOCK_PACKAGE_STATUS"; }
    update-grub() {
        echo update-grub >> "$COMMAND_LOG"
        echo updated-grub > "$BOOT_DIR/grub/grub.cfg"
        [[ "$MOCK_GRUB_FAILURE" == 0 ]]
    }
    reboot() { echo reboot >> "$COMMAND_LOG"; }
    is_hyperv_system() { [[ "$MOCK_HYPERV" == 1 ]]; }
    lsinitramfs() { cat "$CASE_DIR/modules"; }
    ip() { printf '%s\n' "$MOCK_IPV4_ROUTE"; }
    sysctl() {
        printf 'sysctl %s\n' "$*" >> "$COMMAND_LOG"
        case "$1" in
            -n) local key="${2#net.ipv6.conf.}"; cat "$IPV6_PROC_DIR/${key%.disable_ipv6}/disable_ipv6" ;;
            -p) local switch_file; for switch_file in "$IPV6_PROC_DIR"/*/disable_ipv6; do echo 1 > "$switch_file"; done ;;
            --system) return 0 ;;
        esac
    }
}

assert_original_boot() {
    [[ "$(cat "$BOOT_DIR/grub/grub.cfg")" == original-grub ]] || fail '未恢复原有 GRUB 配置'
    [[ "$(cat "$BOOT_DIR/grub/grubenv")" == original-env ]] || fail '未恢复原有 GRUB 环境'
    [[ "$(cat "$BOOT_DIR/vmlinuz-old")" == old-kernel ]] || fail '旧内核丢失'
    ! grep -q 'reboot\|apt-get' "$COMMAND_LOG" || fail '失败后重启或删除了旧内核'
}

test_failed_install_preserves_old_kernel() (
    setup_fixture
    MOCK_DPKG_FAILURE=1
    expect_failure install_packages "$PACKAGE_DIR" > "$CASE_DIR/output"
    grep -q '^dpkg -i ' "$COMMAND_LOG" || fail '没有执行到真实安装路径'
    ! grep -q update-grub "$COMMAND_LOG" || fail 'dpkg 失败后仍更新引导'
    assert_original_boot
)

test_missing_initramfs_and_grub_failure() (
    setup_fixture
    MOCK_MISSING_INITRD=1
    expect_failure install_packages "$PACKAGE_DIR" > "$CASE_DIR/output"
    assert_original_boot
    MOCK_MISSING_INITRD=0
    MOCK_GRUB_FAILURE=1
    expect_failure install_packages "$PACKAGE_DIR" > "$CASE_DIR/output"
    assert_original_boot
)

test_preflight_rejects_incompatible_system() (
    setup_fixture
    MOCK_DKMS_STATUS='mimic/0.7.1, 6.17.0-oracle, aarch64: installed'
    expect_failure install_packages "$PACKAGE_DIR" > "$CASE_DIR/output"
    [[ ! -s "$COMMAND_LOG" ]] || fail 'mimic 预检失败仍执行了安装'
    MOCK_DKMS_STATUS=''
    mkdir -p "$DKMS_STATE_DIR/mimic/0.7.1"
    assert_compatible_dkms
    rmdir "$DKMS_STATE_DIR/mimic/0.7.1"
    MOCK_DKMS_FAILURE=1
    expect_failure assert_compatible_dkms > "$CASE_DIR/output"
    MOCK_DKMS_FAILURE=0
    MOCK_AUDIT='linux-image is half-configured'
    expect_failure install_packages "$PACKAGE_DIR" > "$CASE_DIR/output"
    MOCK_AUDIT=''
    MOCK_PACKAGE_ARCH='arm64'
    expect_failure install_packages "$PACKAGE_DIR" > "$CASE_DIR/output"
    [[ ! -s "$COMMAND_LOG" ]] || fail '包/系统预检失败仍执行了安装'
)

test_azure_requires_drivers_before_install() (
    setup_fixture
    MOCK_HYPERV=1
    printf 'CONFIG_BLK_DEV_SD=y\n' > "$CASE_DIR/payload/boot/config-$RELEASE"
    tar -cf "$CASE_DIR/payload.tar" -C "$CASE_DIR/payload" .
    expect_failure install_packages "$PACKAGE_DIR" > "$CASE_DIR/output"
    [[ ! -s "$COMMAND_LOG" ]] || fail 'Azure 缺驱动仍执行了安装'
)

test_azure_vmbus_config_versions() (
    setup_fixture
    MOCK_HYPERV=1
    KERNEL_PACKAGE_RELEASE='7.2.10-joeyblog-bbrv3'
    sed '/CONFIG_HYPERV_VMBUS=/d' "$CASE_DIR/payload/boot/config-$RELEASE" > "$CASE_DIR/no-vmbus.config"
    cat "$CASE_DIR/no-vmbus.config" > "$CASE_DIR/disabled-vmbus.config"
    echo '# CONFIG_HYPERV_VMBUS is not set' >> "$CASE_DIR/disabled-vmbus.config"
    expect_failure assert_cloud_kernel_config "$CASE_DIR/disabled-vmbus.config" > "$CASE_DIR/output"
    KERNEL_PACKAGE_RELEASE='6.1.0-joeyblog-bbrv3'
    assert_cloud_kernel_config "$CASE_DIR/no-vmbus.config"
)

test_package_pair_must_be_complete_and_match() (
    setup_fixture
    rm "$PACKAGE_DIR/linux-headers-$RELEASE.deb"
    expect_failure install_packages "$PACKAGE_DIR" > "$CASE_DIR/output"
    touch "$PACKAGE_DIR/linux-headers-7.2.8-joeyblog-bbrv3.deb"
    expect_failure install_packages "$PACKAGE_DIR" > "$CASE_DIR/output"
    [[ ! -s "$COMMAND_LOG" ]] || fail '缺 headers 或版本错配仍执行了安装'
)

test_azure_checks_modular_drivers_in_initramfs() (
    setup_fixture
    MOCK_HYPERV=1
    printf '%s\n' 'CONFIG_HYPERV=m' 'CONFIG_HYPERV_VMBUS=m' 'CONFIG_HYPERV_STORAGE=m' \
        'CONFIG_HYPERV_NET=m' 'CONFIG_PCI_HYPERV=m' 'CONFIG_BLK_DEV_SD=y' > "$CASE_DIR/payload/boot/config-$RELEASE"
    tar -cf "$CASE_DIR/payload.tar" -C "$CASE_DIR/payload" .
    expect_failure install_packages "$PACKAGE_DIR" > "$CASE_DIR/output"
    assert_original_boot
    printf '%s\n' 'usr/lib/modules/kernel/hv_vmbus.ko.zst' 'usr/lib/modules/kernel/hv_storvsc.ko.xz' \
        'usr/lib/modules/kernel/hv_netvsc.ko' 'usr/lib/modules/kernel/pci-hyperv.ko.gz' > "$CASE_DIR/modules"
    install_packages "$PACKAGE_DIR" <<< n > "$CASE_DIR/output"
    [[ "$(cat "$BOOT_DIR/grub/grub.cfg")" == updated-grub ]] || fail '安全安装后未更新 GRUB'
    ! grep -q reboot "$COMMAND_LOG" || fail '拒绝重启后仍执行了重启'
)

test_success_preserves_old_kernel_and_requires_reboot() (
    setup_fixture
    install_packages "$PACKAGE_DIR" <<< n > "$CASE_DIR/output"
    [[ -s "$BOOT_DIR/vmlinuz-old" ]] || fail '成功安装删除了旧内核'
    grep -q '当前仍在运行' "$CASE_DIR/output" || fail '未区分安装成功与实际运行'
    ! grep -q 'reboot\|apt-get' "$COMMAND_LOG" || fail '未授权重启或删除了旧内核'
)

test_ipv6_connection_protection() (
    setup_fixture
    SSH_CONNECTION='2001:db8::1 12345 2001:db8::2 22'
    expect_failure disable_ipv6 > "$CASE_DIR/output"
    [[ ! -f "$IPV6_CONF" && ! -s "$COMMAND_LOG" ]] || fail 'IPv6 SSH 被修改'
    SSH_CONNECTION=''
    SSH_CLIENT='2001:db8::1 12345 22'
    expect_failure disable_ipv6 > "$CASE_DIR/output"
    SSH_CLIENT=''
    MOCK_IPV4_ROUTE=''
    expect_failure disable_ipv6 > "$CASE_DIR/output"
    [[ ! -f "$IPV6_CONF" && ! -s "$COMMAND_LOG" ]] || fail '无 IPv4 出口仍禁用了 IPv6'
)

test_ipv6_disable_and_restore_own_config() (
    setup_fixture
    echo 'net.ipv6.bindv6only = 1' > "$CASE_DIR/admin.conf"
    disable_ipv6 <<< n > "$CASE_DIR/output"
    [[ ! -f "$IPV6_CONF" ]] || fail '取消后仍写了 IPv6 配置'
    disable_ipv6 <<< y > "$CASE_DIR/output"
    grep -q 'net.ipv6.conf.all.disable_ipv6 = 1' "$IPV6_CONF" || fail '未持久禁用 IPv6'
    [[ "$(cat "$IPV6_PROC_DIR/all/disable_ipv6")" == 1 ]] || fail 'IPv6 未即时禁用'
    cp "$IPV6_STATE_FILE" "$CASE_DIR/initial-snapshot"
    disable_ipv6 <<< y > "$CASE_DIR/output"
    cmp "$IPV6_STATE_FILE" "$CASE_DIR/initial-snapshot" || fail '重复禁用覆盖原始状态'
    mkdir -p "$IPV6_PROC_DIR/new0"
    echo 1 > "$IPV6_PROC_DIR/new0/disable_ipv6"
    rm -r "$IPV6_PROC_DIR/eth0"
    MOCK_RESTORE_FAILURE=1
    expect_failure restore_ipv6 > "$CASE_DIR/output"
    [[ -f "$IPV6_STATE_FILE" ]] || fail '恢复失败丢失重试快照'
    MOCK_RESTORE_FAILURE=0
    restore_ipv6 > "$CASE_DIR/output"
    [[ ! -f "$IPV6_CONF" && ! -f "$IPV6_STATE_FILE" && "$(cat "$IPV6_PROC_DIR/all/disable_ipv6")" == 0 ]] || fail 'IPv6 未恢复'
    [[ "$(cat "$IPV6_PROC_DIR/a0/disable_ipv6")" == 1 ]] || fail '管理员原有接口禁用状态丢失'
    [[ "$(cat "$IPV6_PROC_DIR/new0/disable_ipv6")" == 0 ]] || fail '新接口未沿用原 default'
    grep -q 'a0' "$CASE_DIR/output" || fail '未提示仍禁用的接口'
    [[ "$(cat "$CASE_DIR/admin.conf")" == 'net.ipv6.bindv6only = 1' ]] || fail '修改了管理员的 IPv6 配置'
)

test_real_deb_package_metadata() (
    if ! command -v dpkg-deb >/dev/null 2>&1; then
        echo '跳过：宿主机没有 dpkg-deb；Linux CI 执行真实 deb 校验。'
        return 0
    fi
    local fixture_dir release host_arch package_name root_dir
    fixture_dir=$(mktemp -d "$TEST_DIR/real-deb.XXXXXX")
    release='7.3.1-joeyblog-bbrv3'
    host_arch=$(dpkg --print-architecture)
    mkdir -p "$fixture_dir/packages"
    for package_name in "linux-image-$release" "linux-headers-$release"; do
        root_dir="$fixture_dir/$package_name"
        mkdir -p "$root_dir/DEBIAN" "$root_dir/boot" "$root_dir/usr/share/test-payload"
        printf 'Package: %s\nVersion: 7.3.1-1\nArchitecture: %s\nMaintainer: 测试 <test@example.invalid>\nDescription: 安装脚本回归测试\n' \
            "$package_name" "$host_arch" > "$root_dir/DEBIAN/control"
        echo CONFIG_HYPERV=y > "$root_dir/boot/config-$release"
        # 配置后还有大量载荷，确保 tar 消费完整流，不产生 SIGPIPE 假失败。
        dd if=/dev/zero of="$root_dir/usr/share/test-payload/trailing-data" bs=1024 count=2048 2>/dev/null
        dpkg-deb --build "$root_dir" "$fixture_dir/packages/$package_name.deb" >/dev/null
    done
    is_hyperv_system() { return 1; }
    validate_kernel_packages "$fixture_dir/packages"
    [[ "$KERNEL_PACKAGE_RELEASE" == "$release" ]] || fail '真实 deb 版本解析错误'
    [[ "${#KERNEL_DEB_FILES[@]}" == 2 ]] || fail '真实 deb 配对失败'
    grep -qx CONFIG_HYPERV=y "$fixture_dir/packages/kernel.config" || fail '真实 deb 配置提取失败'
)

test_download_filters_and_isolates_packages() (
    if ! command -v jq >/dev/null 2>&1; then
        echo '跳过：宿主机没有 jq。'
        return 0
    fi
    local download_log fixture_dir release_json
    fixture_dir=$(mktemp -d "$TEST_DIR/download.XXXXXX")
    download_log="$fixture_dir/downloads"
    : > "$download_log"
    release_json='[{"tag_name":"x86_64-7.3.1","assets":[
      {"name":"linux-image-7.3.1-joeyblog-bbrv3_7.3.1-1_amd64.deb","browser_download_url":"https://example.invalid/linux-image-7.3.1-joeyblog-bbrv3_7.3.1-1_amd64.deb"},
      {"name":"linux-headers-7.3.1-joeyblog-bbrv3_7.3.1-1_amd64.deb","browser_download_url":"https://example.invalid/linux-headers-7.3.1-joeyblog-bbrv3_7.3.1-1_amd64.deb"},
      {"name":"linux-image-7.3.1-joeyblog-bbrv3-dbg_7.3.1-1_amd64.deb","browser_download_url":"https://example.invalid/debug.deb"},
      {"name":"linux-libc-dev_7.3.1-1_amd64.deb","browser_download_url":"https://example.invalid/libc.deb"},
      {"name":"x86_64-7.3.1.config","browser_download_url":"https://example.invalid/kernel.config"}]}]'
    wget() { printf '%s\n' "$3" >> "$download_log"; [[ "$4" == -O ]] || return 1; touch "$5"; }
    install_packages() {
        [[ "$1" == */bbrv3.* ]] || fail '未使用独立临时目录'
        [[ "$(find "$1" -name '*.deb' | wc -l | tr -d ' ')" == 2 ]] || fail '下载了非内核包'
        printf '%s\n' "$1" > "$fixture_dir/package-dir"
    }
    download_and_install_release "$release_json" x86_64-7.3.1 >/dev/null
    [[ "$(wc -l < "$download_log" | tr -d ' ')" == 2 ]] || fail '下载筛选错误'
    ! grep -q 'libc\|debug\|config' "$download_log" || fail '下载了无关文件'
    [[ ! -e "$(cat "$fixture_dir/package-dir")" ]] || fail '下载目录未清理'
)

for test_name in \
    test_failed_install_preserves_old_kernel \
    test_missing_initramfs_and_grub_failure \
    test_preflight_rejects_incompatible_system \
    test_azure_requires_drivers_before_install \
    test_azure_vmbus_config_versions \
    test_package_pair_must_be_complete_and_match \
    test_azure_checks_modular_drivers_in_initramfs \
    test_success_preserves_old_kernel_and_requires_reboot \
    test_ipv6_connection_protection \
    test_ipv6_disable_and_restore_own_config \
    test_real_deb_package_metadata \
    test_download_filters_and_isolates_packages; do
    "$test_name"
    echo "通过：$test_name"
done
