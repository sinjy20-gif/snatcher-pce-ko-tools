#!/usr/bin/env python3
"""Build ac_0.1.16: ac_0.1.14 with 32 KiB CD chunks.

Same single change as ac_0.1.15 but twice as far.  See that file for the
reasoning; the short version is that ac_0.1.14's measured 5.28 s first-dialogue
load matched the projected 5.23 s to within 1 %, so the cost model

    calls x 188 ms  +  bytes / 150 KB/s

is trustworthy and the call count is now the whole problem.

    chunk    calls   projected   measured
     8 KiB     21      5.23 s      5.28 s
    16 KiB     13      3.5 s       ac_0.1.15
    32 KiB      8      2.6 s       this build

Test ac_0.1.16 first.  If Korean renders and scenes load correctly, it wins and
ac_0.1.15 can be ignored.  If it breaks, ac_0.1.15 is the halfway fallback and
tells us whether the BIOS carries the AC destination across one bank boundary
but not three.
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

VERSION = "ac_0.1.16"
CHUNK_BYTES = 0x8000        # 32 KiB = 16 sectors per CD_READ

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

    first = {"speaker", "ui", "small_scenes", "shared", "scene_111800"}
    calls = sum(-(-int(p["bytes"]) // CHUNK_BYTES)
                for p in manifest["packages"] if p["name"] in first)
    calls += compact.build_packs_compact.init_chunks
    print(f"\nchunk           : {CHUNK_BYTES} B ({sectors} sectors per CD_READ)")
    print(f"initial CD load : {compact.build_packs_compact.init_chunks} chunks")
    print(f"first-dialogue  : {calls} CD_READ calls (ac_0.1.14 measured 21 / 5.28 s)")
    print(f"projected       : {calls * 0.188 + 167936 / (150 * 1024):.2f} s")
    print(f"helper code     : {manifest['helper_code_bytes']} B "
          f"({manifest['helper_free_bytes']} B free)")
