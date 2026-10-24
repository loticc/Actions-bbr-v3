#!/usr/bin/env bash
set -euo pipefail

target=scripts/package/install-extmod-build
if [[ ! -f "$target" || ! -f .config ]]; then
  echo '请在准备好 .config 的内核源码目录运行打包准备脚本。' >&2
  exit 1
fi

# 上游精简的 headers 只带 auto.conf；DKMS 的配置/签名检查仍然读取 .config。
# 复制本次构建的配置，不能用仓库中其他内核版本的配置代替。
if ! grep -q 'BBRV3_HEADERS_CONFIG' "$target"; then
  cat >> "$target" <<'EOF'

# BBRV3_HEADERS_CONFIG：保留本次构建的完整配置供 DKMS 使用。
cp "${KCONFIG_CONFIG:-.config}" "${destdir}/.config"
EOF
fi
