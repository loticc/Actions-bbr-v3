#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

required_symbols=(
  HYPERV HYPERV_VMBUS HYPERV_STORAGE HYPERV_NET PCI_HYPERV PCI_HYPERV_INTERFACE
  PCI PCI_MSI SYSFS ACPI BLOCK SCSI SCSI_LOWLEVEL SCSI_FC_ATTRS BLK_DEV_SD
  NET NETDEVICES NET_CORE NVME_CORE BLK_DEV_NVME
)

assert_cloud_config() {
  local config_file=$1 symbol
  for symbol in "${required_symbols[@]}"; do
    if [ "${2:-modern}" = legacy ] && [ "$symbol" = HYPERV_VMBUS ]; then
      continue
    fi
    if ! grep -qx "CONFIG_${symbol}=y" "$config_file"; then
      echo "失败：${config_file} 缺少内置 CONFIG_${symbol}" >&2
      exit 1
    fi
  done
  if grep -q '^CONFIG_HYPERV_VTL_MODE=' "$config_file"; then
    echo "失败：普通云主机不能启用 HYPERV_VTL_MODE" >&2
    exit 1
  fi
}

# 在隔离目录执行真正的准备脚本；替身只写配置和模拟 olddefconfig 丢失选项。
# 真实 Kconfig 的依赖求解仍须由构建矩阵中的 olddefconfig 验证。
mkdir -p "$test_dir/bin" "$test_dir/kernel/scripts" "$test_dir/kernel/drivers/hv" "$test_dir/workspace"
printf 'config HYPERV_VMBUS\n\ttristate "VMBus"\n' > "$test_dir/kernel/drivers/hv/Kconfig"
cat > "$test_dir/kernel/scripts/config" <<'PY'
#!/usr/bin/env python3
import pathlib
import sys

option, symbol, *arguments = sys.argv[1:]
key = "CONFIG_" + symbol
values = {"--enable": "y", "--module": "m", "--disable": None}
value = '"' + arguments[0] + '"' if option == "--set-str" else values[option]
path = pathlib.Path(".config")
lines = [line for line in path.read_text().splitlines()
         if not line.startswith(key + "=") and line != "# " + key + " is not set"]
lines.append(key + "=" + value if value is not None else "# " + key + " is not set")
path.write_text("\n".join(lines) + "\n")
PY
cat > "$test_dir/bin/make" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
symbol=${DROP_SYMBOL:-}
if ! grep -q '^config HYPERV_VMBUS$' drivers/hv/Kconfig; then
  symbol=HYPERV_VMBUS
fi
if [ -n "$symbol" ]; then
  awk -v key="CONFIG_${symbol}=" 'index($0, key) != 1' .config > .config.tmp
  mv .config.tmp .config
fi
SH
cat > "$test_dir/bin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
chmod +x "$test_dir/kernel/scripts/config" "$test_dir/bin/make" "$test_dir/bin/timeout"

for arch in x86_64 arm64; do
  baseline=x86-64.config
  if [ "$arch" = arm64 ]; then baseline=arm64.config; fi
  assert_cloud_config "$repo_dir/$baseline"

  # 故意不给云驱动，并放入普通云主机不应启用的模式，验证策略完整补齐。
  printf 'CONFIG_HYPERV_VTL_MODE=y\nCONFIG_CPU_BIG_ENDIAN=y\n' > "$test_dir/workspace/$baseline"
  if ! (cd "$test_dir/kernel" && PATH="$test_dir/bin:$PATH" \
    GITHUB_WORKSPACE="$test_dir/workspace" KERNEL_VERSION=test \
    bash "$repo_dir/scripts/prepare-kernel-config.sh" "$arch") > "$test_dir/prepare.log" 2>&1; then
    cat "$test_dir/prepare.log" >&2
    exit 1
  fi
  assert_cloud_config "$test_dir/workspace/build-configs/$arch.config"
  if [ "$arch" = x86_64 ]; then
    grep -qx CONFIG_HYPERVISOR_GUEST=y "$test_dir/kernel/.config"
    grep -qx CONFIG_X86_LOCAL_APIC=y "$test_dir/kernel/.config"
  fi

  for symbol in HYPERV HYPERV_VMBUS HYPERV_STORAGE HYPERV_NET PCI_HYPERV BLK_DEV_NVME; do
    if (cd "$test_dir/kernel" && PATH="$test_dir/bin:$PATH" \
      GITHUB_WORKSPACE="$test_dir/workspace" KERNEL_VERSION=test DROP_SYMBOL="$symbol" \
      bash "$repo_dir/scripts/prepare-kernel-config.sh" "$arch") > "$test_dir/reject.log" 2>&1; then
      echo "失败：${arch} 在 olddefconfig 移除 CONFIG_${symbol} 后仍继续构建" >&2
      exit 1
    fi
    grep -q "ERROR:.*CONFIG_${symbol}" "$test_dir/reject.log"
  done
  # 旧内核没有独立 VMBus 符号，仍须能通过核心/存储/网络校验。
  printf 'config HYPERV\n\ttristate "Hyper-V"\n' > "$test_dir/kernel/drivers/hv/Kconfig"
  if ! (cd "$test_dir/kernel" && PATH="$test_dir/bin:$PATH" \
    GITHUB_WORKSPACE="$test_dir/workspace" KERNEL_VERSION=test \
    bash "$repo_dir/scripts/prepare-kernel-config.sh" "$arch") > "$test_dir/legacy.log" 2>&1; then
    cat "$test_dir/legacy.log" >&2
    exit 1
  fi
  assert_cloud_config "$test_dir/workspace/build-configs/$arch.config" legacy
  printf 'config HYPERV_VMBUS\n\ttristate "VMBus"\n' > "$test_dir/kernel/drivers/hv/Kconfig"
  echo "通过：${arch} 云驱动策略与 olddefconfig 降级拦截"
done
