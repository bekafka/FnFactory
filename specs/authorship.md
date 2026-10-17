# 作者口径：开发者 / 发布者 / 源作者

每个进 [FnDepot](https://github.com/bekafka/FnDepot) 的应用都有**三个作者身份**，
**不许混写、不许留空**。这份规范由流水线硬性门禁执行：
`FnFactory/tools/lint-package.sh`（打包前）+ `FnDepot/tools/verify.py`（发布前）。

## 1. 三个角色

| 角色 | 是谁 | manifest 字段 | `fnpack.json` 字段 | 本仓库的固定值 |
|---|---|---|---|---|
| **开发者** | 做 fnOS 适配、写生命周期脚本、打包的人/团队 | `maintainer` / `maintainer_url` | `maintainer` / `maintainer_url` | `bekafka` / `https://github.com/bekafka/FnDepot` |
| **发布者** | 把 `.fpk` 发出来、维护应用源的人 | `distributor` / `distributor_url` | `distributor` / `distributor_url` | `bekafka` / `https://github.com/bekafka/FnDepot` |
| **源作者**（README 应用列表里写作「原作者」） | **上游项目最初的创造者与权利源头**（不是打包者） | `source_author` / `source_author_url` | `source_author` / `source_author_url` | 上游 GitHub owner / 上游项目主页 |

例：Motrix 的上游是 [agalwood/Motrix](https://github.com/agalwood/Motrix)（最初作者 agalwood，MIT），所以

```ini
maintainer        = bekafka
maintainer_url    = https://github.com/bekafka/FnDepot
distributor       = bekafka
distributor_url   = https://github.com/bekafka/FnDepot
source_author     = agalwood
source_author_url = https://github.com/agalwood/Motrix
```

开发者与发布者都是 bekafka，链接都指向本仓库 `bekafka/FnDepot`（用户口径：都指向自己）；
**源作者永远是上游那个项目**，不是我们。

## 2. 为什么源作者要单独记

- 官方 manifest 只有 `maintainer`（开发者）和 `distributor`（发布者）两个字段，
  **没有"上游作者"字段**。`source_author` / `source_author_url` 是本项目补的扩展键；
  fnpack 1.2.3 实测原样保留进包、不报错（见 §6 实测）。
- 官方 FnDepot V2 源规范里的 `source_info.author` 指"**这个应用源由谁维护**"（= bekafka），
  **不是**上游项目的创作者，不要把它当源作者用。
- 打包适配不等于原创。写清上游项目、作者与许可，是再分发时的基本义务；
  也让用户知道出问题该找谁（上游功能缺陷 vs 打包/安装问题）。

官方口径参考：

- fnOS manifest：<https://developer.fnnas.com/docs/core-concepts/manifest/>
  （`maintainer` = 开发者，`distributor` = 发布者）
- FnDepot V2 源规范：<https://github.com/EWEDLCM/FnDepot> §4.3「开发者、发布者和源作者」

## 3. 写在哪（六处，缺一不可）

| # | 位置 | 写什么 | 谁校验 |
|---|---|---|---|
| 1 | `apps/<App>/package/manifest` | 六字段；`desc` 末尾带源作者链接 | `lint-package.sh` |
| 2 | `fnpack.json` 应用节点 | 六字段（客户端展示开发者/发布者，`source_author*` 为扩展键） | `verify.py` |
| 3 | `README.md` 应用列表 | 「原作者」列：`[owner/repo](上游项目主页)` | `verify.py` |
| 4 | `assets/<App>/README.md` | 「作者与来源」小节（客户端应用页会渲染它） | 人工抽查 |
| 5 | `apps/<App>/README.md` | 技术说明里同样标出三个角色（贡献者视角） | 人工抽查 |
| 6 | `.fpk` 包内 `manifest` | 随包分发，装到设备后仍可 `tar xf` 查证 | fnpack 原样保留（§6 实测） |

第 1 与第 2 处的六个字段必须**逐字一致**，`verify.py` 会拦（防止只改了一边）。

## 4. 取值规则

- `source_author`：上游 GitHub owner（大小写照抄）；上游是组织/公司就写组织名。
- `source_author_url`：**项目主页**，固定 `https://github.com/<owner>/<repo>`；
  不带 `/releases`、`/tree`、`/issues`、`latest/download`（那些会随发版漂移或 404）。
- **"最初的创造者与权利源头"** 指项目起源：不链 fork、不链下游镜像、不链别人的二次封装。
  上游改过名/迁移过仓库时，写现在可访问的 origin 项目页，并在 `apps/<App>/README.md` 注明迁移链。
- 上游是纯组织项目（没有个人作者）时，`source_author` 写组织名即可。
- **第三方收录**（不是我们打包、只做索引的应用）：
  `maintainer` / `maintainer_url` 写上游打包者与项目页（沿用 `fndepot` 口径），
  `distributor` / `distributor_url` 仍写本源（bekafka / FnDepot），
  `source_author` / `source_author_url` 写**真正的上游原创者**。

## 5. 门禁

`FnFactory/tools/lint-package.sh <package-dir>`（CI 的「校验打包规范」步骤）：

- manifest 六字段齐全，且 `maintainer` / `distributor` 等与本仓库固定值一致
  （可用 `FACTORY_OWNER` / `FACTORY_DEV_URL` / `FACTORY_PUB_URL` 覆盖，给别的维护者复用）；
- `source_author` 非空且不是占位符（`your-name`、`@...@`、`TODO`）；
- `source_author_url` 是项目主页形态，且不含 `/releases`、`latest/download`；
- `desc` 里出现 `source_author_url`（保证用户在应用中心点得到源作者）。

`FnDepot/tools/verify.py`：

- 索引里每个应用都要有 `source_author` / `source_author_url`，且形态合法；
- 有 `apps/<App>/package/manifest` 的应用，manifest 与索引的六字段逐字一致；
- README 应用列表「原作者」列的链接 == 索引 `source_author_url`，版本/架构列仍由发版流水线同步。

发布流水线在推送前跑 `verify.py --no-net`，所以**口径不一致的索引推不上去**。

## 6. 实测记录（2026-10-17）

- **fnpack 接受扩展键**：在 manifest 里加 `source_author` / `source_author_url`，
  `fnpack 1.2.3 build` 正常出包，包内 manifest 原样保留这两个键（字段顺序会被重排，内容不变）。
- **FnDepot 客户端容忍未知应用级字段**：客户端 v0.6.6 成功同步了
  `Kasbuky-sudo/FnDepot`（应用节点带扩展键 `developer` / `developer_url`）的全部 6 个应用，
  `sync_status=synced`、`sync_error=NULL`。所以 `source_author*` 不会让整个源同步失败；
  客户端只是忽略它（展示仍靠 `maintainer`/`distributor` 与 `desc`/README）。
- 旧 manifest 的 `maintainer_url` 曾指向已废弃的 `bekafka/motrix-fpk`，本轮一并纠正。

## 7. 变更记录

- **2026-10-17**：定案三作者口径（开发者/发布者/源作者）；Motrix、Magpie 首批落地；
  新增 `templates/manifest` 模板与 `lint-package.sh` 作者门禁；`fnpack.json` 与 README 同步。
