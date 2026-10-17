# 飞牛平台坑位清单

全部是在真机（fnOS 1.x，A311D/aarch64）上撞出来并复核过的，不是传闻。
写这条清单的目的：**下一个应用别再把同样的坑重踩一遍**。

## 1. `/vol1` 的权限层会覆盖 POSIX ACL、文件 capability 和用户组

现象：应用用户（`run-as: package`）访问 `/vol1` 下的其他目录 → `Permission denied`。

实测结论（逐条否掉）：

| 尝试 | 结果 |
|---|---|
| `setfacl -m u:<user>:rx <dir>` | 无效（被 trimacl/trimafs 覆盖） |
| `setcap` 给二进制加能力 | 无效 |
| 把用户加进 `Users` 组 | 无效 |
| 以 root 跑 | 有效，但违反 `run-as` 约定 |

**正解**：应用只读写自己的 `$TRIM_PKGVAR` 和 `data-share`（`$TRIM_DATA_SHARE_PATHS`），
跨目录访问找 fnOS 的授权接口（应用权限页），不要在打包里硬刚 ACL。
确实需要在 `/vol1` 上做"受限遍历"的（例如只读自己目录的上级），要准备 `O_PATH` 回退补丁这类方案 ——
那属于应用自身代码的兼容层，别指望系统权限放行。

## 2. `data-share` 里新建的文件被强制成 `0700`

- `touch`、`echo >`、下载器/curl 直接写，全是 `0700`；
- `umask 0022` 无效；`chmod` 有效；
- 后果：同机其他应用用户读不了，媒体服务器/同步工具全部取不到文件。

**正解**：启动时把用户数据目录 `chmod 0755`、文件 `0644`，并起一个跟随进程存活的轮询修新文件
（见 `specs/lifecycle.md` §7）。

## 3. 飞牛上的 node 进程名是 `MainThread`

`pgrep -x node` / `pgrep node` 匹配不到任何东西（`comm` 被改写）。
**正解**：遍历 `/proc/*/exe` 比对 realpath（见 `specs/lifecycle.md` §2）。

## 4. 向导值不进 `cmd/main`

`wizard_*` 只注入 install/upgrade/uninstall/config 的回调脚本，**不注入 `cmd/main`**。
想看用户填的端口，只能由回调写进 `config.env` 再 source。
这条不记住的典型后果：安装向导里改了端口，应用还在用默认端口，入口点进去 404。

## 5. `appcenter-cli` 的边角

- `stop` / `start` / `status` / `check` / `uninstall` 都是**位置参数**，没有 `restart`；
- `uninstall` **不接受 `--env`** → 卸载向导无法非交互传值，逻辑要用"直接跑脚本"验；
- 对已安装的应用再 `install-fpk` 会报错，升级要先卸载（数据在 `@appdata`，不会丢）；
- 需要 root（用 sudo 或 root 登录）。

## 6. 替换正在运行的二进制会 `Text file busy`

应用常驻时 `cp`/`install` 覆盖包内可执行文件会失败。
**正解**：先 `appcenter-cli stop`，替换后再 `start`。
另外注意有些应用会**常驻子进程**（守护/旁路程序），停主进程不等于子进程已退出 —— 见 §2 的孤儿清扫。

## 7. GitHub `releases/latest` 对"只发预发布"的项目会返回 2023 年的旧稳定版

自动跟版流水线若用 `releases/latest`，会给一个只有 beta 的项目抓到几年前的 stable。
**正解**：`GET /repos/:owner/:repo/releases?per_page=N`，跳过 `draft`，**保留 prerelease**，
按 `published_at` 取最新，再把 tag 去掉前缀 `v` 当包版本。

## 8. `fpk.py inspect`（fnos-fpk-builder skill）误报 `core` 目录

规则把任何 basename 为 `core` 的**目录**当成 core dump / vim swap，命中就 FAILED。
带 `dist/core/`、`node_modules/**/core/` 的上游包会全部被拦。
**正解**：本机已改成"只有文件才算"，见该 skill 的 `LOCAL-PATCHES.md`；换机器部署 skill 时记得同步这条。

## 9. 日志没有轮转 = 迟早吃满盘

应用自己的日志和我们的 `info.log` 都是纯追加。实机上见过单文件 23MB 的 `info.log`。
**正解**：启动时按大小轮转，只留一份 `.1`（见 `specs/lifecycle.md` §6）。

## 10. 端口默认值别用 8080 / 8000

热门端口在 NAS 上大概率已被别的应用占着（尤其 8080 / 3000 / 5000）。
二选一：
- 默认给冷门端口（例如 2xxxx），向导里可改；
- 或启动前探测并自动换端口（有配置文件的应用可以做，见下一条）。

引擎类子进程（自带 RPC/监听端口的）默认端口撞车时，上游通常**直接 fatal 退出**。
如果它把端口存在自己的配置文件里，可以在启动前读出来、探测、换一个空闲端口写回去，
比"日志里警告一下然后起不来"好得多。

## 11. 图标与入口

- 包内图标：`ICON.PNG`（64×64）+ `ICON_256.PNG`（256×256），`app/ui/images/icon_64.png` / `icon_256.png`；
- 桌面入口 `app/ui/config` 里 `"port": "${wizard_port}"`，回调里再兜底重写一次；
- 想要"在桌面窗口内打开"用 `type: iframe`（应用若没发 `X-Frame-Options`/CSP `frame-ancestors` 限制）。

## 12. 卸载默认值必须是"保留"

CLI、系统内部调用、补全触发卸载时都不会带 `wizard_*`。
`uninstall_callback` 里 `${wizard_uninstall_mode:-keep}`，**默认保留**，删数据只能由用户显式选。
