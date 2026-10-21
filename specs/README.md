# 打包规范（specs）

本目录是 FnFactory 的**规范层**：把踩过的坑固化成"必须这样做"的条款，配套**可直接拷走的模板**。
规则只有一条：**新应用接入时先读这里，再写脚本**。

| 规范 | 管什么 | 模板 | 谁必须遵守 |
|---|---|---|---|
| [authorship.md](authorship.md) | **三个作者**：开发者 / 发布者 / 源作者——谁是谁、写在哪六处、怎么校验 | `templates/manifest` | 所有应用，接入第一件事 |
| [uninstall.md](uninstall.md) | 卸载向导（保留配置 / 完全卸载）、路径护栏、日志落点 | `templates/wizard/uninstall`、`templates/cmd/uninstall_{init,callback}` | **所有带持久化数据的应用** |
| [lifecycle.md](lifecycle.md) | `cmd/main`：pid 身份、孤儿清扫、就绪判据、日志轮转、目录权限、首启默认值、内存上限 | `templates/cmd/main` | 所有常驻进程应用 |
| [acceptance.md](acceptance.md) | 六阶验收（状态/端点/鉴权/端到端/生命周期/运维） | `templates/tests/accept.sh` | 所有应用，发布前必跑 |
| [pitfalls.md](pitfalls.md) | 飞牛平台坑位（权限层、MainThread、`releases/latest`…） | — | 所有应用，写代码前先看 |

## 规范门禁

```bash
tools/lint-package.sh apps/MyApp/package
```

CI 的「校验打包规范」步骤跑同一条脚本。它只检查规范里的**硬性要求**（必需文件、脚本语法、
`keep` 默认、`/vol1/@appdata/*` 路径护栏、卸载向导结构、`/proc/<pid>/exe` 身份校验、
不使用 `pgrep -x node`、端口默认值不是热门端口、**三个作者字段齐全且值正确**）。加规范时想清楚：这条能不能写成断言？

## 怎么继承

一次性把模板拷进应用包并替换占位符：

```bash
# 在 FnDepot 仓库根目录执行（集中式模型：apps/<App>/package 就是模板目录）
/path/to/FnFactory/tools/scaffold-lifecycle.sh \
  --pkg-dir apps/MyApp/package \
  --app MyApp \
  --prefix MYAPP \
  --port 26800 \
  --health /healthz \
  --mode entry \
  --entry dist/server/index.mjs \
  --runtime-bin /var/apps/nodejs_v24/target/bin/node \
  --launch 'exec "$RUNTIME_BIN" --max-old-space-size="${MAX_OLD_SPACE:-512}" "$ENTRY"' \
  --own-bins 'bin/helper' \
  --save-dir '/vol1/@appshare/MyApp/downloads' \
  --state-paths 'data home tmp config.env'
```

脚本做的事：拷模板 → 替换占位符 → 生成后校验（`bash -n`、JSON 解析）→ 已存在的文件默认不覆盖（要覆盖加 `--force`）。
生成完**仍然要自己读一遍**「应用定制区」和 `TODO(app-env)` / `TODO(first-run)` / `TODO(e2e)` 这几处 TODO。

不想用脚本就手工拷 `templates/` 下的文件，把 `@...@` 全部替换掉，效果一样。

## 规范与模板的对应关系

- 规范里写了"为什么"和实测证据；模板里只写"怎么做"，并且尽量让**忘记改就会明显报错**
  （比如 `@APPNAME@` 没替换，`bash -n` 能过但跑起来会打印 `@APPNAME@`）。
- 规范改了，模板和 `templates/README.md` 的占位符表要同步改 —— 在同一个 PR 里完成。
- 模板不是"最佳实践收藏"，是**能直接跑起来的最小骨架**：能删的地方尽量少，注释尽量解释"不这么写会出什么事"。
