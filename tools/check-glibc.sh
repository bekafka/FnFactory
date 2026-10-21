#!/bin/bash
# ==============================================================================
# 检查 payload 内 ELF 文件要求的最高 GLIBC 版本是否 <= 目标基线。
#
#   tools/check-glibc.sh <max-version> <payload-dir>
#   tools/check-glibc.sh 2.36 build_workspace/MyApp/app
#
# 背景：fnOS 1.x 实测为 Debian 12.12 / glibc 2.36（libc6 2.36-9+deb12u13）。
# 在 Ubuntu 24.04（glibc 2.39）上构建带 CGO/原生模块的产物，可能在设备上报
# `GLIBC_2.39 not found`。纯静态 Go（CGO_ENABLED=0）不会出现在这个检查里。
# ==============================================================================
set -euo pipefail

MAX="${1:-}"
PAYLOAD="${2:-}"

[ -n "$MAX" ] && [ -d "$PAYLOAD" ] || {
  echo "usage: $0 <max-version> <payload-dir>" >&2
  exit 2
}

command -v readelf >/dev/null 2>&1 || {
  echo "::error::缺少 readelf（binutils），无法检查 GLIBC 版本" >&2
  exit 2
}
command -v file >/dev/null 2>&1 || {
  echo "::error::缺少 file，无法识别 ELF" >&2
  exit 2
}

FAIL=0
CHECKED=0
HIGHEST=""
HIGHEST_FILE=""

while IFS= read -r -d '' f; do
  file -b "$f" 2>/dev/null | grep -q 'ELF' || continue
  CHECKED=$((CHECKED + 1))

  # readelf 输出里可能有多个 GLIBC_2.x；按版本排序取最高
  versions=$(readelf --version-info "$f" 2>/dev/null \
    | grep -o 'GLIBC_[0-9][0-9.]*' | sort -Vu || true)
  [ -n "$versions" ] || continue
  high=$(printf '%s\n' "$versions" | tail -1)
  [ -n "$high" ] || continue
  high="${high#GLIBC_}"

  if [ -z "$HIGHEST" ] || [ "$(printf '%s\n%s\n' "$HIGHEST" "$high" | sort -V | tail -1)" = "$high" ]; then
    HIGHEST="$high"
    HIGHEST_FILE="$f"
  fi

  if [ "$(printf '%s\n%s\n' "$MAX" "$high" | sort -V | tail -1)" != "$MAX" ]; then
    echo "::error::$f 需要 GLIBC_$high，高于目标基线 $MAX" >&2
    FAIL=1
  fi
done < <(find "$PAYLOAD" -type f -print0)

if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: payload 有 ELF 高于 glibc $MAX；请改用 Debian 12 / Ubuntu 22.04 构建，或使用静态链接。" >&2
  exit 1
fi

echo "✓ glibc 检查通过：$CHECKED 个 ELF，最高 GLIBC_${HIGHEST:-（无动态 ELF）} <= $MAX"
[ -n "$HIGHEST_FILE" ] && echo "  最高文件：${HIGHEST_FILE#$PAYLOAD/}"
exit 0
