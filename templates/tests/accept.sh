#!/bin/bash
# @APPNAME@ 验收阶梯 —— 安装到真机后跑：bash tests/accept.sh all
# 规范见 fpk-factory/specs/acceptance.md；占位符由 scaffold-lifecycle.sh 替换。
set -u

APPNAME="@APPNAME@"
PKGVAR="@PKGVAR@"            # 默认 /vol1/@appdata/@APPNAME@
SAVE="@SAVE_DIR@"            # 用户数据目录（下载/产出）
PORT="@PORT@"
HEALTH="@HEALTH@"            # 健康端点路径，例如 /healthz
LOG_FILE="$PKGVAR/info.log"
BASE="http://127.0.0.1:$PORT"
STAGE="${1:-all}"
PASS=0; FAIL=0

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
  [ "$code" = "200" ] && ok "首页 = 200" || bad "首页 = $code"
  ip="$(lan_ip)"
  if [ -n "$ip" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://$ip:$PORT$HEALTH")"
    [ "$code" = "200" ] && ok "局域网 IP 访问 = 200（$ip）" || bad "局域网 $ip = $code"
  else
    echo "  [SKIP] 取不到局域网 IP"
  fi
}

stage_e2e() {
  head2 "阶段 4：端到端"
  # TODO(e2e): 换成真实业务验证 —— 触发 → 等产物 → 断言大小/sha256/属主。
  # 没填时明确跳过，不要假装通过。
  echo "  [SKIP] 未配置端到端用例（在 stage_e2e 里补 TODO(e2e)）"
}

stage_lifecycle() {
  head2 "阶段 5：生命周期"
  appcenter-cli stop "$APPNAME" >/dev/null 2>&1
  for i in $(seq 1 20); do [ "$(appcenter-cli status "$APPNAME" 2>/dev/null)" = "stopped" ] && break; sleep 1; done
  [ "$(appcenter-cli status "$APPNAME" 2>/dev/null)" = "stopped" ] && ok "stop 后 status = stopped" || bad "stop 后仍不是 stopped"
  ss -ltn 2>/dev/null | grep -qE "[:.]$PORT[[:space:]]" && bad "端口 $PORT 未释放" || ok "端口 $PORT 已释放"
  left="$(for p in $(ls /proc | grep -E '^[0-9]+$'); do
            e="$(readlink -f /proc/$p/exe 2>/dev/null)"; case "$e" in */"$APPNAME"/*|*nodejs_v24*) echo "$p" ;; esac
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
  mode=$(stat -c '%a' "$SAVE" 2>/dev/null)
  [ -n "$mode" ] && [ $(( 0$mode & 0005 )) -ne 0 ] && ok "用户数据目录权限 $mode（可进入）" || bad "用户数据目录权限 ${mode:-?}"
  pid=$(cat "$PKGVAR/perm-fix.pid" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ok "权限修正轮询在跑" || bad "权限修正轮询未运行"
  np=$(cat "$PKGVAR/app.pid" 2>/dev/null)
  tr '\0' ' ' < "/proc/${np:-0}/cmdline" 2>/dev/null | grep -q -- "--max-old-space-size=" \
    && ok "内存上限已生效" || echo "  [SKIP] 非 Node 应用，无堆参数"
  wiz="/var/apps/$APPNAME/wizard/uninstall"
  [ -f "$wiz" ] && grep -q wizard_uninstall_mode "$wiz" && ok "卸载向导存在" || bad "缺少卸载向导"
}

case "$STAGE" in
  status)    stage_status ;;
  endpoints) stage_status; stage_endpoints ;;
  e2e)       stage_status; stage_endpoints; stage_e2e ;;
  lifecycle) stage_status; stage_lifecycle ;;
  ops)       stage_status; stage_ops ;;
  all)       stage_status; stage_endpoints; stage_e2e; stage_lifecycle; stage_ops ;;
  *)         echo "usage: $0 {status|endpoints|e2e|lifecycle|ops|all}"; exit 2 ;;
esac

printf '\n=== 结果：PASS=%d FAIL=%d ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
