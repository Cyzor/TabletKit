#!/usr/bin/env python3
"""backfill_libwacom_dimensions.py — fill activeWidthMM/Height from libwacom

Reads every Wacom-branded `.tablet` file from a local libwacom checkout, builds
a {PID → (widthMM, heightMM, modelName)} map, then walks
Sources/TabletKit/Registry/WacomDeviceRegistry.swift and inserts `activeWidthMM` /
`activeHeightMM` arguments into entries that don't already have them.

libwacom Width/Height are **manufacturer-advertised drawing-area dimensions
in millimeters**, confirmed via the `wacom.example` file ("Width in mm, as
advertised by the manufacturer ... drawing area, not the full tablet").
They are typically within 1–3% of the precise active-area dimensions we
hand-measure for `.verified` entries — close enough to drive the `lpi`
accessor's cursor-mapping logic, but slightly less precise than a live
capture.  We therefore:

  • never overwrite entries that already declare `activeWidthMM`,
  • leave the existing 6 hand-measured `.verified` entries untouched,
  • clearly mark new entries (via the script's commit message) as
    libwacom-advertised rather than hand-measured.

Usage:
    python3 tools/backfill_libwacom_dimensions.py \\
        --libwacom-data /path/to/libwacom/data [--registry <path>]
    python3 tools/backfill_libwacom_dimensions.py ... --dry-run   # preview only
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import registry_lib as rl


def parse_tablet_file(path: Path) -> tuple[list[int], float | None, float | None, str]:
    """Return (pid_list, widthMM, heightMM, modelName) from a .tablet file."""
    pids: list[int] = []
    width = height = None
    model = ""
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if line.startswith("Width="):
            try:
                width = float(line.split("=", 1)[1].strip())
            except ValueError:
                pass
        elif line.startswith("Height="):
            try:
                height = float(line.split("=", 1)[1].strip())
            except ValueError:
                pass
        elif line.startswith("ModelName="):
            model = line.split("=", 1)[1].strip()
        elif line.startswith("DeviceMatch="):
            # DeviceMatch=usb|056a|0317;bluetooth|056a|0360;
            for tok in line.split("=", 1)[1].split(";"):
                tok = tok.strip()
                if not tok:
                    continue
                parts = tok.split("|")
                # usb|056a|0317  or  bluetooth|056a|0360  or  usb|056a|0357|Wacom Intuos
                if len(parts) >= 3 and parts[0] in ("usb", "bluetooth"):
                    try:
                        vid = int(parts[1], 16)
                        pid = int(parts[2], 16)
                        if vid == rl.WACOM_VID and pid not in pids:
                            pids.append(pid)
                    except ValueError:
                        pass
    return pids, width, height, model


def build_libwacom_map(data_dir: Path) -> dict[int, tuple[float, float, str, str]]:
    """{pid: (widthMM, heightMM, modelName, source_filename)} for all Wacom devices.

    When multiple files cover the same PID (transport variants, alt PIDs),
    later files win — libwacom convention keeps the more-specific match late.
    """
    out: dict[int, tuple[float, float, str, str]] = {}
    for path in sorted(data_dir.glob("wacom-*.tablet")):
        pids, w, h, model = parse_tablet_file(path)
        if w is None or h is None:
            continue
        for pid in pids:
            out[pid] = (w, h, model, path.name)
    return out


PID_LINE = re.compile(r"productID:\s*0x([0-9A-Fa-f]+)")
HAS_DIM = re.compile(r"\bactiveWidthMM:")
MAX_X = re.compile(r"\bmaxX:\s*(\d+)")
MAX_Y = re.compile(r"\bmaxY:\s*(\d+)")


def patch_block(
    lines: list[str], start: int, end: int,
    libwacom: dict[int, tuple[float, float, str, str]]
) -> tuple[bool, str | None]:
    """Inject activeWidthMM/Height into the block.  Returns (changed, reason_skipped)."""
    block = lines[start:end + 1]
    pid_match = None
    max_x: int | None = None
    max_y: int | None = None
    for line in block:
        if pid_match is None:
            m = PID_LINE.search(line)
            if m:
                pid_match = int(m.group(1), 16)
        if max_x is None:
            m = MAX_X.search(line)
            if m:
                max_x = int(m.group(1))
        if max_y is None:
            m = MAX_Y.search(line)
            if m:
                max_y = int(m.group(1))
    if pid_match is None:
        return False, "no productID"

    # Already has dimensions? leave alone.
    if any(HAS_DIM.search(l) for l in block):
        return False, "already has activeWidthMM"

    if pid_match not in libwacom:
        return False, f"PID 0x{pid_match:04X} not in libwacom"

    w, h, model, src = libwacom[pid_match]

    # If our maxX/maxY and libwacom's size imply different resolutions on the
    # two axes, they probably describe different devices that share a PID
    # (Wacom reuses PIDs across product lines). Skip loudly so whoever reads
    # the dry run can look into it. Same measure the registry tests use.
    disagreement = rl.lpi_disagreement(
        {"maxX": max_x, "maxY": max_y, "activeWidthMM": w, "activeHeightMM": h})
    if disagreement is not None and disagreement > rl.LPI_TOLERANCE:
        return False, (
            f"LPI mismatch PID 0x{pid_match:04X}: "
            f"X={rl.axis_lpi(max_x, w):.0f} Y={rl.axis_lpi(max_y, h):.0f} "
            f"({disagreement * 100:.1f}%) — our entry and {src} likely describe different devices"
        )

    # Keep the dimensions on the same line as the closing `)`, the convention
    # every other entry follows (`activeWidthMM: X, activeHeightMM: Y),`).
    last = lines[end]
    last_paren = last.rfind(")")
    if last_paren < 0:
        return False, "no closing paren on final line"

    insert = f", activeWidthMM: {w:g}, activeHeightMM: {h:g}"
    lines[end] = last[:last_paren] + insert + last[last_paren:]
    return True, f"PID 0x{pid_match:04X}: {w:g} × {h:g} mm ({src})"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--libwacom-data", required=True, type=Path,
                    help="Path to libwacom data/ directory")
    ap.add_argument("--registry", type=Path, default=rl.DEFAULT_REGISTRY,
                    help="Path to WacomDeviceRegistry.swift (default: this checkout's)")
    ap.add_argument("--dry-run", action="store_true",
                    help="Print proposed changes without writing the file")
    args = ap.parse_args()

    if not args.libwacom_data.is_dir():
        print(f"error: libwacom data dir not found: {args.libwacom_data}", file=sys.stderr)
        return 1
    if not args.registry.is_file():
        print(f"error: registry file not found: {args.registry}", file=sys.stderr)
        return 1

    libwacom = build_libwacom_map(args.libwacom_data)
    print(f"# libwacom map: {len(libwacom)} Wacom PIDs covered", file=sys.stderr)

    lines = args.registry.read_text(encoding="utf-8").split("\n")

    # The shared walker's end index is one past the block; patch_block's is inclusive.
    blocks = [(start, end - 1) for start, end, _ in rl.iter_init_blocks(lines)]
    print(f"# found {len(blocks)} .init(...) blocks in registry", file=sys.stderr)

    changed_blocks = 0
    skipped_no_pid = 0
    skipped_already = 0
    skipped_no_libwacom = 0
    skipped_lpi = 0
    for start, end in blocks:
        ok, reason = patch_block(lines, start, end, libwacom)
        if ok:
            changed_blocks += 1
            print(f"  + {reason}", file=sys.stderr)
        else:
            if reason and reason.startswith("already"):
                skipped_already += 1
            elif reason and reason.startswith("PID 0x"):
                skipped_no_libwacom += 1
            elif reason and reason.startswith("LPI mismatch"):
                print(f"  ! SKIP: {reason}", file=sys.stderr)
                skipped_lpi += 1
            else:
                skipped_no_pid += 1

    print(f"# proposed updates: {changed_blocks} entries", file=sys.stderr)
    print(f"# skipped (already filled): {skipped_already}", file=sys.stderr)
    print(f"# skipped (PID not in libwacom): {skipped_no_libwacom}", file=sys.stderr)
    print(f"# skipped (LPI sanity mismatch): {skipped_lpi}", file=sys.stderr)
    print(f"# skipped (no productID found): {skipped_no_pid}", file=sys.stderr)

    if args.dry_run:
        print("# dry-run: no file written", file=sys.stderr)
        return 0

    args.registry.write_text("\n".join(lines), encoding="utf-8")
    print(f"# wrote {args.registry}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
