#!/usr/bin/env python3
"""export_registry_json.py — emit WacomDeviceRegistry as versioned JSON.

TabletKit's device registry only exists as Swift (`WacomDeviceRegistry.swift`),
which means a non-Swift consumer — a script, a website, another platform's
driver — can't read it without either a Swift toolchain or its own from-scratch
parser. OpenTabletDriver's per-vendor JSON configs are the model worth
borrowing here (see `TabletKit-Public-API-Design.md`, §5 item 5): a
versioned, machine-readable snapshot alongside the Swift source, not a
replacement for it. `registry_lib.py` already parses the Swift for the audit
scripts, so this is a serialization step, not a redesign.

Regenerate after any registry edit:

    python3 tools/export_registry_json.py

Output is committed (`registry.json` at the TabletKit repo root), same
convention as `registry_audit.csv` — a generated artifact checked in so
consumers without Python/Swift tooling can still read it.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import registry_lib as rl

SCHEMA_VERSION = 1

# Fields carried through verbatim from registry_lib's parsed entry dict.
# "line" and "hasInitSteps" are maintenance-script bookkeeping, not part of
# the device's own data, and are deliberately excluded. This is a projection
# of WacomDeviceSpec, not the full struct: registry_lib doesn't yet parse
# hasDualRings/hasTouchStrips/ringSlotCount/hasTilt/initSteps/ledCompanionPID,
# so neither does this export.
_FIELDS = (
    "name", "parser", "confidence", "productStringMatch",
    "maxX", "maxY", "maxPressure", "buttonCount",
    "maxTouchContacts", "touchMaxX", "touchMaxY",
    "hasTouchRing", "hasEraser", "hasFingerTouch", "isPenDisplay", "seizeUSB",
    "activeWidthMM", "activeHeightMM",
)

# registry_lib reports a field as None when a Swift call site omits it — which
# for a field with a non-nil Swift default means "took the default," not
# "unknown." Resolve those here so a consumer without WacomDeviceSpec's own
# doc comments in front of them doesn't misread omitted-but-defaulted as
# unset. Fields not listed here either have no default (always present) or a
# genuinely meaningful nil default (activeWidthMM/activeHeightMM: "unknown";
# productStringMatch: "match any") — those stay null as parsed.
_SWIFT_DEFAULTS = {
    "maxTouchContacts": 0,
    "touchMaxX": 0,
    "touchMaxY": 0,
    "hasFingerTouch": False,
    "isPenDisplay": False,
}


def build_document(entries: list[dict]) -> dict:
    devices = []
    for e in entries:
        device = {"productID": f"0x{e['pid']:04X}"}
        for f in _FIELDS:
            value = e.get(f)
            if value is None and f in _SWIFT_DEFAULTS:
                value = _SWIFT_DEFAULTS[f]
            device[f] = value
        devices.append(device)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "vendorID": "0x056A",
        "note": (
            "Generated from WacomDeviceRegistry.swift by "
            "tools/export_registry_json.py — do not hand-edit. Field meanings "
            "match the doc comments on WacomDeviceSpec in that file."
        ),
        "deviceCount": len(devices),
        "devices": devices,
    }


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--registry", default=rl.DEFAULT_REGISTRY,
        help="path to WacomDeviceRegistry.swift")
    p.add_argument(
        "--out", default=str(rl.ROOT / "registry.json"),
        help="output JSON path")
    args = p.parse_args()

    entries = rl.parse_registry(args.registry)
    doc = build_document(entries)

    out_path = Path(args.out)
    out_path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {doc['deviceCount']} devices to {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
