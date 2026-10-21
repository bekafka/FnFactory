# Changelog

## Unreleased

### Fixed

- manifest 注入：多行 changelog 规范化为单行，新增 `tools/render-manifest.py` 做行格式与占位符校验。
- `templates/cmd/main`：先 source `config.env` 再读取 `PREFIX_*`，修复 `PORT` 被 `MAX_OLD_SPACE` 覆盖、其他配置被忽略的问题。
- `templates/cmd/main`：`RUNTIME_BIN` 可配置，支持 Node 之外的 entry 运行时；Node 自动带 `--max-old-space-size`。
- `tools/scaffold-lifecycle.sh`：验收脚本写到 `apps/<App>/tests/`；binary/entry 模式必填参数校验；`--runtime-bin`。
- `_build-fpk.yml`：Release tag 默认 `<App>-v<version>` 并强校验；fnpack 必须报告 `Packing successfully` 且恰好一个 `.fpk`。
- `_build-fpk.yml`：拆分 build/package，统一在 x86 runner 用 amd64 fnpack 打包，移除 arm64 qemu。
- `_publish-index.yml`：并发串行化 + push 冲突 `fetch/rebase` 重试；`platform` 跟随最新 release 的 packages；README 最新版使用 `version_key`。
- `_auto-upstream.yml`：改用 releases 列表（保留 prerelease），支持 `build_app_key`，只记录“已触发”，Release 不存在会重试。
- `templates/tests/accept.sh`：补鉴权阶段；e2e 未实现直接 FAIL；端口从 config.env 读取；进程匹配不再误伤其他 Node 应用。
- `templates/cmd/uninstall_callback`：`PKGVAR` 归一化与 `@STATE_PATHS@` 路径穿越护栏。
- `tools/lint-package.sh`：去注释后再匹配；新增 appname/manifest 占位符/config JSON/图标/桌面入口检查。
- examples：修复旧仓库名、`template_dir`、`git log | head` SIGPIPE、架构自检、Docker manifest jq 解析、runtime-dep 误拷全仓。

### Added

- `.github/workflows/ci.yml` + `tests/run.sh` + `tests/fixtures/` 回归测试。
- `Makefile`、`.gitattributes`、Dependabot 配置、自动跟版调用示例。
