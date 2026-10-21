#!/usr/bin/env python3
"""import_vendor_configs.py — OTD → VendorDeviceProfile importer

Parses OpenTabletDriver Configurations/<Vendor>/*.json files and emits Swift
`VendorDeviceProfile(...)` entries for non-Wacom vendors.

Unlike `import_otd_configs.py` (which targets Wacom devices in the full
`WacomDeviceSpec` shape with decoder-bound fields), this script produces the
recognition-only shape used by `VendorDeviceRegistry` for devices we name but
don't yet decode.

Usage:
    python3 tools/import_vendor_configs.py [OTD Configurations dir] \\
        --vendors Huion Xencelabs XP-Pen

The directory defaults to the OpenTabletDriver clone under upstream/ (see
registry_lib). Output goes to stdout — pipe into VendorDeviceRegistry.swift's
`knownDevices` array (between the `// BEGIN GENERATED` / `// END GENERATED`
markers).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import registry_lib as rl


def short_parser(otd_class: str | None) -> str | None:
    """Reduce 'OpenTabletDriver.Configurations.Parsers.UCLogic.UCLogicTiltReportParser'
    to 'UCLogicTiltReportParser' — the trailing class name is the useful bit."""
    if not otd_class:
        return None
    return otd_class.rsplit(".", 1)[-1]


def parse_config(path: Path, vendor: str) -> list[dict]:
    """Parse one OTD JSON file into zero-or-more profile dicts.

    A single config can declare multiple `DigitizerIdentifiers` (one per
    transport / report-length variant); each becomes its own profile so the
    registry lookup can find the device regardless of which variant the OS
    enumerates.
    """
    try:
        with path.open() as f:
            cfg = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(f"# WARN: skipped {path.name}: {e}", file=sys.stderr)
        return []

    name = cfg.get("Name", path.stem)
    specs = cfg.get("Specifications", {}) or {}
    dig = specs.get("Digitizer", {}) or {}
    pen = specs.get("Pen", {}) or {}
    aux = specs.get("AuxiliaryButtons", {}) or {}

    profiles = []
    seen_pids: set[tuple[int, int]] = set()  # (vid, pid)
    for ident in cfg.get("DigitizerIdentifiers", []) or []:
        vid = ident.get("VendorID")
        pid = ident.get("ProductID")
        if vid is None or pid is None:
            continue
        # Multiple identifiers in one file often re-declare the same (vid, pid)
        # with different InputReportLength — collapse them; the recognition
        # layer doesn't need the per-length distinction.
        if (vid, pid) in seen_pids:
            continue
        seen_pids.add((vid, pid))

        # DeviceStrings is a dict keyed by descriptor index ("201", "200", …).
        # The #201 string holds Huion's firmware family regex ("HUION_T194_…");
        # we keep the first non-empty entry as the disambiguator hint.
        device_strings = ident.get("DeviceStrings", {}) or {}
        regex = None
        for key in ("201", "200", "100"):
            v = device_strings.get(key)
            if v:
                regex = v
                break

        profiles.append({
            "vendor": vendor,
            "vendorID": vid,
            "productID": pid,
            "productName": name,
            "activeWidthMM": dig.get("Width"),
            "activeHeightMM": dig.get("Height"),
            "maxX": dig.get("MaxX"),
            "maxY": dig.get("MaxY"),
            "maxPressure": pen.get("MaxPressure"),
            "penButtonCount": pen.get("ButtonCount"),
            "auxButtonCount": aux.get("ButtonCount"),
            "otdParser": short_parser(ident.get("ReportParser")),
            "productStringRegex": regex,
        })
    return profiles


def emit_swift(profiles: list[dict]) -> str:
    """Render profiles as Swift `.init(...)` entries, one per line block."""
    s, i, d = rl.swift_string, rl.swift_int, rl.swift_double
    lines = []
    for p in sorted(profiles, key=lambda x: (x["vendor"], x["productID"], x["productName"])):
        lines.append("        VendorDeviceProfile(")
        lines.append(f'            vendor: {s(p["vendor"])},')
        lines.append(f'            vendorID: 0x{p["vendorID"]:04X}, productID: 0x{p["productID"]:04X},')
        lines.append(f'            productName: {s(p["productName"])},')
        lines.append(f'            activeWidthMM: {d(p["activeWidthMM"])}, '
                     f'activeHeightMM: {d(p["activeHeightMM"])},')
        lines.append(f'            maxX: {i(p["maxX"])}, maxY: {i(p["maxY"])},')
        lines.append(f'            maxPressure: {i(p["maxPressure"])},')
        lines.append(f'            penButtonCount: {i(p["penButtonCount"])}, '
                     f'auxButtonCount: {i(p["auxButtonCount"])},')
        lines.append(f'            otdParser: {s(p["otdParser"])},')
        lines.append(f'            productStringRegex: {s(p["productStringRegex"])}),')
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("configs_root", type=Path, nargs="?", default=rl.DEFAULT_OTD,
                        help="Path to OTD .../Configurations/ directory")
    parser.add_argument("--vendors", nargs="+", required=True,
                        help="Vendor folder names to import (case-sensitive)")
    args = parser.parse_args()

    if not args.configs_root.is_dir():
        print(f"error: not a directory: {args.configs_root}", file=sys.stderr)
        return 1

    all_profiles: list[dict] = []
    for vendor in args.vendors:
        vendor_dir = args.configs_root / vendor
        if not vendor_dir.is_dir():
            print(f"# WARN: vendor folder not found: {vendor_dir}", file=sys.stderr)
            continue
        count_before = len(all_profiles)
        for cfg_path in sorted(vendor_dir.glob("*.json")):
            all_profiles.extend(parse_config(cfg_path, vendor))
        print(f"# {vendor}: {len(all_profiles) - count_before} profiles "
              f"from {len(list(vendor_dir.glob('*.json')))} files",
              file=sys.stderr)

    print(emit_swift(all_profiles))
    print(f"# total profiles: {len(all_profiles)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
