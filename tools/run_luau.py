#!/usr/bin/env python3
"""Run pure shared Luau modules (BigNumber, NumberFormat, EconomyMath...) under the stock `luau` CLI.

Roblox-style `require(script.Parent.X)` paths are rewritten to CLI string requires in a temp copy.
Usage: python3 tools/run_luau.py tests/BigNumber.spec.luau [more files...]
       LUAU=/path/to/luau python3 tools/run_luau.py tools/sim.luau
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REQUIRE = re.compile(r"require\(script((?:\.Parent)+)((?:\.\w+)+)\)")


def rewrite(source: str) -> str:
    def repl(match: re.Match) -> str:
        parents = match.group(1).count(".Parent")
        names = match.group(2).lstrip(".").split(".")
        prefix = "./" if parents == 1 else "../" * (parents - 1)
        return 'require("%s%s")' % (prefix, "/".join(names))

    return REQUIRE.sub(repl, source)


def main() -> int:
    luau = os.environ.get("LUAU", shutil.which("luau") or "/tmp/tools/luau")
    build = tempfile.mkdtemp(prefix="luau-build-")
    for folder in ("src/shared", "src/server/Modules", "tests", "tools"):
        src_dir = os.path.join(ROOT, folder)
        dst_dir = os.path.join(build, "server/Modules" if folder == "src/server/Modules" else os.path.basename(folder))
        for dirpath, _, files in os.walk(src_dir):
            for name in files:
                if not name.endswith(".luau"):
                    continue
                src = os.path.join(dirpath, name)
                dst = os.path.join(dst_dir, os.path.relpath(src, src_dir))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                with open(src, encoding="utf-8") as f:
                    text = f.read()
                with open(dst, "w", encoding="utf-8") as f:
                    f.write(rewrite(text))
    status = 0
    for target in sys.argv[1:]:
        path = os.path.join(build, target.replace("src/shared", "shared"))
        print("==> %s" % target, flush=True)
        status |= subprocess.call([luau, path])
    shutil.rmtree(build, ignore_errors=True)
    return status


if __name__ == "__main__":
    sys.exit(main())
