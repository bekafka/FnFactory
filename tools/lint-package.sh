#!/bin/bash
# ==============================================================================
# 打包规范门禁：在 CI 里对应用包的模板做结构检查。
#
#   tools/lint-package.sh <package-template-dir>   # 例如 packaging/MyApp
#
# 只检查"规范里写成硬性要求"的部分，风格问题不管。任何一条不过就 exit 1。
# 规范：specs/uninstall.md、specs/lifecycle.md、specs/acceptance.md
# ==============================================================================
set -u
DIR="${1:-}"
FAIL=0

pass() { printf '  [PASS] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf '  [SKIP] %s\n' "$1"; }

[ -n "$DIR" ] && [ -d "$DIR" ] || { echo "usage: $0 <package-template-dir>" >&2; exit 2; }

echo "== 包结构：$DIR"

# ── 1. 必需文件 ───────────────────────────────────────────────────────────────
for f in manifest cmd/main config/privilege config/resource; do
  [ -f "$DIR/$f" ] && pass "存在 $f" || fail "缺少 $f"
done

# ── 2. 生命周期脚本语法 ──────────────────────────────────────────────────────
for f in cmd/main cmd/install_callback cmd/config_callback cmd/upgrade_callback cmd/uninstall_callback; do
  [ -f "$DIR/$f" ] || { skip "没有 $f（可接受，但 uninstall_callback 建议有）"; continue; }
  bash -n "$DIR/$f" 2>/dev/null && pass "$f 语法通过" || fail "$f 有语法错误"
done

# ── 3. 卸载规范（specs/uninstall.md）────────────────────────────────────────
uninst="$DIR/cmd/uninstall_callback"
if [ -f "$uninst" ]; then
  grep -q 'wizard_uninstall_mode:-keep' "$uninst" \
    && pass "卸载默认保留（keep）" \
    || fail "uninstall_callback 默认值不是 keep（必须是 \${wizard_uninstall_mode:-keep}）"
  grep -q '/vol1/@appdata/\*' "$uninst" \
    && pass "purge 有路径护栏" \
    || fail "uninstall_callback 缺少 /vol1/@appdata/* 路径护栏"
  grep -q 'TRIM_TEMP_LOGFILE' "$uninst" \
    && pass "卸载日志写 TRIM_TEMP_LOGFILE" \
    || fail "卸载日志应写 TRIM_TEMP_LOGFILE（purge 会删掉 info.log）"
else
  fail "缺少 cmd/uninstall_callback（有状态的应用必须提供卸载方式）"
fi

wiz="$DIR/wizard/uninstall"
if [ -f "$wiz" ]; then
  if python3 - "$wiz" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
items = [i for step in data for i in step.get("items", [])]
radio = [i for i in items if i.get("field") == "wizard_uninstall_mode"]
assert radio, "缺少 field=wizard_uninstall_mode 的表单项"
r = radio[0]
assert r.get("type") == "radio", "wizard_uninstall_mode 必须是 radio"
assert r.get("initValue") == "keep", "默认值必须是 keep"
values = [o.get("value") for o in r.get("options", [])]
assert "keep" in values and "purge" in values, f"选项需同时包含 keep/purge，实际 {values}"
PY
  then pass "卸载向导结构正确（radio / keep 默认 / keep+purge）"; else fail "卸载向导 JSON 不符合规范"; fi
else
  fail "缺少 wizard/uninstall（有状态的应用必须给用户选择）"
fi

# ── 4. 生命周期规范（specs/lifecycle.md）────────────────────────────────────
main="$DIR/cmd/main"
if [ -f "$main" ]; then
  grep -q 'readlink "/proc/' "$main" && pass "cmd/main 做了 /proc/<pid>/exe 身份校验" \
    || fail "cmd/main 没有 /proc/<pid>/exe 身份校验（会把死进程当成 running）"
  # 只看可执行行（行首非 #），注释里提到这个词不算
  if grep -qE '^[[:space:]]*[^#].*pgrep[[:space:]]+-x[[:space:]]+node' "$main"; then
    fail "cmd/main 使用了 pgrep -x node（飞牛上 comm=MainThread，匹配不到）"
  else
    pass "未使用 pgrep -x node"
  fi
  grep -q 'find_orphans\|/proc/\$pid/exe\|/proc/\$p/exe\|ls /proc' "$main" \
    && pass "有 /proc 遍历的孤儿兜底" \
    || fail "cmd/main 没有孤儿清扫逻辑"
  grep -q 'info.log.1' "$main" && pass "日志轮转已实现" || skip "没有日志轮转（长时间运行前建议加）"
  grep -q 'healthz\|/health' "$main" && pass "有健康端点探测" || skip "就绪判据不是健康端点"
fi

# ── 5. 配置与向导 ───────────────────────────────────────────────────────────
if [ -f "$DIR/manifest" ]; then
  grep -q 'install_dep_apps' "$DIR/manifest" && pass "manifest 声明了 install_dep_apps" || skip "未依赖官方运行时"
fi
if [ -f "$DIR/wizard/install" ]; then
  if python3 - "$DIR/wizard/install" <<'PY'
import json, sys
items = [i for step in json.load(open(sys.argv[1])) for i in step.get("items", [])]
ports = [i for i in items if i.get("field") == "wizard_port"]
assert ports, "没有 wizard_port 字段"
v = str(ports[0].get("initValue", ""))
assert v.isdigit(), f"wizard_port 默认值不是数字：{v!r}"
assert v not in {"8080", "8000", "3000", "5000"}, f"默认端口 {v} 是热门端口，容易冲突"
PY
  then pass "安装向导：端口字段有非热门默认值"; else fail "安装向导端口默认值不合规（缺字段 / 非数字 / 热门端口）"; fi
fi

echo
if [ "$FAIL" -eq 0 ]; then echo "== 规范检查通过"; else echo "== 规范检查失败：$FAIL 项"; exit 1; fi
