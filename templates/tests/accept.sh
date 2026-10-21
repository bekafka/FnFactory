#!/bin/bash
# @APPNAME@ 验收阶梯 —— 安装到真机后跑：bash tests/accept.sh all
# 规范见 FnFactory/specs/acceptance.md；占位符由 scaffold-lifecycle.sh 替换。
set -u

APPNAME="@APPNAME@"
PREFIX="@PREFIX@"
PKGVAR="@PKGVAR@"            # 默认 /vol1/@appdata/@APPNAME@
APPDEST="${TRIM_APPDEST:-/var/apps/$APPNAME/target}"
SAVE="@SAVE_DIR@"            # 用户数据目录（下载/产出）
PORT="@PORT@"
HEALTH="@HEALTH@"            # 健康端点路径，例如 /healthz
LOG_FILE="$PKGVAR/info.log"
STAGE="${1:-all}"
PASS=0; FAIL=0

# 用户可能改过端口/保存目录：优先读 config.env 里的 PREFIX_*，不要用 scaffold 时的快照。
if [ -r "$PKGVAR/config.env" ]; then
  # shellcheck disable=SC1090
  . "$PKGVAR/config.env"
fi
if [ -n "${PREFIX:-}" ]; then
  var="${PREFIX}_PORT"; [ -n "${!var:-}" ] && PORT="${!var}"
  var="${PREFIX}_SAVE_DIRS"; [ -n "${!var:-}" ] && SAVE="${!var%% *}"
  var="${PREFIX}_FIX_PERMISSIONS"; FIX_PERMISSIONS="${!var:-${FIX_PERMISSIONS:-1}}"
  var="${PREFIX}_PERM_FIX_INTERVAL"; PERM_FIX_INTERVAL="${!var:-${PERM_FIX_INTERVAL:-30}}"
fi
BASE="http://127.0.0.1:$PORT"

ok()  { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; }
head2() { printf '\n── %s ──\n' "$1"; }
lan_ip() { ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -n 1; }

stage_status() {
  head2 "阶段 1：应用状态"
  st="$(appcenter-cli status "$APPNAME" 2>/dev/null)"
  [ "$st" = "running" ] && ok "appcenter status = running" || bad "status = $st"
}

stage_endpoints() {
  head2 "阶段 2：端点"
  code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE$HEALTH")"
  [ "$code" = "200" ] && ok "健康端点 $HEALTH = 200" || bad "健康端点 = $code"
  code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/")"
  case "$code" in
    200|301|302|303) ok "首页 = $code" ;;
    *)              bad "首页 = $code" ;;
  esac
  ip="$(lan_ip)"
  if [ -n "$ip" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://$ip:$PORT$HEALTH")"
    [ "$code" = "200" ] && ok "局域网 IP 访问 = 200（$ip）" || bad "局域网 $ip = $code"
  else
    echo "  [SKIP] 取不到局域网 IP"
  fi
}

stage_auth() {
  head2 "阶段 3：鉴权"
  if [ "${AUTH_MODE:-auto}" = "none" ]; then
    echo "  [SKIP] AUTH_MODE=none（应用明确声明无鉴权）"
    return 0
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/")"
  case "$code" in
    401|403) ok "未认证访问被拒绝（$code）" ;;
    *)       bad "未认证访问返回 $code（鉴权可能未生效；无鉴权应用请设 AUTH_MODE=none）" ;;
  esac
  if [ -n "${AUTH_HEADER:-}" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "$AUTH_HEADER" "$BASE/")"
    case "$code" in
      200|301|302|303) ok "带凭据访问 $code" ;;
      *)               bad "带凭据访问 $code" ;;
    esac
  else
    echo "  [SKIP] 未提供 AUTH_HEADER（正例未验证）"
  fi
}

stage_e2e() {
  head2 "阶段 4：端到端"
  # 换成真实业务验证：触发 → 等产物 → 断言大小/sha256/属主。
  # 没填时明确失败，不要假装通过；实现后把下面这行改成 ok。
  bad "stage_e2e 未实现（发布前必须替换本函数）"
}

stage_lifecycle() {
  head2 "阶段 5：生命周期"
  appcenter-cli stop "$APPNAME" >/dev/null 2>&1
  for i in $(seq 1 20); do [ "$(appcenter-cli status "$APPNAME" 2>/dev/null)" = "stopped" ] && break; sleep 1; done
  [ "$(appcenter-cli status "$APPNAME" 2>/dev/null)" = "stopped" ] && ok "stop 后 status = stopped" || bad "stop 后仍不是 stopped"
  ss -ltn 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]" && bad "端口 $PORT 未释放" || ok "端口 $PORT 已释放"
  left="$(for p in $(ls /proc | grep -E '^[0-9]+$'); do
            e="$(readlink -f "/proc/$p/exe" 2>/dev/null)"
            c="$(readlink -f "/proc/$p/cwd" 2>/dev/null)"
            m="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
            case "$e" in */"$APPNAME"/*) echo "$p"; continue ;; esac
            case "$c" in "$APPDEST"|"$APPDEST"/*) echo "$p"; continue ;; esac
            case "$m" in *"$APPDEST"*|*"$PKGVAR"*) echo "$p"; continue ;; esac
          done | head -n 1)"
  [ -z "$left" ] && ok "无残留进程" || bad "仍有残留进程 pid=$left"
  appcenter-cli start "$APPNAME" >/dev/null 2>&1
  for i in $(seq 1 45); do
    curl -fsS -m 1 "$BASE$HEALTH" >/dev/null 2>&1 && break; sleep 1
  done
  curl -fsS -m 2 "$BASE$HEALTH" >/dev/null 2>&1 && ok "start 后就绪" || bad "start 后未就绪"
}

stage_ops() {
  head2 "阶段 6：运维项"
  if [ -n "${SAVE:-}" ] && [ -d "$SAVE" ]; then
    mode=$(stat -c '%a' "$SAVE" 2>/dev/null)
    [ -n "$mode" ] && [ $(( 0$mode & 0005 )) -ne 0 ] && ok "用户数据目录权限 $mode（可进入）" || bad "用户数据目录权限 ${mode:-?}"
  else
    echo "  [SKIP] 用户数据目录不存在：${SAVE:-（未配置）}"
  fi
  if [ "${FIX_PERMISSIONS:-1}" = "1" ] && [ -n "${SAVE:-}" ]; then
    pid=$(cat "$PKGVAR/perm-fix.pid" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ok "权限修正轮询在跑" || bad "权限修正轮询未运行"
  else
    echo "  [SKIP] FIX_PERMISSIONS=0 或未配置 SAVE_DIRS"
  fi
  np=$(cat "$PKGVAR/app.pid" 2>/dev/null)
  tr '\0' ' ' < "/proc/${np:-0}/cmdline" 2>/dev/null | grep -q -- "--max-old-space-size=" \
    && ok "内存上限已生效" || echo "  [SKIP] 非 Node 应用，无堆参数"
  wiz="/var/apps/$APPNAME/wizard/uninstall"
  [ -f "$wiz" ] && grep -q wizard_uninstall_mode "$wiz" && ok "卸载向导存在" || bad "缺少卸载向导"
}

case "$STAGE" in
  status)    stage_status ;;
  endpoints) stage_status; stage_endpoints ;;
  auth)      stage_status; stage_auth ;;
  e2e)       stage_status; stage_endpoints; stage_auth; stage_e2e ;;
  lifecycle) stage_status; stage_lifecycle ;;
  ops)       stage_status; stage_ops ;;
  all)       stage_status; stage_endpoints; stage_auth; stage_e2e; stage_lifecycle; stage_ops ;;
  *)         echo "usage: $0 {status|endpoints|auth|e2e|lifecycle|ops|all}"; exit 2 ;;
esac

printf '\n=== 结果：PASS=%d FAIL=%d ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
