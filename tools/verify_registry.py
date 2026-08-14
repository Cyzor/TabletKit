#!/usr/bin/env python3
"""verify_registry.py — Cross-reference WacomDeviceRegistry against canonical sources.

Compares every entry in TabletKit/Sources/TabletKit/Registry/WacomDeviceRegistry.swift
against:
  • Linux input-wacom feature structs (kernel canonical)
  • OpenTabletDriver JSON configs (community canonical)

Emits a CSV with one row per registry PID, columns:
  pid, registry_name, registry_parser, registry_maxX/maxY/maxP,
  kernel_maxX/maxY/maxP/type, otd_maxX/maxY/maxP/parser,
  verdict, notes

Verdicts:
  agree            — kernel and registry match (dims within tolerance)
  cross_referenced — kernel and OTD agree with each other and with registry
  kernel_disagrees — kernel has different dims; per project convention kernel wins
  otd_disagrees    — OTD has different dims; less authoritative than kernel
  kernel_only      — kernel has it, OTD doesn't
  otd_only         — OTD has it, kernel doesn't (newer hardware, typically)
  name_only        — registry carries no dims at all (no decoder for the family);
                     nothing to compare, so this is not a disagreement.  Matches
                     the registry's own "Name-only:" section comments.  Beware:
                     audit_registry.py counts a "name-only" bucket meaning
                     something else entirely — rows where *only the name* differs
                     from the kernel's.  Same phrase, unrelated measure.
  unknown          — neither source has the PID
  registry_only    — see "unknown"

Every path argument defaults to the standard in-repo layout, so the common case
is just:

    python3 tools/verify_registry.py

Or point it elsewhere:

    python3 tools/verify_registry.py \\
        --registry  TabletKit/Sources/TabletKit/Registry/WacomDeviceRegistry.swift \\
        --kernel    /path/to/input-wacom/4.18/wacom_wac.c \\
        --otd       /path/to/OpenTabletDriver/Configurations \\
        --out       registry_audit.csv
"""

import argparse
import csv
import sys
from typing import Optional

import registry_lib as rl

DIM_TOLERANCE = 0  # exact match required for now; bump to 50 if rounding noise appears

# Intuos 1 and Intuos 2: the kernel's wacom_features maxX/maxY are half of what
# our decoder emits, so a raw comparison reports a spurious 2x disagreement on
# all eleven PIDs.  IntuosV1Decoder.decodeUSBPen packs an extra low-order bit
# per axis (`(hi << 8 | lo) << 1 | fractional`), giving 5080 lpi output units
# against the kernel's 2540 lpi figures.  OTD's IntuosV1TabletReport.cs does the
# same and its configs carry the doubled maxima, which is why OTD agrees with us
# and only the kernel appears to disagree.
#
# This is load-bearing, not cosmetic: issue #5 ("screen area coverage too small")
# was these rows carrying the un-doubled values, fixed 2026-08-03.  Without this
# scaling the audit re-proposes that regression on every run.  See
# Notes/Wacom-HID-GD-0608-U-Reference.md for the manual + OTD cross-check.
KERNEL_HALF_SCALE_PIDS = frozenset({
    0x0020, 0x0021, 0x0022, 0x0023, 0x0024,          # Intuos 1  (GD-*-U)
    0x0041, 0x0042, 0x0043, 0x0044, 0x0045, 0x0047,  # Intuos 2  (XD-*-U)
})

# Ten of those rows still report otd_disagrees after scaling, on pressure alone:
# OTD carries 2046 where we carry 1023.  That one is adjudicated, not open —
# Wacom's GD-series manual specifies 1024 levels (10-bit), and an earlier draft
# of our own notes was corrected for exactly this "11-bit" error.  OTD looks to
# have applied the coordinate doubling to pressure too.  Deliberately not
# whitelisted: the rows should keep failing, because the dimensions agreeing is
# not on its own grounds to promote them.

# ── Upstream + registry parsing ───────────────────────────────────────────────
#
# All four parsers live in registry_lib so every tools/ script sees the same
# data.  The thin wrappers below only rename fields to the column names this
# script's CSV has always used.

WACOM_VID = rl.WACOM_VID


def parse_kernel(path: str) -> dict:
    """Return {pid_int: {"name", "maxX", "maxY", "maxP", "type"}}."""
    return {
        pid: {
            "name": k["name"], "maxX": k["maxX"], "maxY": k["maxY"],
            "maxP": k["maxPressure"], "type": k["type"],
        }
        for pid, k in rl.parse_kernel(path).items()
    }


def parse_otd(directory: str) -> dict:
    """Return {pid_int: {"name", "maxX", "maxY", "maxP", "parser"}}."""
    return rl.parse_otd(directory)


def parse_registry(path: str) -> list:
    """Return one row per registry entry, in file order."""
    return [
        {
            "pid": e["pid"], "name": e["name"], "parser": e["parser"],
            "maxX": e["maxX"] or 0, "maxY": e["maxY"] or 0,
            "maxP": e["maxPressure"] or 0,
            "confidence": e["confidence"],
        }
        for e in rl.parse_registry(path)
    ]


# ── Kernel type → MockTab parser family ──────────────────────────────────────

KERNEL_TYPE_TO_PARSER = {
    "PENPARTNER": "graphire", "GRAPHIRE": "graphire", "GRAPHIRE_BT": "graphire",
    "G4": "graphire", "PTU": "graphire",
    "BAMBOO_PT": "bamboo", "BAMBOO_PEN": "bamboo", "BAMBOO_TOUCH": "bamboo",
    "INTUOS": "intuosV1", "INTUOSL": "intuosV1", "INTUOSS": "intuosV1",
    "INTUOSPL": "intuosV1", "INTUOSPM": "intuosV1", "INTUOSPS": "intuosV1",
    "INTUOSHT": "intuosV1", "INTUOSHT2": "intuosV1", "INTUOSHT3_BT": "intuosV1",
    "INTUOS3": "intuos3", "INTUOS3S": "intuos3", "INTUOS3L": "intuos3",
    "INTUOS4": "intuosV1", "INTUOS4S": "intuosV1", "INTUOS4L": "intuosV1",
    "INTUOS4WL": "intuosV1", "INTUOS5": "intuosV1", "INTUOS5S": "intuosV1",
    "INTUOS5L": "intuosV1",
    "INTUOSP2_BT": "intuosV2", "INTUOSP2S_BT": "intuosV2",
    "WACOM_24HD": "cintiqV1", "WACOM_24HDT": "cintiqV1",
    "WACOM_22HD": "cintiqV1", "WACOM_21UX2": "cintiqV1",
    "WACOM_BEE": "cintiqV1", "CINTIQ": "cintiqV1", "CINTIQ_COMPANION_2": "cintiqV1",
    "DTUS": "graphire", "DTUSX": "graphire", "DTU": "graphire",
}


def map_kernel_parser(t: str) -> Optional[str]:
    if not t:
        return None
    if t in KERNEL_TYPE_TO_PARSER:
        return KERNEL_TYPE_TO_PARSER[t]
    return None


# OTD class-name suffix → parser (mirrors import_otd_configs.py)
OTD_TYPE_TO_PARSER = {
    "IntuosReportParser": "intuosV1",
    "IntuosV1ReportParser": "intuosV1",
    "WacomDriverIntuosReportParser": "intuosV1",
    "WacomDriverIntuosV1ReportParser": "intuosV1",
    "Intuos3ReportParser": "intuos3",
    "WacomDriverIntuos3ReportParser": "intuos3",
    "Intuos3ExtraAuxReportParser": "intuos3",
    "CintiqV1ReportParser": "cintiqV1",
    "IntuosV2ReportParser": "intuosV2",
    "WacomDriverIntuosV2ReportParser": "intuosV2",
    "IntuosV3ReportParser": "intuosV2",
    "BambooReportParser": "bamboo",
    "BambooPadReportParser": "bamboo",
    "GraphireReportParser": "graphire",
    "WacomDriverlessTablet": "graphire",
    "WacomDriverless": "graphire",
}


def map_otd_parser(name: str) -> Optional[str]:
    if not name:
        return None
    if name in OTD_TYPE_TO_PARSER:
        return OTD_TYPE_TO_PARSER[name]
    return None


# ── Verdict computation ──────────────────────────────────────────────────────

def dims_agree(a, b) -> bool:
    if a is None or b is None:
        return False
    return (
        abs(a["maxX"] - b["maxX"]) <= DIM_TOLERANCE
        and abs(a["maxY"] - b["maxY"]) <= DIM_TOLERANCE
        and a["maxP"] == b["maxP"]
    )


def scale_kernel_dims(pid, kern):
    """Put kernel dims into our decoder's output units.

    Returns (kern, note).  Only the Intuos 1/2 rows need this; everything else
    passes through untouched.  The CSV keeps reporting the kernel's raw figures,
    so the note is what explains why a doubled registry row still reads as
    agreeing.
    """
    if kern is None or pid not in KERNEL_HALF_SCALE_PIDS:
        return kern, ""
    scaled = dict(kern)
    scaled["maxX"] = kern["maxX"] * 2
    scaled["maxY"] = kern["maxY"] * 2
    return scaled, ("kernel dims doubled to 5080 lpi decoder units "
                    "(Intuos 1/2 fractional-bit packing)")


def is_name_only(reg) -> bool:
    """True when a registry row carries no dimensions at all.

    Twenty-five rows are deliberately dimensionless — the PL / DTF / DTU-710
    families and the ISDv4 built-ins, whose report formats have no decoder here.
    Their kernel figures live in comments beside them, waiting for a decoder to
    land.  Comparing 0 against a real kernel maximum is not a disagreement, it
    is an absence, and reporting sixteen of them as `kernel_disagrees` every run
    buried the three rows that genuinely conflict.

    Note this is deliberately *not* the same treatment as the Intuos 1/2 and
    Intuos3 pressure rows above.  Those carry real dims and a real conflict and
    are meant to keep failing; see the comment on KERNEL_HALF_SCALE_PIDS.  This
    only reclassifies rows that have nothing to compare in the first place.
    """
    return reg["maxX"] == 0 and reg["maxY"] == 0 and reg["maxP"] == 0


def _name_only_notes(kern, otd) -> str:
    """Report what upstream has, so the row doubles as a decoder to-do list."""
    available = []
    for src, label in ((kern, "kernel"), (otd, "OTD")):
        if src:
            available.append(
                f"{label} has maxX={src['maxX']} maxY={src['maxY']} maxP={src['maxP']}"
            )
    if not available:
        return "registry carries no dims; neither kernel nor OTD has this PID either"
    return ("registry carries no dims (no decoder for this family); "
            + "; ".join(available) + " if one lands")


def compute_verdict(pid, reg, kern, otd) -> tuple[str, str]:
    """Return (verdict, notes)."""
    if is_name_only(reg):
        return ("name_only", _name_only_notes(kern, otd))

    if not kern and not otd:
        return ("unknown", "neither kernel nor OTD has this PID")

    kern, scale_note = scale_kernel_dims(pid, kern)
    if scale_note:
        verdict, notes = _compute_verdict(reg, kern, otd)
        return (verdict, f"{scale_note}; {notes}" if notes else scale_note)
    return _compute_verdict(reg, kern, otd)


def _compute_verdict(reg, kern, otd) -> tuple[str, str]:

    if kern and otd:
        if dims_agree(reg, kern) and dims_agree(reg, otd):
            # Two independent canonical sources concur; flag for promotion.
            return ("cross_referenced", "kernel + OTD both agree with registry")
        if dims_agree(reg, kern):
            return ("otd_disagrees", _diff_notes(reg, otd, "OTD"))
        if dims_agree(reg, otd):
            return ("kernel_disagrees", _diff_notes(reg, kern, "kernel"))
        return ("kernel_disagrees", "registry differs from BOTH kernel AND OTD: " + _diff_notes(reg, kern, "kernel"))

    if kern:
        if dims_agree(reg, kern):
            return ("agree", "kernel agrees; OTD has no entry")
        return ("kernel_disagrees", _diff_notes(reg, kern, "kernel"))

    # otd only
    if dims_agree(reg, otd):
        return ("otd_only", "OTD agrees; kernel has no entry")
    return ("otd_disagrees", _diff_notes(reg, otd, "OTD") + "; kernel has no entry")


def _diff_notes(reg, src, label):
    parts = []
    if reg["maxX"] != src["maxX"]:
        parts.append(f"{label} maxX={src['maxX']} (registry {reg['maxX']})")
    if reg["maxY"] != src["maxY"]:
        parts.append(f"{label} maxY={src['maxY']} (registry {reg['maxY']})")
    if reg["maxP"] != src["maxP"]:
        parts.append(f"{label} maxP={src['maxP']} (registry {reg['maxP']})")
    return "; ".join(parts) if parts else f"{label} agrees on dims"


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--registry", default=str(rl.DEFAULT_REGISTRY),
                   help="path to WacomDeviceRegistry.swift")
    p.add_argument("--kernel", default=str(rl.DEFAULT_KERNEL),
                   help="path to input-wacom wacom_wac.c")
    p.add_argument("--otd", default=str(rl.DEFAULT_OTD),
                   help="path to the OTD Configurations tree (searched recursively)")
    p.add_argument("--out", default="registry_audit.csv", help="output CSV path")
    args = p.parse_args()

    registry = parse_registry(args.registry)
    kernel = parse_kernel(args.kernel)
    otd = parse_otd(args.otd)

    print(f"Loaded {len(registry)} registry entries, "
          f"{len(kernel)} kernel features, "
          f"{len(otd)} OTD entries.", file=sys.stderr)

    rows = []
    counts = {}
    for reg in registry:
        pid = reg["pid"]
        kern = kernel.get(pid)
        otd_e = otd.get(pid)
        verdict, notes = compute_verdict(pid, reg, kern, otd_e)
        counts[verdict] = counts.get(verdict, 0) + 1

        # parser comparison
        parser_match = []
        if kern and kern.get("type"):
            kp = map_kernel_parser(kern["type"])
            if kp and kp != reg["parser"]:
                parser_match.append(f"kernel parser={kp} (kernel type {kern['type']})")
        if otd_e:
            op = map_otd_parser(otd_e.get("parser", ""))
            if op and op != reg["parser"]:
                parser_match.append(f"OTD parser={op} (OTD class {otd_e['parser']})")
        if parser_match:
            notes = (notes + "; " if notes else "") + "; ".join(parser_match)

        rows.append({
            "pid": f"0x{pid:04X}",
            "registry_name": reg["name"],
            "registry_parser": reg["parser"],
            "registry_maxX": reg["maxX"], "registry_maxY": reg["maxY"], "registry_maxP": reg["maxP"],
            "registry_confidence": reg["confidence"],
            "kernel_name": kern["name"] if kern else "",
            "kernel_maxX": kern["maxX"] if kern else "",
            "kernel_maxY": kern["maxY"] if kern else "",
            "kernel_maxP": kern["maxP"] if kern else "",
            "kernel_type": kern["type"] if kern else "",
            "otd_name": otd_e["name"] if otd_e else "",
            "otd_maxX": otd_e["maxX"] if otd_e else "",
            "otd_maxY": otd_e["maxY"] if otd_e else "",
            "otd_maxP": otd_e["maxP"] if otd_e else "",
            "otd_parser": otd_e["parser"] if otd_e else "",
            "verdict": verdict,
            "notes": notes,
        })

    # PIDs in kernel/OTD that registry doesn't have
    reg_pids = {r["pid"] for r in registry}
    for pid in sorted((set(kernel) | set(otd)) - reg_pids):
        kern = kernel.get(pid)
        otd_e = otd.get(pid)
        rows.append({
            "pid": f"0x{pid:04X}",
            "registry_name": "<missing>",
            "registry_parser": "",
            "registry_maxX": "", "registry_maxY": "", "registry_maxP": "",
            "registry_confidence": "",
            "kernel_name": kern["name"] if kern else "",
            "kernel_maxX": kern["maxX"] if kern else "",
            "kernel_maxY": kern["maxY"] if kern else "",
            "kernel_maxP": kern["maxP"] if kern else "",
            "kernel_type": kern["type"] if kern else "",
            "otd_name": otd_e["name"] if otd_e else "",
            "otd_maxX": otd_e["maxX"] if otd_e else "",
            "otd_maxY": otd_e["maxY"] if otd_e else "",
            "otd_maxP": otd_e["maxP"] if otd_e else "",
            "otd_parser": otd_e["parser"] if otd_e else "",
            "verdict": "missing_from_registry",
            "notes": "kernel and/or OTD know this PID; registry does not",
        })
        counts["missing_from_registry"] = counts.get("missing_from_registry", 0) + 1

    fieldnames = list(rows[0].keys()) if rows else []
    with open(args.out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(rows)

    print(f"\nWrote {args.out} with {len(rows)} rows.\n", file=sys.stderr)
    print("Verdict summary:", file=sys.stderr)
    for v in sorted(counts.keys()):
        print(f"  {v:24s} {counts[v]}", file=sys.stderr)


if __name__ == "__main__":
    main()
