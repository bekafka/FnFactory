# FnFactory · FPK 构建机器人仓库

把任意应用打成飞牛 fnOS 可安装的 `.fpk`，发到 **FnDepot 的 Release**，并写回它的索引。
**本仓库不产生任何应用**，它是构建机器人：提供可复用流水线（workflow）、
打包规范（`specs/`）、可继承模板（`templates/`）与工具。

---

## 架构（集中式，2026-10-17 定案）

```
① FnDepot（应用源码 + 索引）        ② FnFactory（本仓库）
   bekafka/FnDepot                     bekafka/FnFactory
   ├── fnpack.json  ← 客户端只读它      ├── .github/workflows/
   ├── assets/                         │   ├── _build-fpk.yml   ◀── 被 FnDepot 调用
   └── apps/                           │   ├── _publish-index.yml
       └── <App>/                      │   └── _auto-upstream.yml
           ├── package/  (fnOS 模板)   ├── specs/      打包规范
           ├── packaging/build.sh      ├── templates/ 可继承模板
           ├── tests/                  └── tools/     fnpack + scaffold + lint
           └── README.md
                  │  uses: FnFactory/.github/workflows/_build-fpk.yml@main
                  ▼
        Release（.fpk 资产发布在 FnDepot 自己仓库里）
```

| 仓库 | 角色 | 客户端读它吗 |
|---|---|---|
| **FnDepot** | 每个 fpk 应用的**源代码项目** + 索引；`.fpk` 资产发在自己的 Release 里 | ✅ 只读 `fnpack.json` |
| **FnFactory**（本仓库） | 构建机器人：可复用流水线 + 规范 + fnpack 工具 | ❌ |

**分工**：应用源码进 FnDepot 的 `apps/<App>/`；FnFactory 只提供"怎么把源码变成可安装的包"
（workflow + 规范 + 工具）。产物回落到 FnDepot 的 Release，索引写回 FnDepot 的 `fnpack.json`。

### 为什么这样收敛

- 一个仓库装下所有应用的源码，个人/小团队维护的第三方生态更容易整体浏览和复用；
- 可复用 workflow 里 `github.repository` 指向**调用方**，所以 Release 天然落在 FnDepot，
  不需要额外 PAT —— `GITHUB_TOKEN` 自己就能写自己的索引；
- 资产走 Release 而不是 git 提交，仓库体积始终保持小巧。

> Release tag 必须带应用名前缀（`<App>-v<version>`）：多应用共仓时这是防 tag 相撞的唯一手段。

---

## 打包规范（`specs/`）—— 踩过的坑，别再踩

工厂除了流水线，还沉淀了一套**规范 + 可继承模板**。新应用接入前先读，写脚本时直接拷模板：

| 规范 | 管什么 | 模板 |
|---|---|---|
| [`specs/authorship.md`](specs/authorship.md) | **三个作者**：开发者 / 发布者 / **源作者**（上游项目最初的创造者与权利源头）——写在哪六处、怎么校验 | `templates/manifest` |
| [`specs/uninstall.md`](specs/uninstall.md) | 卸载向导（**保留配置 / 完全卸载**）、`purge` 路径护栏、日志落点 | `templates/wizard/uninstall`、`templates/cmd/uninstall_*` |
| [`specs/lifecycle.md`](specs/lifecycle.md) | `cmd/main`：pid 身份校验、孤儿清扫（**别用 `pgrep -x node`**）、就绪判据、日志轮转、用户数据目录权限、首启默认值、内存上限 | `templates/cmd/main` |
| [`specs/acceptance.md`](specs/acceptance.md) | 六阶验收：状态 / 端点 / 鉴权 / 端到端 / 生命周期 / 运维项 | `templates/tests/accept.sh` |
| [`specs/pitfalls.md`](specs/pitfalls.md) | 飞牛平台坑位：权限层覆盖 ACL、`data-share` 强制 `0700`、`comm=MainThread`、`releases/latest` 抓不到预发布… | — |

三条硬约束（CI 里会拦）：

1. **有持久化数据的应用必须给卸载方式选择**，默认 `keep`，`purge` 必须有 `/vol1/@appdata/*` 路径护栏；
2. **`cmd/main` 必须做 `/proc/<pid>/exe` 身份校验**、不得用 `pgrep -x node` 做孤儿清扫；
3. **三个作者必须写清**：`maintainer`/`distributor` 写 bekafka，`source_author`/`source_author_url`
   写上游项目最初的创造者与权利源头（见 [`specs/authorship.md`](specs/authorship.md)）。

### 一键继承

```bash
本仓库 tools/scaffold-lifecycle.sh \
  --pkg-dir apps/MyApp/package --app MyApp --prefix MYAPP --port 26800 \
  --health /healthz --mode entry --entry dist/server/index.mjs \
  --launch 'exec "$NODE_BIN" --max-old-space-size="${MAX_OLD_SPACE:-512}" "$ENTRY"' \
  --own-bins 'bin/helper' \
  --save-dir '/vol1/@appshare/MyApp/downloads' \
  --state-paths 'data home tmp config.env'
```

生成后会提示补三处 `TODO`（应用环境变量、首启默认值、端到端用例），并自动跑 `bash -n` + JSON 校验；
已存在的文件默认不覆盖（`--force` 才覆盖）。

### 规范门禁

```bash
tools/lint-package.sh apps/MyApp/package      # 本地跑；CI 的「校验打包规范」步骤跑同一条
```

它检查的是**规范里写成硬性要求**的部分（必需文件、脚本语法、keep 默认、路径护栏、向导结构、
`/proc` 身份校验、热门端口默认值、**三个作者字段**…）。门禁不是为了卡人，是为了让规范不至于只活在文档里。

---

## 接入一个新应用（4 步）

### 1. 应用仓库放模板与脚本

```
apps/MyApp/
├── package/                   # fnOS 包模板（fnpack create MyApp 生成后改名）
│   ├── manifest               # 占位符必须保留；三个作者按 specs/authorship.md
│   ├── config/                # resource（含 privilege）
│   ├── cmd/                   # install/upgrade/uninstall/config 生命周期 + main
│   ├── wizard/
│   └── app/
├── packaging/
│   ├── build.sh               # 从 examples/ 挑一个改名而来
│   ├── patches/               # 可选：上游兼容补丁
│   └── tools/                 # 可选：payload 生产线自带的工具
└── tests/                     # 验收阶梯
```

**目录名 = appname**（`apps/MyApp/` 的 `MyApp` 必须逐字等于 `package/manifest` 里的
`appname`），索引键、Release tag、资产名全靠它对齐。

生成官方模板骨架，再用工厂的规范模板覆盖生命周期/卸载/验收：

```bash
fnpack create MyApp              # native
fnpack create MyApp --template docker

# 生命周期 + 卸载 + 验收（含占位符替换）
本仓库 tools/scaffold-lifecycle.sh --pkg-dir apps/MyApp/package --app MyApp ...
```

### 2. `build.sh` 契约

流水线会传入这些环境变量，脚本的职责就是**把要进包的东西放进 `$PAYLOAD_DIR`**：

| 变量 | 值 |
|---|---|
| `ARCH` | `amd64` / `arm64` |
| `PLATFORM` | `x86` / `arm` |
| `VERSION` | 包版本 |
| `PAYLOAD_DIR` | **产物写这里**，会被整体拷进模板的 `app/` |

想在包内得到 `app/bin/foo`，就往 `$PAYLOAD_DIR/bin/foo` 写。

### 3. 在 FnDepot 上架（只做一次）

在 FnDepot 仓库跑 `python3 tools/add-app.py --help` 看参数（**源作者是必填**，口径见
[`specs/authorship.md`](specs/authorship.md)）。**跳过这步会让端到端静默失败**：
缺必填字段的应用会被客户端直接跳过，而索引看起来完全正常。

### 4. 触发构建

集中式模型下**不需要配任何 secret** —— 发布发生在 FnDepot 自己的仓库里，
`GITHUB_TOKEN` 就够了。在 FnDepot 仓库跑 Actions：

```bash
# 手动触发：Actions → Build App → Run workflow
# 填 app_key=MyApp、version=1.0.0、changelog=...
```

（也可在 FnDepot 加一条 push tag 的触发器，见 `examples/depot-build-app.yml`。）

---

## 流水线文件

| 文件 | 作用 |
|---|---|
| [`_build-fpk.yml`](.github/workflows/_build-fpk.yml) | 通用构建：矩阵 → fnpack build → Release → 调发布 |
| [`_publish-index.yml`](.github/workflows/_publish-index.yml) | 写回索引：防呆 + platform 并集 + README 同步 + verify 门禁 |
| [`_auto-upstream.yml`](.github/workflows/_auto-upstream.yml) | 可选：每周巡检上游 release，有新版自动触发 |

`_build-fpk.yml` 的 `template_dir` 指向**模板目录本身**（不再拼 app_key），
`build_script` 指向应用自己的 payload 生产线。调用方例子见
[examples/depot-build-app.yml](examples/depot-build-app.yml)。

`_build-fpk.yml` 在「校验契约」之后会跑 [`tools/lint-package.sh`](tools/lint-package.sh)：
卸载向导、`keep` 默认、路径护栏、`/proc` 身份校验、热门端口默认值这些规范项不过，构件不会产出。

### `_publish-index.yml` 比常见做法多做的四件事

1. **首次收录防呆** —— app 键不存在直接失败，而不是静默写出缺必填字段的空壳
2. **`platform` 取并集** —— 先发 x86 再发 arm 时自动补上 `arm`，否则 arm 设备看不到应用
3. **README 收录表同步** —— `verify.py` 会校验表里版本 == `max(releases)`
4. **推送前 `verify.py --no-net` 门禁** —— 结构不过就地失败，绝不推坏索引

---

## fnpack 工具

`tools/` 下随仓库携带两个静态二进制，按 `tools/SHA256SUMS` 哈希校验：

| 文件 | 版本 | 来源 |
|---|---|---|
| `fnpack-linux-amd64` | 1.2.3 | 官方发布 `static2.fnnas.com`，哈希已核对 |
| `fnpack-linux-arm64` | **1.2.4** | 官方该架构 404；取自飞牛设备自带的 `/usr/local/bin/fnpack` |

> ⚠️ **两个架构的 fnpack 版本不同**（1.2.3 / 1.2.4）。
> 官方对 arm64 从未发布过工件（`static2.fnnas.com/fnpack/fnpack-1.2.3-linux-arm64` → 404），
> 设备自带的是 1.2.4。出厂包内容一致，但如果你要求严格同版本，需自行取舍。

`fnpack` 的主机架构与**包内产物架构无关**（它只做打包，不执行包内文件），所以理论上单机可打双架构；
本流水线仍用矩阵，是为了让「编译」这一步也落在原生架构上（避免 CGO / 原生模块跨架构问题）。

> ⚠️ **两个版本行为有差异**：1.2.4（arm64，设备自带）会校验 manifest 的版本号必须是
> `x.y.z[-r]`（`r` 为整数），`2.0.0-beta.49` 直接 `Packing failed`；1.2.3（amd64）没有这个校验。
> 所以流水线**统一用 amd64 1.2.3 打包**（2026-10-17 实测定案）。本地复刻时注意：
> 在飞牛设备上直接用它的 `/usr/local/bin/fnpack`（1.2.4）打 beta 版本会失败。
