#!/usr/bin/env python3
"""check-public-api.py — compare TabletKit's public symbols with public-api.txt.

On the next branch the public API should only shrink. CI runs this there and
fails when a public symbol isn't in public-api.txt, so every addition is a
deliberate edit to that file, made in the same commit. Removals fail too, so
the file stays exact; rerun with --update to record them.

Only symbols declared in TabletKit's source count. Members the compiler
synthesizes (operators, hash(into:), Codable) vary between toolchains.

    python3 tools/check-public-api.py            # check
    python3 tools/check-public-api.py --update   # rewrite public-api.txt
"""
import atexit
import glob
import json
import pathlib
import shutil
import subprocess
import tempfile
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIST = ROOT / "public-api.txt"
HEADER = (
    "# TabletKit's public symbols, one per line: kind, then path.\n"
    "# Written by tools/check-public-api.py --update. Additions are deliberate;\n"
    "# say why in the commit.\n"
)


def current_symbols():
    # The compiler writes the graphs only when it compiles, so build into a
    # fresh scratch directory. `swift package dump-symbol-graph` also asks
    # for the test module, which some toolchains can't load.
    scratch = tempfile.mkdtemp()
    atexit.register(shutil.rmtree, scratch, ignore_errors=True)
    graphs = pathlib.Path(scratch) / "graphs"
    graphs.mkdir()
    subprocess.run(
        ["swift", "build", "--target", "TabletKit", "--scratch-path", f"{scratch}/build",
         "-Xswiftc", "-emit-symbol-graph", "-Xswiftc", "-emit-symbol-graph-dir", "-Xswiftc", str(graphs)],
        cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    paths = glob.glob(str(graphs / "TabletKit*.symbols.json"))
    if not paths:
        sys.exit("check-public-api: no TabletKit symbol graph found")
    found = set()
    for path in paths:
        for s in json.load(open(path))["symbols"]:
            if s.get("accessLevel") not in ("public", "open") or not s.get("location"):
                continue
            kind = s["kind"]["identifier"].removeprefix("swift.")
            found.add(f"{kind} {'.'.join(s['pathComponents'])}")
    return found


def main():
    found = current_symbols()
    if "--update" in sys.argv:
        LIST.write_text(HEADER + "".join(f"{line}\n" for line in sorted(found)))
        print(f"check-public-api: wrote {len(found)} symbols to {LIST.name}")
        return
    listed = {line for line in LIST.read_text().splitlines() if line and not line.startswith("#")}
    added, removed = sorted(found - listed), sorted(listed - found)
    for line in added:
        print(f"added:   {line}")
    for line in removed:
        print(f"removed: {line}")
    if added or removed:
        sys.exit(f"check-public-api: {len(added)} added, {len(removed)} removed. "
                 "If intended, run tools/check-public-api.py --update and commit public-api.txt.")
    print(f"check-public-api: {len(found)} public symbols, matching {LIST.name}")


main()
