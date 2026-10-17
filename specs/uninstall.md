# 卸载规范

**适用**：所有带数据的应用（有 `TRIM_PKGVAR` 持久化目录的，几乎全部）。
**继承**：`templates/wizard/uninstall`、`templates/cmd/uninstall_init`、`templates/cmd/uninstall_callback`，
或用 `tools/scaffold-lifecycle.sh` 一次拷进应用包。

---

## 1. 必须提供卸载方式选择

飞牛官方契约里写着（`references/official-docs-live.md` §卸载流程）：

> 卸载逻辑应尊重用户数据。如果应用允许用户选择保留或删除数据，可在 `wizard/uninstall` 中收集选择。

**结论：只要应用往 `$TRIM_PKGVAR` 写过东西，就必须给用户选择，不能替用户决定。**

`wizard/uninstall` 用 `radio`（互斥两项，字段必须叫 `wizard_uninstall_mode`，默认 `keep`）：

```json
[
  {
    "stepTitle": "卸载 <应用名>",
    "items": [
      {
        "type": "radio",
        "field": "wizard_uninstall_mode",
        "label": "卸载方式",
        "initValue": "keep",
        "options": [
          { "label": "保留配置卸载（数据库、设置、插件都留着，重装后继续用）", "value": "keep" },
          { "label": "完全卸载（删除数据库、设置、插件和日志）", "value": "purge" }
        ]
      },
      { "type": "tips", "helpText": "两种方式都不会删除 <用户数据目录> 里的文件。" }
    ]
  }
]
```

为什么是 `radio` 而不是 `switch`：
- 两项语义互斥、且都是"危险/安全"级别的选择，`switch` 容易让人以为"关掉=全删"却看不出默认值；
- `radio` 让默认项在界面上可见（`initValue`）。

`tips` 必须**明确写出"不删什么"**（用户数据目录、下载目录、data-share 共享目录）。
对用户有价值的东西（下载的文件、导出的数据）一律不在卸载里删 —— 卸载是删"应用状态"，不是删"用户资产"。

## 2. 分两个脚本，别在 `uninstall_init` 里动手

| 脚本 | 时机 | 只该做什么 |
|---|---|---|
| `cmd/uninstall_init` | 卸载前，应用文件还在 | 把用户选择记进日志（`TRIM_TEMP_LOGFILE`），`exit 0` |
| `cmd/uninstall_callback` | 包文件已移除、应用已停止 | 真正执行删除 |

`uninstall_init` 里删东西会在"用户中途取消卸载"时留下半删状态；`uninstall_callback` 才是稳定时机。

## 3. `purge` 的硬性要求

```bash
case "$MODE" in
  purge)
    case "$PKGVAR" in
      /vol1/@appdata/*)   # ← 路径护栏：不是这个前缀就绝不动手
        rm -rf "$PKGVAR/data" ... ;;
      *) log "PKGVAR 不在预期路径（$PKGVAR），跳过删除" ;;
    esac ;;
  *) log "保留配置卸载" ;;
esac
```

四条规定：

1. **路径护栏**：`PKGVAR` 必须落在 `/vol1/@appdata/` 下，否则跳过并记日志。
   没有这层判断，`TRIM_PKGVAR` 被环境变量污染就是一次 `rm -rf` 打偏。
2. **逐项删除，不删 `PKGVAR` 本身**：删 `data/ home/ tmp/`、`config.env`、`*.pid`、旧日志，
   目录留给系统或下次安装重建。删目录本身容易和 fnOS 的目录管理打架。
3. **`keep` 分支必须打印"保留了什么"**，让用户/日志能确认这次卸载没有动数据。
4. **日志写 `TRIM_TEMP_LOGFILE`**（`/dev/null` 兜底）：`purge` 会把 `PKGVAR/info.log` 一起删掉，
   写到那里等于没写。同时 `echo` 到 stdout，App Center 的控制台能看到。

## 4. 与其它生命周期脚本的配合

- `install_callback` / `config_callback` 必须能在**空 data 目录**下重建一切（`purge` 之后重装就是这条路径）。
  自己验一遍：`purge` → 重装 → 首启正常、默认配置正确。
- 卸载**不要**去删 `data-share` 目录（`TRIM_DATA_SHARE_PATHS`）：那是用户在"文件"里共享的东西，
  属于用户资产；本规范统一约定"不删"。
- 卸载**不要**碰其他应用的文件；也不要 `pkill` 别的进程。

## 5. 验收（脚本级，3 个用例）

CLI 的 `appcenter-cli uninstall` 不接受 `--env`，卸载向导无法非交互传值，所以逻辑用**直接调用脚本**验：

```bash
# 1) purge 清空
T=/vol1/@appdata/<pkg>-deltest; mkdir -p $T/data $T/home; touch $T/data/db $T/config.env $T/info.log
wizard_uninstall_mode=purge TRIM_PKGVAR=$T bash /var/apps/<pkg>/cmd/uninstall_callback
[ -z "$(ls -A $T)" ] && echo "purge ok"

# 2) keep 不动
wizard_uninstall_mode=keep TRIM_PKGVAR=$T bash /var/apps/<pkg>/cmd/uninstall_callback
[ -f $T/data/db ] && echo "keep ok"

# 3) 默认值（不传 wizard_*）等价于 keep
TRIM_PKGVAR=$T bash /var/apps/<pkg>/cmd/uninstall_callback
```

第 3 条很重要：Tab 补全/CLI/系统内部调用卸载时不会带 `wizard_*`，此时必须走 `keep`。

最后在 App Center 里**手工点一次**「完全卸载」，确认向导真的弹出来、选了之后数据真的没了 ——
这一步没法自动化，写进发布 checklist。
