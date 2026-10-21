#!/usr/bin/env python3
"""Teach the vendored @opentui/core about Android, in place.

Upstream 0.4.5 resolves its native library from a static platform table and
throws for anything that is not darwin, linux or win32. `@opentui/core` is not
listed in upstream `patchedDependencies`, so a patch file dropped into
`patches/` is never applied. This script edits every installed copy instead.

Run after `bun install` and before `bun build`; it is idempotent and fails if a
pattern disappears, so a version bump cannot silently produce an unpatched
bundle.
"""

import json
import sys
from pathlib import Path

MARKER = "OPENTUI_LIB_PATH must point to libopentui.so on Android"

NAME_OLD = '  linux: "libopentui.so",\n'
NAME_NEW = '  linux: "libopentui.so",\n  android: "libopentui.so",\n'

LOADER_OLD = (
    "async function resolveNativeLibraryPath() {\n"
    "  const asset = getNativeAssetDescriptor(getCurrentNodeAssetTarget());\n"
)
LOADER_NEW = LOADER_OLD + (
    '  if (process.platform === "android") {\n'
    '    const androidPath = process.env.OPENTUI_LIB_PATH;\n'
    "    if (!androidPath) {\n"
    f'      throw new Error("{MARKER}");\n'
    "    }\n"
    "    return androidPath;\n"
    "  }\n"
)

NODE_ASSETS_OLD = "  const nativeRoot = dirname(resolvePackageEntry(native.packageName));\n"
NODE_ASSETS_NEW = (
    '  const nativeRoot = process.platform === "android" && process.env.OPENTUI_LIB_PATH\n'
    "    ? dirname(process.env.OPENTUI_LIB_PATH)\n"
    "    : dirname(resolvePackageEntry(native.packageName));\n"
)


def package_dirs(root: Path):
    for manifest in root.glob("**/node_modules/@opentui/core/package.json"):
        try:
            if json.loads(manifest.read_text())["name"] == "@opentui/core":
                yield manifest.parent
        except (KeyError, json.JSONDecodeError):
            continue


def patch_once(path: Path, old: str, new: str, label: str) -> bool:
    text = path.read_text()
    if new in text:
        return False
    if old not in text:
        raise SystemExit(f"cannot patch {path}: {label} pattern not found")
    path.write_text(text.replace(old, new, 1))
    return True


def replace_if_present(path: Path, old: str, new: str) -> bool:
    text = path.read_text()
    if new in text or old not in text:
        return False
    path.write_text(text.replace(old, new, 1))
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <upstream checkout>", file=sys.stderr)
        return 2

    root = Path(sys.argv[1])
    changed = 0
    seen = 0
    for directory in package_dirs(root):
        seen += 1
        tables = 0
        loaders = 0
        chunks = sorted(directory.glob("chunk-bun-*.js")) + sorted(directory.glob("chunk-node-*.js"))
        for chunk in chunks:
            text = chunk.read_text()
            if NAME_OLD in text:
                tables += 1
                changed += patch_once(chunk, NAME_OLD, NAME_NEW, "native file name table")
            if LOADER_OLD in text:
                loaders += 1
                changed += patch_once(chunk, LOADER_OLD, LOADER_NEW, "native library resolver")
                if MARKER not in chunk.read_text():
                    raise SystemExit(f"{chunk} still has no Android loader after patching")

        node_assets = directory / "node-assets.js"
        if node_assets.is_file():
            if NAME_OLD in node_assets.read_text():
                tables += 1
                changed += patch_once(node_assets, NAME_OLD, NAME_NEW, "native file name table")
            changed += replace_if_present(node_assets, NODE_ASSETS_OLD, NODE_ASSETS_NEW)

        if tables == 0 or loaders == 0:
            raise SystemExit(f"{directory}: expected a native file table and a loader, found {tables} and {loaders}")

        print(f"patched {directory}")

    if seen == 0:
        print("no @opentui/core copy found; run bun install first", file=sys.stderr)
        return 1

    print(f"opentui: {seen} package dir(s), {changed} file(s) changed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
