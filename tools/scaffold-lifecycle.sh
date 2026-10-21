#!/bin/bash
# ==============================================================================
# 把 FnFactory 的生命周期/卸载/验收模板拷进一个应用包，并替换占位符。
#
#   tools/scaffold-lifecycle.sh --pkg-dir apps/MyApp/package --app MyApp \
#     --prefix MYAPP --port 26800 --health /healthz \
#     --mode entry --entry dist/server/index.mjs \
#     --runtime-bin /var/apps/nodejs_v24/target/bin/node \
#     --launch 'exec "$RUNTIME_BIN" --max-old-space-size="${MAX_OLD_SPACE:-512}" "$ENTRY"' \
#     --own-bins 'bin/helper' \
#     --save-dir '/vol1/@appshare/MyApp/downloads' \
#     --state-paths 'data home tmp config.env'
#
# 规范：specs/lifecycle.md、specs/uninstall.md、specs/acceptance.md
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES="$FACTORY_DIR/templates"

PKG_DIR=""; APP=""; PREFIX=""; PORT=""; MODE="entry"; ENTRY=""
RUNTIME_BIN=""; LAUNCH=""; OWN_BINS=""; HEALTH="/healthz"; SAVE_DIR=""
STATE_PATHS="data home tmp config.env"; TESTS_DIR=""; FORCE=0; DRY=0

usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --pkg-dir)     PKG_DIR="${2:-}"; shift 2 ;;
    --app)         APP="${2:-}"; shift 2 ;;
    --prefix)      PREFIX="${2:-}"; shift 2 ;;
    --port)        PORT="${2:-}"; shift 2 ;;
    --mode)        MODE="${2:-}"; shift 2 ;;
    --entry)       ENTRY="${2:-}"; shift 2 ;;
    --runtime-bin) RUNTIME_BIN="${2:-}"; shift 2 ;;
    --launch)      LAUNCH="${2:-}"; shift 2 ;;
    --own-bins)    OWN_BINS="${2:-}"; shift 2 ;;
    --health)      HEALTH="${2:-}"; shift 2 ;;
    --save-dir)    SAVE_DIR="${2:-}"; shift 2 ;;
    --state-paths) STATE_PATHS="${2:-}"; shift 2 ;;
    --tests-dir)   TESTS_DIR="${2:-}"; shift 2 ;;
    --force)       FORCE=1; shift ;;
    --dry-run)     DRY=1; shift ;;
    -h|--help)     usage ;;
    *) echo "未知参数：$1" >&2; usage ;;
  esac
done

[ -n "$PKG_DIR" ] && [ -n "$APP" ] && [ -n "$PREFIX" ] && [ -n "$PORT" ] || {
  echo "缺少 --pkg-dir/--app/--prefix/--port" >&2; usage; }
[ -d "$PKG_DIR" ] || { echo "包目录不存在：$PKG_DIR" >&2; exit 2; }
case "$MODE" in entry|binary) ;; *) echo "--mode 只能是 entry 或 binary" >&2; exit 2 ;; esac
case "$APP" in
  ''|*[!A-Za-z0-9._-]*) echo "--app 只能包含字母、数字、点、下划线、连字符：$APP" >&2; exit 2 ;;
esac
case "$PREFIX" in
  ''|*[!A-Za-z0-9_]*) echo "--prefix 只能包含字母、数字、下划线：$PREFIX" >&2; exit 2 ;;
esac
case "$PORT" in
  ''|*[!0-9]*) echo "--port 必须是数字：$PORT" >&2; exit 2 ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || {
  echo "--port 必须在 1-65535：$PORT" >&2; exit 2; }

if [ "$MODE" = "binary" ]; then
  [ -n "$OWN_BINS" ] && [ "$OWN_BINS" != "." ] || {
    echo "--mode binary 必须给 --own-bins（例如 bin/helper）" >&2; exit 2; }
  [ -n "$LAUNCH" ] || LAUNCH='exec "$APPDEST/${OWN_BINS%% *}"'
else
  [ -n "$ENTRY" ] && [ "$ENTRY" != "." ] || {
    echo "--mode entry 必须给 --entry（例如 dist/server/index.mjs）" >&2; exit 2; }
  [ -n "$RUNTIME_BIN" ] || RUNTIME_BIN="/var/apps/nodejs_v24/target/bin/node"
  case "$RUNTIME_BIN" in /*) ;; *) echo "--runtime-bin 必须是绝对路径：$RUNTIME_BIN" >&2; exit 2 ;; esac
  [ -n "$LAUNCH" ] || LAUNCH='exec "$RUNTIME_BIN" "$ENTRY"'
fi
[ -n "$OWN_BINS" ] || OWN_BINS="."
[ -n "$TESTS_DIR" ] || TESTS_DIR="$(cd "$PKG_DIR/.." && pwd)/tests"

if [ "$DRY" = "1" ]; then
  echo "dry-run: 将写入"
  echo "  $PKG_DIR/cmd/{main,uninstall_init,uninstall_callback}"
  echo "  $PKG_DIR/wizard/uninstall"
  echo "  $TESTS_DIR/accept.sh"
  exit 0
fi

mkdir -p "$PKG_DIR/cmd" "$PKG_DIR/wizard" "$TESTS_DIR"

python3 - "$TEMPLATES" "$PKG_DIR" "$TESTS_DIR" "$APP" "$PREFIX" "$MODE" "$ENTRY" \
  "$RUNTIME_BIN" "$LAUNCH" "$OWN_BINS" "$HEALTH" "$PORT" "$SAVE_DIR" "$STATE_PATHS" "$FORCE" <<'PY'
import os, sys, json, pathlib

(tpl_dir, pkg_dir, tests_dir, app, prefix, mode, entry,
 runtime_bin, launch, own_bins, health, port, save_dir, state_paths, force) = sys.argv[1:16]

tpl_dir = pathlib.Path(tpl_dir)
pkg_dir = pathlib.Path(pkg_dir)
tests_dir = pathlib.Path(tests_dir)

save_dir = save_dir or f"/vol1/@appshare/{app}/downloads"
pkvar = f"/vol1/@appdata/{app}"

subs = {
    "@APPNAME@": app,
    "@PREFIX@": prefix.upper(),
    "@MODE@": mode,
    "@ENTRY@": entry,
    "@RUNTIME_BIN@": runtime_bin,
    "@LAUNCH@": launch,
    "@OWN_BINS@": own_bins,
    "@HEALTH_PATH@": health,
    "@DEFAULT_PORT@": str(port),
    "@SAVE_DIR@": save_dir,
    "@SAVE_DIRS@": save_dir,
    "@PKGVAR@": pkvar,
    "@PORT@": str(port),
    "@HEALTH@": health,
    "@USER_DATA_HINT@": save_dir,
    "@STATE_PATHS@": state_paths,
}

# 模板文件 → 目标路径
plan = [
    (tpl_dir / "cmd" / "main", pkg_dir / "cmd" / "main"),
    (tpl_dir / "cmd" / "uninstall_init", pkg_dir / "cmd" / "uninstall_init"),
    (tpl_dir / "cmd" / "uninstall_callback", pkg_dir / "cmd" / "uninstall_callback"),
    (tpl_dir / "wizard" / "uninstall", pkg_dir / "wizard" / "uninstall"),
    (tpl_dir / "tests" / "accept.sh", tests_dir / "accept.sh"),
]

written, skipped = [], []
for src, dst in plan:
    if dst.exists() and force != "1":
        skipped.append(str(dst))
        continue
    text = src.read_text(encoding="utf-8")
    for key, value in subs.items():
        text = text.replace(key, value)
    if dst.exists():
        dst.chmod(0o644)
    dst.write_text(text, encoding="utf-8")
    if dst.suffix in (".sh", "") and not str(dst).endswith("uninstall"):
        dst.chmod(0o755)
    written.append(str(dst))

print("written:", *written, sep="\n  ")
if skipped:
    print("skipped (已存在，--force 覆盖):", *skipped, sep="\n  ")
PY

fail=0
for f in "$PKG_DIR/cmd/main" "$PKG_DIR/cmd/uninstall_init" "$PKG_DIR/cmd/uninstall_callback" "$TESTS_DIR/accept.sh"; do
  bash -n "$f" || { echo "语法错误：$f" >&2; fail=1; }
done
python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$PKG_DIR/wizard/uninstall" \
  || { echo "JSON 错误：$PKG_DIR/wizard/uninstall" >&2; fail=1; }

left="$(grep -rnoE '@[A-Z_]+@' "$PKG_DIR/cmd" "$PKG_DIR/wizard" "$TESTS_DIR/accept.sh" 2>/dev/null || true)"
if [ -n "$left" ]; then
  echo "错误：仍有未替换的占位符（模板没覆盖到的标记）：" >&2
  printf '%s\n' "$left" >&2
  fail=1
fi

[ "$fail" = "0" ] || exit 1
cat <<MSG

下一步（必做，脚本不会替你决定）：
  1. 打开 $PKG_DIR/cmd/main，补「应用定制区」：TODO(app-env) / TODO(first-run) 两处。
  2. 补 $TESTS_DIR/accept.sh 的 stage_e2e（真实业务断言）；不补的话 accept all 会直接 FAIL。
  3. 安装向导里把默认端口设成 $PORT，并在 install_callback/config_callback 里写 $PKG_DIR 对应的 config.env。
  4. 真机跑：bash $TESTS_DIR/accept.sh all
MSG
