#!/bin/bash
# FnFactory 自身回归测试（不依赖 GitHub Actions）。
# 用法：bash tests/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; }
section() { printf '\n== %s ==\n' "$1"; }

# ── 1. shell 语法 ────────────────────────────────────────────────────────────
section "shell 语法"
while IFS= read -r -d '' f; do
  if bash -n "$f" 2>/dev/null; then
    ok "bash -n ${f#"$ROOT"/}"
  else
    bad "bash -n ${f#"$ROOT"/}"
  fi
done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -type f \
  \( -name '*.sh' -o -name '*.sh.example' -o -path "$ROOT/templates/cmd/*" -o -path "$ROOT/templates/tests/accept.sh" \) -print0)

# ── 2. YAML / JSON ───────────────────────────────────────────────────────────
section "YAML / JSON"
if python3 - "$ROOT" <<'PY'
import glob, sys
import yaml
root = sys.argv[1]
files = sorted(glob.glob(root + "/.github/workflows/*.yml") + glob.glob(root + "/examples/*.yml"))
for path in files:
    yaml.safe_load(open(path, encoding="utf-8"))
    print("yaml ok:", path)
PY
then ok "workflow/example YAML 可解析"; else bad "workflow/example YAML 解析失败"; fi

for f in "$ROOT/templates/wizard/uninstall" "$ROOT/tests/fixtures/Fixture/package/wizard/uninstall" \
         "$ROOT/tests/fixtures/Fixture/package/wizard/install" \
         "$ROOT/tests/fixtures/Fixture/package/config/privilege" \
         "$ROOT/tests/fixtures/Fixture/package/config/resource" \
         "$ROOT/tests/fixtures/Fixture/package/app/ui/config"; do
  if python3 -m json.tool "$f" >/dev/null 2>&1; then
    ok "JSON ${f#"$ROOT"/}"
  else
    bad "JSON ${f#"$ROOT"/}"
  fi
done

# ── 3. lint：正例 + 反例 ─────────────────────────────────────────────────────
section "lint-package.sh"
if bash "$ROOT/tools/lint-package.sh" "$ROOT/tests/fixtures/Fixture/package" >/dev/null 2>&1; then
  ok "真实结构 fixture 通过"
else
  bad "真实结构 fixture 应通过但失败了"
fi

mkdir -p "$TMP/apps/Fixture"
cp -r "$ROOT/tests/fixtures/Fixture/package" "$TMP/apps/Fixture/package"
python3 - "$TMP/apps/Fixture/package/cmd/uninstall_callback" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace("""    case "$PKGVAR" in
      /vol1/@appdata/*)""", """    case "$PKGVAR" in
      *)""")
open(path, "w", encoding="utf-8").write(text)
PY
if bash "$ROOT/tools/lint-package.sh" "$TMP/apps/Fixture/package" >/tmp/fnfaudit-lint-bad.log 2>&1; then
  bad "删掉实际路径护栏后 lint 仍然 PASS"
else
  if grep -q '路径护栏' /tmp/fnfaudit-lint-bad.log; then
    ok "删掉实际路径护栏后 lint FAIL（注释不能绕过）"
  else
    bad "lint 失败了，但不是因为路径护栏"
  fi
fi

# ── 4. scaffold：路径 / 默认值 / 配置加载 ────────────────────────────────────
section "scaffold-lifecycle.sh"
mkdir -p "$TMP/apps/MyApp/package"
touch "$TMP/apps/MyApp/package/manifest"
if bash "$ROOT/tools/scaffold-lifecycle.sh" \
  --pkg-dir "$TMP/apps/MyApp/package" --app MyApp --prefix MYAPP --port 26999 \
  --mode entry --entry dist/server/index.mjs \
  --runtime-bin /var/apps/nodejs_v24/target/bin/node \
  --own-bins 'bin/helper' >/tmp/fnfaudit-scaffold.log 2>&1; then
  ok "scaffold 生成成功"
else
  bad "scaffold 生成失败"
fi

if [ -f "$TMP/apps/MyApp/tests/accept.sh" ] && [ ! -e "$TMP/apps/tests/accept.sh" ]; then
  ok "accept.sh 落在 apps/MyApp/tests/"
else
  bad "accept.sh 路径不对（期望 apps/MyApp/tests/accept.sh）"
fi

printf 'MYAPP_PORT=27777\nMYAPP_MAX_OLD_SPACE=640\nMYAPP_FIX_PERMISSIONS=0\n' \
  > "$TMP/apps/MyApp/package/config.env"
{
  echo 'set -u'
  echo 'PREFIX=MYAPP'
  echo 'DEFAULT_PORT=26999'
  echo "CONF='$TMP/apps/MyApp/package/config.env'"
  echo 'log_msg() { :; }'
  sed -n '/^load_config()/,/^}/p' "$TMP/apps/MyApp/package/cmd/main"
  echo 'load_config'
  echo 'printf "%s|%s|%s\n" "$PORT" "$MAX_OLD_SPACE" "$FIX_PERMISSIONS"'
} > "$TMP/porttest.sh"
out="$(bash "$TMP/porttest.sh")"
if [ "$out" = "27777|640|0" ]; then
  ok "config.env 的 PREFIX_* 生效（PORT/MAX_OLD_SPACE/FIX_PERMISSIONS）"
else
  bad "config.env 未被正确读取：$out"
fi

mkdir -p "$TMP/apps/BinApp/package"
touch "$TMP/apps/BinApp/package/manifest"
if bash "$ROOT/tools/scaffold-lifecycle.sh" \
  --pkg-dir "$TMP/apps/BinApp/package" --app BinApp --prefix BINAPP --port 26998 \
  --mode binary >/dev/null 2>&1; then
  bad "--mode binary 缺 --own-bins 仍然成功"
else
  ok "--mode binary 缺 --own-bins 被拒绝"
fi

# 卸载 callback：.. 不得越出 PKGVAR；正常 state path 仍可删
cp "$TMP/apps/MyApp/package/cmd/uninstall_callback" "$TMP/uninstall.sh"
sed -i "s#/vol1/@appdata/\*#${TMP}/*#" "$TMP/uninstall.sh"
sed -i 's/for rel in data home tmp config.env/for rel in ..\/victim data/' "$TMP/uninstall.sh"
mkdir -p "$TMP/pkgvar/data"
printf 'keep\n' > "$TMP/victim"
TRIM_PKGVAR="$TMP/pkgvar" TRIM_TEMP_LOGFILE="$TMP/uninstall.log" \
  wizard_uninstall_mode=purge bash "$TMP/uninstall.sh" >/dev/null 2>&1
if [ -e "$TMP/victim" ]; then
  ok "uninstall_callback 拒绝 ../victim 路径穿越"
else
  bad "uninstall_callback 删除了 PKGVAR 之外的文件"
fi
if [ -e "$TMP/pkgvar/data" ]; then
  bad "uninstall_callback 没有删除合法 state path"
else
  ok "uninstall_callback 删除合法 state path"
fi

# ── 5. 验收模板：六阶阶段齐全 ────────────────────────────────────────────────
section "acceptance 模板"
if grep -q '^stage_auth()' "$ROOT/templates/tests/accept.sh" && \
   grep -q 'stage_auth;' "$ROOT/templates/tests/accept.sh"; then
  ok "accept.sh 有鉴权阶段并接入 all"
else
  bad "accept.sh 缺鉴权阶段"
fi
if grep -q 'stage_e2e 未实现' "$ROOT/templates/tests/accept.sh"; then
  ok "accept.sh 的 e2e 未实现会强制 FAIL"
else
  bad "accept.sh 缺少 e2e 未实现标记"
fi

# ── 6. glibc 基线检查 ─────────────────────────────────────────────────────────
section "glibc 基线"
mkdir -p "$TMP/glibc-payload"
cp /bin/true "$TMP/glibc-payload/true"
if bash "$ROOT/tools/check-glibc.sh" 2.0 "$TMP/glibc-payload" >/dev/null 2>&1; then
  bad "glibc 2.0 的基线应失败"
else
  ok "glibc 基线能拦截高于目标版本的 ELF"
fi
if bash "$ROOT/tools/check-glibc.sh" 99 "$TMP/glibc-payload" >/dev/null 2>&1; then
  ok "glibc 基线放行低于目标版本的 ELF"
else
  bad "glibc 基线误杀了低版本 ELF"
fi

# ── 7. manifest 渲染：多行 changelog + fnpack 真打包 ─────────────────────────
section "manifest / fnpack"
mkdir -p "$TMP/render"
cp -r "$ROOT/tests/fixtures/Fixture/package" "$TMP/render/Fixture"
if APP_KEY=Fixture VERSION=9.9.9 PLATFORM=x86 \
   CHANGELOG=$'* fix one\n* fix two & more / slash' \
   python3 "$ROOT/tools/render-manifest.py" "$TMP/render/Fixture/manifest" >/tmp/fnfaudit-render.log 2>&1; then
  ok "render-manifest.py 接受多行 changelog"
else
  bad "render-manifest.py 失败"
fi
if grep -q '^changelog             = \* fix one · \* fix two & more / slash$' "$TMP/render/Fixture/manifest"; then
  ok "changelog 被规范化为单行"
else
  bad "changelog 未规范化"
fi

if [ "$(uname -m)" = "x86_64" ] && [ -x "$ROOT/tools/fnpack-linux-amd64" ]; then
  ( cd "$TMP/render" && "$ROOT/tools/fnpack-linux-amd64" build Fixture >/tmp/fnfaudit-fnpack.log 2>&1 )
  rc=$?
  if [ "$rc" -eq 0 ] && grep -q 'Packing successfully' /tmp/fnfaudit-fnpack.log && [ -f "$TMP/render/Fixture.fpk" ]; then
    ok "fnpack 1.2.3 真实出包（多行 changelog 归一后）"
  else
    bad "fnpack 出包失败（rc=$rc）"
  fi
else
  echo "  [SKIP] 非 x86_64 或无 fnpack 二进制"
fi

# 反例：appname 与 app_key 不一致必须失败
mkdir -p "$TMP/render/bad"
cp -r "$ROOT/tests/fixtures/Fixture/package" "$TMP/render/bad/Fixture"
sed -i 's/^appname.*/appname               = Wrong/' "$TMP/render/bad/Fixture/manifest"
if APP_KEY=Fixture VERSION=9.9.9 PLATFORM=x86 CHANGELOG=x \
   python3 "$ROOT/tools/render-manifest.py" "$TMP/render/bad/Fixture/manifest" >/dev/null 2>&1; then
  bad "appname 不匹配时 render-manifest.py 仍然成功"
else
  ok "appname 不匹配时 render-manifest.py 失败"
fi

printf '\n=== 结果：PASS=%d FAIL=%d ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
