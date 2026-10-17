# fpk-factory · FPK 打包厂

把任意应用自动打成飞牛 fnOS 可安装的 `.fpk`，发到 GitHub Release，并写回
[FnDepot](../FnDepot) 索引。**本仓库自己不产生应用**，它只提供可复用的流水线。

---

## 架构（拓扑 C：混合）

```
① 自研应用仓库                    ② 打包厂（本仓库）              ③ 索引仓库
   bekafka/myapp                     bekafka/fpk-factory            bekafka/FnDepot
   ├── src/                          ├── tools/fnpack-linux-*       ├── fnpack.json
   ├── packaging/                    ├── .github/workflows/         ├── categories.json
   │   ├── MyApp/  (fnOS 包模板)     │   ├── _build-fpk.yml   ◀──┐  └── tools/
   │   └── build.sh                  │   ├── _publish-index.yml ◀─┤
   └── .github/workflows/release.yml ┘   └── _auto-upstream.yml    │
              │  uses: .../_build-fpk.yml@main                      │
              │  uses: .../_publish-index.yml@main ─────────────────┘
              ▼
        Release（.fpk 资产留在这里）
```

| 仓库 | 角色 | 客户端读它吗 |
|---|---|---|
| **应用仓库**（各一个） | 源码 + 包模板 + `build.sh` | ❌ |
| **打包厂**（本仓库，一个） | 可复用流水线 + fnpack 工具 | ❌ |
| **FnDepot**（一个） | 索引元数据 | ✅ 只读它 |

**重打包上游**（别人的二进制/镜像，自己没有源码仓库）就走本仓库：
在 `fnpack/<App>/` 放模板，在 `.github/workflows/` 放一条流水线。

---

## 核心设计：三类应用共用一条流水线

二进制 / Node-Python / Docker **不是三种流水线**——它们的打包流程完全一样：

```
取产物 → 套模板 → 注入占位符 → fnpack build → 改名 → Release → 写索引
   ▲
   └── 唯一因类型而异的一步，由应用自己的 packaging/build.sh 实现
```

所以本仓库只有**一条**构建流水线，差异全部收敛到应用仓库的一个脚本里。

| 类型 | fnpack 模板 | build.sh 范例 | 要点 |
|---|---|---|---|
| **二进制** | `native` | [`examples/build-binary.sh.example`](examples/build-binary.sh.example) | 交叉编译 + `platform` 拆包 |
| **Node / Python** | `native` | [`examples/build-runtime-dep.sh.example`](examples/build-runtime-dep.sh.example) | **不打包运行时**，`install_dep_apps` 声明 |
| **Docker** | `docker` | [`examples/build-docker.sh.example`](examples/build-docker.sh.example) | 包内只有 compose，镜像另拉 |

> Node / Python **仍然属于 native**。它们和纯二进制的区别只在「运行时从哪来」，不影响 fnpack 模板的选择。

### 官方自带的运行时（不要自己打包）

实测确认（读设备上已安装应用的 manifest）：

| 依赖名 | 版本 | 提供方 | 证据 |
|---|---|---|---|
| `nodejs_v24` | 24.13.1-1 | **飞牛官方** | `/var/apps/nodejs_v24/manifest` → `distributor = fnos` |
| `bunjs` | 1.3.9 | **飞牛官方** | `distributor = fnos` |
| `python312` | 3.12.13-1 | 官方运行时 | 官方文档列出 |
| `go-1.26` | 1.26.4 | 官方运行时 | 已安装 |
| `redis` / `minio` / `rabbitmq` | — | 官方中间件 | 官方文档列出 |

写在应用模板的 `manifest` 里：

```ini
install_dep_apps=nodejs_v24
```

生命周期脚本里必须先注入 PATH，否则会落到系统自带的旧版本：

```bash
export PATH=/var/apps/nodejs_v24/target/bin:$PATH
```

---

## 打包规范（`specs/`）—— 踩过的坑，别再踩

工厂除了流水线，还沉淀了一套**规范 + 可继承模板**。新应用接入前先读，写脚本时直接拷模板：

| 规范 | 管什么 | 模板 |
|---|---|---|
| [`specs/uninstall.md`](specs/uninstall.md) | 卸载向导（**保留配置 / 完全卸载**）、`purge` 路径护栏、日志落点 | `templates/wizard/uninstall`、`templates/cmd/uninstall_*` |
| [`specs/lifecycle.md`](specs/lifecycle.md) | `cmd/main`：pid 身份校验、孤儿清扫（**别用 `pgrep -x node`**）、就绪判据、日志轮转、用户数据目录权限、首启默认值、内存上限 | `templates/cmd/main` |
| [`specs/acceptance.md`](specs/acceptance.md) | 六阶验收：状态 / 端点 / 鉴权 / 端到端 / 生命周期 / 运维项 | `templates/tests/accept.sh` |
| [`specs/pitfalls.md`](specs/pitfalls.md) | 飞牛平台坑位：权限层覆盖 ACL、`data-share` 强制 `0700`、`comm=MainThread`、`releases/latest` 抓不到预发布… | — |

两条硬约束（CI 里会拦）：

1. **有持久化数据的应用必须给卸载方式选择**，默认 `keep`，`purge` 必须有 `/vol1/@appdata/*` 路径护栏；
2. **`cmd/main` 必须做 `/proc/<pid>/exe` 身份校验**、不得用 `pgrep -x node` 做孤儿清扫。

### 一键继承

```bash
../fpk-factory/tools/scaffold-lifecycle.sh \
  --pkg-dir packaging/MyApp --app MyApp --prefix MYAPP --port 26800 \
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
tools/lint-package.sh packaging/MyApp      # 本地跑；CI 的「校验打包规范」步骤跑同一条
```

它检查的是**规范里写成硬性要求**的部分（必需文件、脚本语法、keep 默认、路径护栏、向导结构、
`/proc` 身份校验、热门端口默认值…）。门禁不是为了卡人，是为了让规范不至于只活在文档里。

---

## 接入一个新应用（4 步）

### 1. 应用仓库放模板与脚本

```
myapp/
├── packaging/
│   ├── MyApp/                 # fnOS 包模板（可用 fnpack create MyApp 生成）
│   │   ├── manifest           # 占位符 ${VERSION} ${CHANGELOG} ${PLATFORM} 必须保留
│   │   ├── config/            # resource（含 privilege）
│   │   ├── cmd/               # install/upgrade/uninstall/config 生命周期 + main
│   │   ├── wizard/
│   │   └── app/
│   └── build.sh               # 从 examples/ 挑一个改名而来
└── .github/workflows/release.yml   # 从 examples/app-release.yml 改名而来
```

生成官方模板骨架，再用工厂的规范模板覆盖生命周期/卸载/验收：

```bash
fnpack create MyApp              # native
fnpack create MyApp --template docker

# 生命周期 + 卸载 + 验收（含占位符替换）
../fpk-factory/tools/scaffold-lifecycle.sh --pkg-dir packaging/MyApp --app MyApp ...
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

见 [FnDepot/README.md](../FnDepot/README.md)。**跳过这步会让端到端静默失败**。

### 4. 配 Secret 并打 tag

应用仓库 → Settings → Secrets → Actions，加：

| Secret | 内容 |
|---|---|
| `FNDEPOT_TOKEN` | classic PAT，勾 `repo`，对 FnDepot 有写权限 |

```bash
git tag v1.0.0 && git push origin v1.0.0
```

---

## 流水线文件

| 文件 | 作用 |
|---|---|
| [`_build-fpk.yml`](.github/workflows/_build-fpk.yml) | 通用构建：矩阵 → fnpack build → Release → 调发布 |
| [`_publish-index.yml`](.github/workflows/_publish-index.yml) | 写回索引：防呆 + platform 并集 + README 同步 + verify 门禁 |
| [`_auto-upstream.yml`](.github/workflows/_auto-upstream.yml) | 可选：每周巡检上游 release，有新版自动触发 |

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

`fnpack` 的主机架构与**包内产物架构无关**，所以理论上单机可打双架构；
本流水线仍用矩阵，是为了让「编译」这一步也落在原生架构上（避免 CGO / 原生模块跨架构问题）。
