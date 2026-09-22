#!/usr/bin/env python3
"""Build ac_0.1.15: ac_0.1.14 with 16 KiB CD chunks instead of 8 KiB.

Why
---
ac_0.1.14 already cut the transferred bytes 5.5x (704 B records -> 128 B plus
one global atlas) and the first-dialogue path from 61 to 21 BIOS CD_READ calls,
confirmed in Mesen.  Korean renders correctly, so the compact -> 704 B
restoration is verified on real hardware.

What is left is the per-call cost.  Each CD_READ costs roughly 188 ms of seek
and BIOS overhead while 8 KiB of payload only takes 53 ms to transfer, so the
call count now dominates:

    directory              65,536 B    8 calls   38 % of the path
    state+template+atlas   24,576 B    3 calls
    speaker / ui / small    17,920 B    3 calls
    shared                 28,032 B    4 calls
    scene_111800           28,672 B    4 calls
                                      --------
                                       21 calls

Doubling the chunk halves most of that without a single new instruction.

    chunk    calls   projected
     8 KiB     21      5.0 s
    16 KiB     13      3.5 s      <- this build
    32 KiB      8      2.6 s      <- ac_0.1.16

The risk this build tests
-------------------------
BIOS CD_READ destination type 4 maps the requested bank into MPR4, an 8 KiB
window.  For a chunk larger than 8 KiB the BIOS must carry on past $9FFF, which
means it increments the destination bank from $40 to $41.  Banks $40-$43 are all
Arcade Card window space, but whether the incremented bank keeps following the
same auto-incrementing AC pointer is not verified.

    it does      Korean still renders -> adopt, then try ac_0.1.16
    it does not  Korean breaks or the scene garbles -> stay on ac_0.1.14

Nothing else changes: same compact records, same atlas, same helper logic, same
directory.  One variable.
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

VERSION = "ac_0.1.15"
CHUNK_BYTES = 0x4000        # 16 KiB = 8 sectors per CD_READ

compact.CHUNK_BYTES = CHUNK_BYTES
dynamic.CHUNK_BYTES = CHUNK_BYTES
dynamic.VERSION = VERSION
dynamic.OUT = ROOT / "build" / "patch" / VERSION


if __name__ == "__main__":
    sectors = CHUNK_BYTES // compact.USER_BYTES
    if not 1 <= sectors <= 255:
        raise SystemExit(f"chunk of {CHUNK_BYTES} B is {sectors} sectors")
    dynamic.main()

    manifest_path = dynamic.OUT / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["chunk_bytes"] = CHUNK_BYTES
    manifest["chunk_sectors"] = sectors
    manifest["compact_records"] = {
        "record_bytes": compact.COMPACT_BYTES,
        "record_count": compact.build_packs_compact.record_count,
        "atlas_glyphs": compact.build_packs_compact.atlas_glyphs,
        "atlas_bytes": compact.build_packs_compact.atlas_bytes,
        "template_ac": f"{compact.TEMPLATE_AC:05X}",
        "atlas_ac": f"{compact.ATLAS_AC:05X}",
        "initial_cd_chunks": compact.build_packs_compact.init_chunks,
        "byte_exact_verified": compact.build_packs_compact.record_count,
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
        ROOT / "snatcher_tool" / "translation" / "master_conflict_exclusions.tsv",
        dynamic.OUT / "master_conflict_exclusions.tsv")
    shutil.copy2(
        ROOT / "lua" / "UI 0.1.73.lua",
        dynamic.OUT / "UI 0.1.73.lua")

    calls = sum(
        -(-int(p["bytes"]) // CHUNK_BYTES) for p in manifest["packages"]
        if p["name"] in {"speaker", "ui", "small_scenes", "shared", "scene_111800"}
    ) + compact.build_packs_compact.init_chunks
    print(f"\nchunk           : {CHUNK_BYTES} B ({sectors} sectors per CD_READ)")
    print(f"initial CD load : {compact.build_packs_compact.init_chunks} chunks")
    print(f"first-dialogue  : {calls} CD_READ calls (ac_0.1.14 needed 21)")
    print(f"helper code     : {manifest['helper_code_bytes']} B "
          f"({manifest['helper_free_bytes']} B free)")
