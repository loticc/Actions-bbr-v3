#!/usr/bin/env bash
set -euo pipefail

action="${1:?用法：kernel-source.sh <resolve|checkout> <版本> [源码目录] [预期提交]}"
version="${2:?缺少内核版本}"
remote="${KERNEL_GIT_URL:-https://github.com/gregkh/linux.git}"

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "无效的内核版本：$version" >&2
  exit 1
fi

# 首发版本的正式标签是 v7.3，不是 v7.3.0；不依赖尚未建立的 stable 分支。
raw_version="$version"
if [[ "$version" =~ ^[0-9]+\.[0-9]+\.0$ ]]; then
  raw_version="${version%.0}"
fi
ref="refs/tags/v$raw_version"

resolve_commit() {
  local refs commit
  refs=$(git ls-remote --exit-code --tags "$remote" "$ref" "$ref^{}") || {
    echo "找不到内核正式标签：$ref" >&2
    return 1
  }
  # 注解标签必须固定到解引用后的提交，而不是标签对象。
  commit=$(printf '%s\n' "$refs" | awk -v ref="$ref" '
    $2 == ref { tag = $1 }
    $2 == ref "^{}" { commit = $1 }
    END { print (commit != "" ? commit : tag) }
  ')
  if ! [[ "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    echo "无法解析标签提交：$ref" >&2
    return 1
  fi
  printf '%s\n' "$commit"
}

case "$action" in
  resolve)
    resolve_commit
    ;;
  checkout)
    destination="${3:?缺少源码目录}"
    expected_commit="${4:-$(resolve_commit)}"
    if ! [[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]]; then
      echo "无效的预期提交：$expected_commit" >&2
      exit 1
    fi
    if [[ -d "$destination" ]] && [[ -n "$(ls -A "$destination")" ]]; then
      echo "源码目录非空，请使用新的工作目录：$destination" >&2
      exit 1
    fi
    git init --quiet "$destination"
    git -C "$destination" remote add origin "$remote"
    git -C "$destination" fetch --quiet --depth=1 origin "$ref"
    actual_commit=$(git -C "$destination" rev-parse 'FETCH_HEAD^{commit}')
    if [[ "$actual_commit" != "$expected_commit" ]]; then
      echo "正式标签提交发生变化，停止构建：预期 $expected_commit，实际 $actual_commit" >&2
      exit 1
    fi
    git -C "$destination" checkout --quiet --detach "$actual_commit"

    actual_version=$(awk '
      /^VERSION[[:space:]]*=/ { v = $3 }
      /^PATCHLEVEL[[:space:]]*=/ { p = $3 }
      /^SUBLEVEL[[:space:]]*=/ { s = $3 }
      /^EXTRAVERSION[[:space:]]*=/ { extra = $3 }
      END { if (v != "" && p != "" && s != "" && extra == "") print v "." p "." s }
    ' "$destination/Makefile")
    normalized_version="$version"
    if [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
      normalized_version="$version.0"
    fi
    if [[ "$actual_version" != "$normalized_version" ]]; then
      echo "源码版本不匹配：预期 $normalized_version，实际 ${actual_version:-无法读取}" >&2
      exit 1
    fi
    echo "已检出 ${ref}（${actual_commit}），源码版本 ${actual_version}。"
    ;;
  *)
    echo "未知操作：$action" >&2
    exit 1
    ;;
esac
