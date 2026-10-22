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

## 13. fnpack 1.2.3 与 1.2.4 的版本号校验差异（CI 必读）

实测（2026-10-17，在飞牛设备上直接跑）：

| fnpack | 来源 | `version=2.0.0-beta.49` | `version=2.0.0-49` |
|---|---|---|---|
| 1.2.3 | 官方 amd64（`static2.fnnas.com`） | ✅ 通过 | ✅ 通过 |
| 1.2.4 | 飞牛设备自带 arm64 | ❌ `Packing failed. Invalid version` | ✅ 通过 |

1.2.4 要求 `x.y.z[-r]` 且 `r` 是**整数**，任何 `beta.N`/`rc.N` 后缀都被拒。
官方只发布过 amd64 1.2.3（`fnnas-apps/fnpack` 仓库与 static2 均无 arm64 工件）。

**打包厂的做法**（`_build-fpk.yml` 已固化）：

- 两个架构**统一用 amd64 1.2.3**（fnpack 只做打包不执行包内文件，宿主架构无所谓）；
- arm64 runner 执行不了 amd64 ELF → `apt-get install qemu-user-static` 经 binfmt 静态执行。

**给新应用的推论**：版本号想保留上游的 `-beta.N`/`-rc.N` 后缀，就必须走本工厂的 CI；
在飞牛设备上直接用它的 `/usr/local/bin/fnpack`（1.2.4）打这种版本会失败。

## 14. GitHub Actions 可复用 workflow 的四个坑（都已修）

1. **`find | head` 的 SIGPIPE**：`set -o pipefail` 下 `find … | head -40` 在文件多于 40 个时
   必现 exit 141/1。所有展示用的管道加 `|| true`。
2. **reusable workflow 里 `gh release`**：release job 没有 checkout 时
   `failed to run git: fatal: not a git repository` —— 可复用 workflow 不会继承调用方的
   检出状态，每个用 `gh` 的 job 都要自己 checkout。
3. **`$GITHUB_OUTPUT` 写多行 JSON**：file-command 格式要求单行值，直接 `echo "packages=$JSON"`
   会报 `Invalid format '  "x86": {'`。多行值必须用 heredoc 定界符：
   ```bash
   echo "packages<<__PKG__"; echo "$PACKAGES"; echo "__PKG__" >> "$GITHUB_OUTPUT"
   ```
   （`steps.<id>.outputs` 读出来是完整 JSON。）
4. **首次收录时 FnDepot 必须先有应用键**：发布 job 只写 `releases.<version>` 节点，
   `.apps[K]` 不存在时校验步骤会红。上架流程见 FnDepot 的 `tools/add-app.py`。

## 15. 集中式模型（FnDepot 装源码 + FnFactory 构建）的两个坑

1. **changelog 里的 `/` 和 `&` 会炸掉 sed 注入**：`sed "s/\${CHANGELOG}/${ESCAPED}/"`
   的替换文本含分隔符/`&` 时直接报 `unknown option to 's'`。用 python 做纯字符串
   `str.replace("${KEY}", value)` 最稳，无需任何转义。
   注意 YAML 块标量（`run: |`）里的 heredoc 代码必须缩进到块内，否则 YAML 解析失败。
2. **可复用 workflow 会收紧 token 权限**：调用方即使声明 `contents: write`，被调用
   workflow 顶层若写 `contents: read`，子 job 的 `GITHUB_TOKEN` 就是 read。
   集中式模型下推送目标就是调用方仓库（FnDepot），两处都必须 `contents: write`：
   ```yaml
   permissions:
     contents: write     # 被调用 workflow 顶层
   jobs:
     publish:
       permissions:
         contents: write # job 级（可选，显式更好）
   ```
   另需仓库设置 Actions 默认权限为 write（`PUT /repos/{repo}/actions/permissions/workflow`）。

## 16. 多应用共仓的 tag 规范

Release tag 必须带应用名前缀：`<App>-v<version>`（如 `Motrix-v2.0.0-beta.49`）。
否则两个应用同版本号会撞 tag，资产互相覆盖。资产名保持 `<App>-<version>-<arch>.fpk`。

## 17. Go 标准库漏洞只能靠「换工具链重编」，改依赖没用

`govulncheck` 把漏洞分成**标准库（stdlib）**和**模块依赖**两类。标准库那部分
（如 2026-10-21 的 `crypto/x509` 中间证书黑名单 `GO-2026-6809` / `CVE-2026-111943`，
修在 go1.26.10 / go1.27.3）**无论怎么 `go get -u` 都清不掉**，因为代码被编进二进制里了；
唯一的办法是用已修复的 Go 重新编译。

复现（Magpie 0.1.1299 / 0.1.1315 的线上二进制都用 go1.27.3 之前的工具链编）：

```bash
# 二进制级扫描：能直接看出 stdlib 漏洞和编译时用的 Go 版本
govulncheck -mode=binary path/to/bin/app   | grep -E 'Found in: (crypto|net|html|mime)/|go1\.' 
go version -m path/to/bin/app | head -1    # go1.27.2 / go1.26.4 → 带洞
```

应用层怎么做（见 `FnDepot/apps/Magpie/packaging/build.sh`）：

- 构建脚本里 **钉死 `GOTOOLCHAIN=go1.27.3`**，不再 `GOTOOLCHAIN=auto` 跟随 `go.mod` 的旧 `go` 指令；
- 编译前跑 `govulncheck ./...`（符号级可达性，不会因为未调用模块报警卡构建）当门禁；
- 编译后 `go version -m` 自证产物所用 Go 版本落在已修复区间，否则拒绝出包；
- CI 的 `setup-go` 也要显式传 `go_version: '1.27.3'`——默认为 `stable`，会随 runner 漂移，
  某天上游把 `stable` 挪回旧线或镜像缓存命中旧版，就会悄悄退回有洞的产物。

**预编译载体（直接取上游 release 二进制）的应用修不了这个**：上游不重编，你就只能等。
要么接受风险并在报告里写清，要么改成源码构建（会多引入 node/pnpm 前端链）。
