# 模板与占位符

`tools/scaffold-lifecycle.sh` 会把这些文件拷进应用包并替换占位符。手工拷也可以，替换同样的标记。

| 文件 | 拷到 | 作用 |
|---|---|---|
| `cmd/main` | `packaging/<App>/cmd/main` | 生命周期入口（start/stop/status） |
| `cmd/uninstall_init` | `packaging/<App>/cmd/uninstall_init` | 卸载前只记录选择 |
| `cmd/uninstall_callback` | `packaging/<App>/cmd/uninstall_callback` | 卸载后按 keep/purge 执行 |
| `wizard/uninstall` | `packaging/<App>/wizard/uninstall` | 卸载方式二选一 |
| `tests/accept.sh` | `<repo>/tests/accept.sh` | 六阶验收脚本 |

## 占位符

| 占位符 | 含义 | 例子 |
|---|---|---|
| `@APPNAME@` | manifest 里的 appname（与包名一致） | `MyApp` |
| `@PREFIX@` | 配置变量前缀（大写） | `MYAPP` → `MYAPP_PORT` |
| `@MODE@` | `entry`（解释器+脚本）/ `binary`（包内自带可执行文件） | `entry` |
| `@ENTRY@` | `MODE=entry` 时的入口文件（相对 `target/`） | `dist/server/index.mjs` |
| `@LAUNCH@` | 拉起进程的完整命令（在 `target/` 下执行） | `exec "$NODE_BIN" "$ENTRY"` |
| `@OWN_BINS@` | 包内自有二进制（相对 `target/`，空格分隔，用于孤儿清扫） | `bin/helper bin/worker` |
| `@HEALTH_PATH@` | 就绪探测路径；空则退化为端口探测 | `/healthz` |
| `@DEFAULT_PORT@` | 端口默认值（别用 8080） | `26800` |
| `TODO(app-env)` | `build_env()` 里追加的应用环境变量（生成后手工补） | `export MYAPP_HOME=...` |
| `TODO(first-run)` | 首启默认值逻辑（生成后手工补，没有就删） | 调应用自己的 API |
| `@USER_DATA_HINT@` | 卸载提示里"不删什么"的说明 | `/vol1/@appshare/MyApp/downloads` |
| `@STATE_PATHS@` | `purge` 要删的相对路径（相对 `PKGVAR`） | `data home tmp config.env` |
| `@PKGVAR@` `@SAVE_DIR@` `@PORT@` `@HEALTH@` | 验收脚本用 | `/vol1/@appdata/MyApp` … |
| `TODO(e2e)` | 验收阶段的端到端用例（生成后手工补，没有就保持 SKIP） | 触发 → 断言产物 |
