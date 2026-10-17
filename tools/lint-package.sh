#!/bin/bash
# ==============================================================================
# 打包规范门禁：在 CI 里对应用包的模板做结构检查。
#
#   tools/lint-package.sh <package-template-dir>   # 例如 apps/MyApp/package
#
# 只检查"规范里写成硬性要求"的部分，风格问题不管。任何一条不过就 exit 1。
# 规范：specs/authorship.md、specs/uninstall.md、specs/lifecycle.md、specs/acceptance.md
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

# ── 6. 作者口径（specs/authorship.md）────────────────────────────────────────
# 三个作者：开发者 maintainer / 发布者 distributor / 源作者 source_author。
# 前两个固定写本仓库所有者；源作者指上游项目最初的创造者与权利源头。
# 换维护者时用环境变量覆盖，不要改脚本里的默认值。
OWNER="${FACTORY_OWNER:-bekafka}"
DEV_URL="${FACTORY_DEV_URL:-https://github.com/bekafka/FnDepot}"
PUB_URL="${FACTORY_PUB_URL:-https://github.com/bekafka/FnDepot}"

mval() {
  # 取 manifest 里某个键的第一处值，去掉首尾空白与包裹引号
  grep -E "^$1[[:space:]]*=" "$DIR/manifest" 2>/dev/null | head -1 \
    | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]+$//; s/^"(.*)"$/\1/'
}

if [ -f "$DIR/manifest" ]; then
  echo "== 作者口径（specs/authorship.md）"
  maint=$(mval maintainer);      maint_url=$(mval maintainer_url)
  dist=$(mval distributor);      dist_url=$(mval distributor_url)
  src=$(mval source_author);     src_url=$(mval source_author_url)

  [ "$maint" = "$OWNER" ] && pass "开发者 maintainer=$OWNER" \
    || fail "maintainer 应为 $OWNER，实际 ${maint:-缺失}"
  [ "$maint_url" = "$DEV_URL" ] && pass "开发者主页 maintainer_url=$DEV_URL" \
    || fail "maintainer_url 应为 $DEV_URL，实际 ${maint_url:-缺失}"
  [ "$dist" = "$OWNER" ] && pass "发布者 distributor=$OWNER" \
    || fail "distributor 应为 $OWNER，实际 ${dist:-缺失}"
  [ "$dist_url" = "$PUB_URL" ] && pass "发布仓库 distributor_url=$PUB_URL" \
    || fail "distributor_url 应为 $PUB_URL，实际 ${dist_url:-缺失}"

  case "$src" in
    ""|your-name|@*@|TODO*) fail "缺少源作者 source_author（上游项目最初的作者/组织）" ;;
    *) pass "源作者 source_author=$src" ;;
  esac

  if printf '%s' "$src_url" | grep -qE '^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/?$'; then
    pass "源作者项目页 source_author_url=$src_url"
    url_owner=$(printf '%s' "$src_url" | sed -E 's#^https://github\.com/([^/]+)/.*#\1#')
    if [ -n "$src" ] && [ "$src" != "$url_owner" ]; then
      fail "source_author（$src）与项目页 owner（$url_owner）不一致"
    fi
    if grep -E '^desc[[:space:]]*=' "$DIR/manifest" | head -1 | grep -qF "$src_url"; then
      pass "desc 里带源作者链接（应用中心可见）"
    else
      fail "desc 里没有源作者链接 $src_url（用户在应用中心看不到源作者）"
    fi
  else
    fail "source_author_url 必须是上游项目主页 https://github.com/<owner>/<repo>，实际 ${src_url:-缺失}"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then echo "== 规范检查通过"; else echo "== 规范检查失败：$FAIL 项"; exit 1; fi
