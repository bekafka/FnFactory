# 生命周期规范（`cmd/main`）

**适用**：所有需要常驻进程的应用（二进制 / Node / Python / Go）。
**继承**：`templates/cmd/main`（完整骨架，含占位符）+ `tools/scaffold-lifecycle.sh`。

---

## 0. 三条基本约定

1. `cmd/main` 只接受 `start` / `stop` / `status`，`status` 用退出码表达
   （`3` = running，`1` = stopped，与 fnOS 一致）。
2. **`status=running` 必须等价于"进程真的在跑"**：App Center 的启停按钮、网关的入口探测都依赖它。
3. 所有状态写 `$TRIM_PKGVAR`，所有可执行产物读 `$TRIM_APPDEST`（`target/` 在重装时会被整体重建）。

## 1. pid 身份校验（不做就会"永远 running"）

`TRIM_APPDEST` 可能是软链，`readlink -f` 归一化后再和 `/proc/<pid>/exe` 比：

```bash
check_identity() {
  exe="$(resolve_path "$(readlink /proc/$1/exe)")"
  want="$(resolve_path "$NODE_BIN")"      # 或包内二进制
  [ "$exe" = "$want" ] || return 1
  cwd="$(resolve_path "$(readlink /proc/$1/cwd)")"
  [ "$cwd" = "$(resolve_path "$APPDEST")" ] || return 1
  tr '\0' ' ' < "/proc/$1/cmdline" | grep -q "$ENTRY"
}
```

pid 复用时只比 pid 会误杀别人的进程，只比 pid 文件会误判"在跑"。

## 2. 孤儿清理：**不要 `pgrep -x node`**

实测：飞牛设备上 node 进程的 `/proc/<pid>/comm` 是 **`MainThread`**，`pgrep -x node` 一个都匹配不到。
唯一可靠的做法是遍历 `/proc/*/exe` 比对 realpath：

```bash
for pid in $(ls /proc | grep -E '^[0-9]+$'); do
  exe="$(resolve_path "$(readlink /proc/$pid/exe 2>/dev/null)")"
  ...
done
```

- 解释器（node/python）是共享运行时：必须再用 cwd + cmdline 收紧；
- 包内独有二进制：只比 exe 就够，且**要能清掉旧数据目录下遗留的实例**（否则它一直占着端口，应用再也起不来）。

## 3. 就绪判据用应用自己

`status=running` 只说明进程活着。真实可用性用应用的健康端点：

```bash
curl -fsS -m 2 "http://127.0.0.1:$PORT/healthz"
```

没有健康端点的应用，退化成"端口已监听"，但要在注释里写明这是弱判据。

**端口一律现读配置**（用户可能改过），不要写死常量；`READY_TIMEOUT` 建议 45s。

## 4. 失败要回收

`start` 超时后：`TERM` → 等 → `KILL` → 再扫一遍孤儿 → 删 pid 文件。
不回收的结果是"App Center 显示 stopped，但端口还被占着"，下次启动必失败。

## 5. 配置从哪来

向导值（`wizard_*`）**只注入 install/callback 脚本，不注入 `cmd/main`**。
所以安装回调必须把它们写进 `$TRIM_PKGVAR/config.env`，`cmd/main` 启动时 source 它。
`config.env` 里的变量名统一加应用前缀（`MYAPP_PORT`），避免和系统变量撞。

## 6. 日志轮转

`info.log` 由我们的脚本和应用自身一起追加，没有上限就会无限涨（实测同机另一应用的日志 23MB）。
启动时检查大小，超过阈值（默认 5MB）就 `mv info.log info.log.1` 再建新的，只留一份。

## 7. 用户数据目录权限

飞牛 `data-share` 的权限层会把应用新建的文件**强制成 `0700`**：

- `touch x`、`echo > x`、下载器/curl 直接写 —— 全是 `0700`；
- `umask 0022` 无效；
- `setfacl` / `setcap` / 加 `Users` 组 —— 对 `/vol1` 一律无效（trimacl 覆盖）；
- **`chmod` 有效**。

后果：同机其他应用用户（媒体服务器、同步工具）读不到刚生成的文件。

做法：启动时把数据目录修成 `0755`、文件修成 `0644`，再起一个**跟随主进程存活**的轮询修新文件；
用两个配置项控制（`MYAPP_FIX_PERMISSIONS` / `MYAPP_SAVE_DIRS`），允许用户关掉。
只对"用户数据目录"做，不碰应用私有目录。

## 8. 首次启动的默认值

上游往往没有"默认语言/默认主题"的开关，值存在应用自己的设置里。别去改上游代码：

- 走应用自己的 API / 配置文件写一次；
- 落一个 marker（`$TRIM_PKGVAR/.first-run-done`），只做一次；
- 用户之后自己改不会被覆盖，卸载重装也不重置（`PKGVAR` 保留时）。

## 9. 内存上限

Node 应用加 `--max-old-space-size=512`（可配）。3~4GB 的盒子上，一个失控的 V8 堆能把整机拖死。

## 10. 自检清单

- [ ] `start` 幂等：已在跑不重复拉起
- [ ] `stop` 后 `ss -ltn` 里没有本应用端口
- [ ] `stop` 后再无 `exe` 指向应用的进程（含包内子进程）
- [ ] `status` 在"进程被 kill -9"后返回 stopped
- [ ] 日志超过阈值会轮转
- [ ] 端口被外来进程占用时，日志里写出占用者
- [ ] `TRIM_PKGVAR` 为空/不存在时不会崩
