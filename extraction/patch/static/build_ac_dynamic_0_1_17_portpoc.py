#!/usr/bin/env python3
"""Build ac_0.1.17-portpoc: probe the two AC mechanisms the sparse directory needs.

Why a separate throwaway build
------------------------------
The sparse-directory plan replaces the 64 KiB dense slot table (40 % of the
first-dialogue bytes) with a 6 KiB list the helper scatters into AC at init.
That needs two things this project has never actually exercised:

    1. writing a run of bytes through an AC data port under auto-increment
       (everything so far only *read* through a port, or let the BIOS write
        into the bank $40 window)
    2. a second independent port at $1A10, so the scatter can read the list
       and write the directory without re-pointing one port twice per entry

Guessing here would repeat a mistake this project has already made several
times, so both are probed in isolation before any of the real work is written.

What this build does
--------------------
ac_0.1.14 exactly, plus about 70 bytes that run once when the directory is
first initialised:

    port 0 -> AC $180000   writes 0,1,2 ... 15 by storing to $1A00
    port 1 -> AC $180200   writes 0,1,2 ... 15 by storing to $1A10

Both targets are far outside anything the packs use, so a failure cannot
corrupt game data.  `UI 0.1.74.lua` reads them back.

Reading the result
------------------
    both patterns present   sparse directory is viable as designed
    port 0 only             viable, but the scatter must re-point one port
                            twice per entry (slower, and ~15 bytes more code)
    neither                 port writes do not auto-increment; fall back to
                            2-byte directory entries (64 KiB -> 32 KiB)

This build is a probe, not a candidate.  ac_0.1.14 remains the tested build.
"""

from __future__ import annotations

import csv
import json
import shutil
import sys
from pathlib import Path


ROOT = Path(r"C:\snatcher")
STATIC = ROOT / "extraction" / "patch" / "static"
sys.path.insert(0, str(STATIC))

import build_ac_dynamic_0_1_14 as compact  # noqa: E402


assignment = compact.assignment
dynamic = compact.dynamic

VERSION = "ac_0.1.17-portpoc"

compact.PORT_POC = True
compact.CHUNK_BYTES = 0x2000        # keep the verified 8 KiB chunk
dynamic.CHUNK_BYTES = 0x2000
dynamic.VERSION = VERSION
dynamic.OUT = ROOT / "build" / "patch" / VERSION


if __name__ == "__main__":
    dynamic.main()

    manifest_path = dynamic.OUT / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["port_probe"] = {
        "purpose": "verify AC port auto-increment writes and a second port at $1A10",
        "port0_data": 0x1A00,
        "port0_target_ac": f"{compact.POC_PORT0_AC:06X}",
        "port1_data": 0x1A10,
        "port1_target_ac": f"{compact.POC_PORT1_AC:06X}",
        "pattern": "0,1,2,...,%d" % (compact.POC_LENGTH - 1),
        "throwaway": True,
    }
    manifest["helper_free_bytes"] = compact.build_helper_compact.free_bytes
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    with (dynamic.OUT / "runtime_scene_assignment.tsv").open(
            "w", encoding="utf-8-sig", newline="") as handle:
        fields = ("reference", "scene", "method", "runtime_seq", "scene_seq",
                  "sequence_distance", "catalog")
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t")
        writer.writeheader()
        writer.writerows(assignment.RUNTIME_EVIDENCE)
    shutil.copy2(
        ROOT / "lua" / "UI 0.1.74.lua",
        dynamic.OUT / "UI 0.1.74.lua")

    print(f"\nport probe      : $1A00 -> AC ${compact.POC_PORT0_AC:06X}, "
          f"$1A10 -> AC ${compact.POC_PORT1_AC:06X}")
    print(f"helper code     : {manifest['helper_code_bytes']} B "
          f"({manifest['helper_free_bytes']} B free)")
    print("run UI 0.1.74.lua and play until the first Korean line appears")
