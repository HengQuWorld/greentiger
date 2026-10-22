#!/usr/bin/env python3
"""Static checks for the HarmonyOS theme palettes.

Dark mode is driven entirely by two palettes in
ohos_app/entry/src/main/ets/utils/ThemeConstants.ets. Two classes of defect
have already shipped once each, so they are checked here instead of by review:

1. Palette drift: a token exists in ThemeColors but in only one of the two
   palettes. TypeScript catches this, but the error message points at the
   palette rather than at the missing token.
2. A theme colour handed to a multi-argument @Builder as an argument. Such
   builders receive arguments by value and never re-render, so the widget keeps
   the colours it was first built with. See
   docs/arkui-builder-refresh-pitfalls.md.

Usage: python3 scripts/check_theme_tokens.py [-v]
Exit code is non-zero only for hard failures (drift, unknown token).
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ETS_DIR = REPO_ROOT / "ohos_app" / "entry" / "src" / "main" / "ets"
THEME_FILE = ETS_DIR / "utils" / "ThemeConstants.ets"

COLORS_REF = re.compile(r"this\.colors\.([A-Za-z][A-Za-z0-9]*)")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def block_keys(source: str, declaration: str) -> list:
    """Keys of `export const <declaration>: T = { ... };` in source order."""
    start = source.find("export const " + declaration)
    if start < 0:
        raise SystemExit("check_theme_tokens: cannot find `%s`" % declaration)
    open_brace = source.find("{", start)
    close_brace = source.find("};", open_brace)
    if open_brace < 0 or close_brace < 0:
        raise SystemExit("check_theme_tokens: cannot parse `%s`" % declaration)
    body = source[open_brace + 1:close_brace]
    return re.findall(r"^\s*([A-Za-z][A-Za-z0-9]*)\s*:", body, re.MULTILINE)


def interface_keys(source: str) -> list:
    start = source.find("export interface ThemeColors")
    end = source.find("}", source.find("{", start))
    return re.findall(r"^\s*([A-Za-z][A-Za-z0-9]*)\s*:", source[start:end], re.MULTILINE)


def comments_stripped(source: str) -> str:
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    return re.sub(r"^\s*//.*$", "", source, flags=re.MULTILINE)


def split_top_level(args: str) -> list:
    """Split a builder argument list on commas that are not nested."""
    parts, depth, current = [], 0, []
    in_string = None
    for ch in args:
        if in_string:
            current.append(ch)
            if ch == in_string:
                in_string = None
            continue
        if ch in "'\"`":
            in_string = ch
            current.append(ch)
        elif ch in "([{":
            depth += 1
            current.append(ch)
        elif ch in ")]}":
            depth -= 1
            current.append(ch)
        elif ch == "," and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(ch)
    if "".join(current).strip():
        parts.append("".join(current))
    return parts


def builder_calls_with_colors(source: str) -> list:
    """(line_no, builder_name) for @Builder calls given this.colors.* arguments."""
    findings = []
    for match in re.finditer(r"this\.(build[A-Z][A-Za-z0-9]*)\s*\(", source):
        name = match.group(1)
        start = match.end()
        depth, index = 1, start
        while index < len(source) and depth > 0:
            ch = source[index]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            index += 1
        args = source[start:index - 1]
        parts = split_top_level(args)
        if len(parts) < 2:
            continue
        for part in parts:
            if COLORS_REF.search(part):
                line_no = source.count("\n", 0, match.start()) + 1
                findings.append((line_no, name))
                break
    return findings


def main() -> int:
    verbose = "-v" in sys.argv
    theme = read(THEME_FILE)
    interface = interface_keys(theme)
    light = block_keys(theme, "LightColors")
    dark = block_keys(theme, "DarkColors")

    failures = []
    warnings = []

    for name, keys in (("LightColors", light), ("DarkColors", dark)):
        missing = [k for k in interface if k not in keys]
        extra = [k for k in keys if k not in interface]
        if missing:
            failures.append("%s is missing tokens declared in ThemeColors: %s"
                            % (name, ", ".join(missing)))
        if extra:
            failures.append("%s declares tokens absent from ThemeColors: %s"
                            % (name, ", ".join(extra)))
        duplicated = sorted({k for k in keys if keys.count(k) > 1})
        if duplicated:
            failures.append("%s repeats keys: %s" % (name, ", ".join(duplicated)))

    sources = {
        path: comments_stripped(read(path))
        for path in sorted(ETS_DIR.rglob("*.ets"))
        if path != THEME_FILE
    }

    used = set()
    for path, text in sources.items():
        for ref in COLORS_REF.finditer(text):
            token = ref.group(1)
            used.add(token)
            if token not in interface:
                line_no = text.count("\n", 0, ref.start()) + 1
                failures.append("%s:%d references unknown token `%s`"
                                % (path.relative_to(REPO_ROOT), line_no, token))

    unused = [k for k in interface if k not in used]
    if unused:
        warnings.append("tokens never used by any page: %s" % ", ".join(unused))

    for path, text in sources.items():
        for line_no, name in builder_calls_with_colors(text):
            warnings.append("%s:%d passes this.colors.* into %s(...), which is "
                            "passed by value and will not follow theme changes"
                            % (path.relative_to(REPO_ROOT), line_no, name))

    if verbose or failures or warnings:
        print("theme tokens: %d declared, %d used" % (len(interface), len(used)))
        for message in failures:
            print("FAIL  " + message)
        for message in warnings:
            print("warn  " + message)

    if failures:
        return 1
    print("theme tokens OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
