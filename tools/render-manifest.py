#!/usr/bin/env python3
"""把 FnFactory 的 manifest 占位符渲染成最终值。

输入（环境变量）：
    APP_KEY   目标 appname，必须与 manifest 的 appname 一致
    VERSION   包版本
    PLATFORM  x86 / arm / all
    CHANGELOG 更新日志（允许多行；会规范化为单行）

退出码：
    0  成功
    1  manifest 格式/契约不满足（错误写到 stderr，GitHub Actions 会显示 ::error::）
"""

import os
import re
import sys


def die(message: str) -> None:
    print(f"::error::{message}", file=sys.stderr)
    raise SystemExit(1)


def parse_field(text: str, name: str) -> str:
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        key, value = s.split("=", 1)
        if key.strip() != name:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        return value
    return ""


def main() -> None:
    if len(sys.argv) != 2:
        die("usage: render-manifest.py <manifest>")

    path = sys.argv[1]
    try:
        text = open(path, encoding="utf-8").read().replace("\r\n", "\n")
    except OSError as exc:
        die(f"读不到 manifest {path}: {exc}")

    app_key = os.environ.get("APP_KEY", "")
    version = os.environ.get("VERSION", "")
    platform = os.environ.get("PLATFORM", "")

    if not app_key or not version or not platform:
        die("APP_KEY / VERSION / PLATFORM 必须非空")

    # fnpack 的 manifest 是逐行 key=value，changelog 不能包含换行。
    changelog = " · ".join(
        line.strip() for line in os.environ.get("CHANGELOG", "").splitlines() if line.strip()
    ) or "维护与细节优化"

    values = {"VERSION": version, "PLATFORM": platform, "CHANGELOG": changelog}
    for name, value in values.items():
        text = text.replace("${%s}" % name, value)

    if re.search(r"@[A-Z_]+@|\$\{[A-Z_]+\}", text):
        die("manifest 仍有未替换占位符")

    if parse_field(text, "appname") != app_key:
        die(f"manifest appname={parse_field(text, 'appname')!r} != app_key={app_key!r}")
    if parse_field(text, "version") != version:
        die(f"manifest version={parse_field(text, 'version')!r} != {version!r}")
    if parse_field(text, "platform") != platform:
        die(f"manifest platform={parse_field(text, 'platform')!r} != {platform!r}")

    for lineno, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if s and not s.startswith("#") and "=" not in s:
            die(f"manifest 第 {lineno} 行不是 key=value: {s!r}")

    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)
    print(f"✓ manifest: appname={app_key} version={version} platform={platform} changelog={changelog!r}")


if __name__ == "__main__":
    main()
