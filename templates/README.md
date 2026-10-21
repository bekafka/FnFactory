# 模板与占位符

`tools/scaffold-lifecycle.sh` 会把这些文件拷进应用包并替换占位符。手工拷也可以，替换同样的标记。

| 文件 | 拷到 | 作用 |
|---|---|---|
| `manifest` | `apps/<App>/package/manifest` | 包元数据 + **三个作者**（手工拷，`scaffold-lifecycle.sh` 不管它） |
| `cmd/main` | `apps/<App>/package/cmd/main` | 生命周期入口（start/stop/status） |
| `cmd/uninstall_init` | `apps/<App>/package/cmd/uninstall_init` | 卸载前只记录选择 |
| `cmd/uninstall_callback` | `apps/<App>/package/cmd/uninstall_callback` | 卸载后按 keep/purge 执行 |
| `wizard/uninstall` | `apps/<App>/package/wizard/uninstall` | 卸载方式二选一 |
| `tests/accept.sh` | `apps/<App>/tests/accept.sh` | 六阶验收脚本 |

## 占位符

| 占位符 | 含义 | 例子 |
|---|---|---|
| `@APPNAME@` | manifest 里的 appname（与包名一致） | `MyApp` |
| `@DISPLAY_NAME@` | 应用显示名（`manifest`，应用中心里给用户看的名字） | `MyApp 下载器` |
| `@DESC@` | 应用简介首段（`manifest` 的 `desc`，HTML 片段） | `把 X 做成飞牛能装的面板` |
| `@SOURCE_AUTHOR@` | 上游项目最初的作者/组织（`specs/authorship.md`） | `agalwood` |
| `@SOURCE_AUTHOR_URL@` | 上游项目主页（不带 `/releases`） | `https://github.com/agalwood/Motrix` |
| `@PREFIX@` | 配置变量前缀（大写） | `MYAPP` → `MYAPP_PORT` |
| `@MODE@` | `entry`（解释器+脚本）/ `binary`（包内自带可执行文件） | `entry` |
| `@ENTRY@` | `MODE=entry` 时的入口文件（相对 `target/`） | `dist/server/index.mjs` |
| `@RUNTIME_BIN@` | `MODE=entry` 的解释器绝对路径；Node/Python 都行 | `/var/apps/nodejs_v24/target/bin/node` |
| `@LAUNCH@` | 拉起进程的完整命令（在 `target/` 下执行） | `exec "$RUNTIME_BIN" "$ENTRY"` |
| `@OWN_BINS@` | 包内自有二进制（相对 `target/`，空格分隔，用于孤儿清扫） | `bin/helper bin/worker` |
| `@HEALTH_PATH@` | 就绪探测路径；空则退化为端口探测 | `/healthz` |
| `@DEFAULT_PORT@` | 端口默认值（别用 8080） | `26800` |
| `TODO(app-env)` | `build_env()` 里追加的应用环境变量（生成后手工补） | `export MYAPP_HOME=...` |
| `TODO(first-run)` | 首启默认值逻辑（生成后手工补，没有就删） | 调应用自己的 API |
| `@USER_DATA_HINT@` | 卸载提示里"不删什么"的说明 | `/vol1/@appshare/MyApp/downloads` |
| `@STATE_PATHS@` | `purge` 要删的相对路径（相对 `PKGVAR`，禁止 `..`/绝对路径） | `data home tmp config.env` |
| `@SAVE_DIRS@` | 权限修正/验收使用的用户数据目录（空格分隔） | `/vol1/@appshare/MyApp/downloads` |
| `@PKGVAR@` `@SAVE_DIR@` `@PORT@` `@HEALTH@` | 验收脚本用 | `/vol1/@appdata/MyApp` … |
| `TODO(e2e)` | 验收阶段的端到端用例（必须补；不补 `accept all` 会 FAIL） | 触发 → 断言产物 |

## manifest 模板

`templates/manifest` 不经 `scaffold-lifecycle.sh`，要手工拷进 `apps/<App>/package/manifest`
再替换 `@...@`。**三个作者（开发者/发布者/源作者）是硬性字段**，口径与门禁见
[`specs/authorship.md`](../specs/authorship.md)：`maintainer`/`distributor` 固定写 bekafka，
`source_author`/`source_author_url` 写上游项目最初的创造者与权利源头。
