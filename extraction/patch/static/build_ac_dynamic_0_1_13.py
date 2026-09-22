#!/usr/bin/env python3
"""Build ac_0.1.13: isolate tiny scenes from the large shared resident pack."""

from __future__ import annotations

import csv
import shutil
import sys
from pathlib import Path


ROOT = Path(r"C:\snatcher")
STATIC = ROOT / "extraction" / "patch" / "static"
sys.path.insert(0, str(STATIC))

import build_ac_dynamic_0_1_11 as assignment  # noqa: E402


dynamic = assignment.dynamic
VERSION = "ac_0.1.13"
dynamic.VERSION = VERSION
dynamic.OUT = ROOT / "build" / "patch" / VERSION
dynamic.RESIDENT_PACK_NAMES = ("speaker", "ui", "small_scenes", "shared")
dynamic.COALESCE_SMALL_SCENES_MAX_RECORDS = 3
dynamic.COALESCE_SMALL_SCENES_TARGET = "small_scenes"


if __name__ == "__main__":
    dynamic.main()
    with (dynamic.OUT / "runtime_scene_assignment.tsv").open(
        "w", encoding="utf-8-sig", newline=""
    ) as handle:
        fields = (
            "reference", "scene", "method", "runtime_seq", "scene_seq",
            "sequence_distance", "catalog",
        )
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t")
        writer.writeheader()
        writer.writerows(assignment.RUNTIME_EVIDENCE)
    shutil.copy2(
        ROOT / "snatcher_tool" / "translation" / "master_conflict_exclusions.tsv",
        dynamic.OUT / "master_conflict_exclusions.tsv",
    )
    diagnostic = (
        ROOT / "build" / "patch" / "ac_0.1.10" / "AC_RUNTIME_SCENE_DIAG.lua"
    ).read_text(encoding="utf-8")
    diagnostic = diagnostic.replace("ac_0.1.10", VERSION).replace("AC110", "AC113")
    diagnostic = diagnostic.replace(
        "local shared = emu.read(0x10005, ac) or 0\n  local scene = emu.read(0x10006, ac) or 0",
        "local small = emu.read(0x10005, ac) or 0\n"
        "  local shared = emu.read(0x10006, ac) or 0\n"
        "  local scene = emu.read(0x10007, ac) or 0",
    ).replace(
        "flags speaker=%02X ui=%02X shared=%02X scene=%02X",
        "flags speaker=%02X ui=%02X small=%02X shared=%02X scene=%02X",
    ).replace(
        "loaders, packReads, speaker, ui, shared, scene))",
        "loaders, packReads, speaker, ui, small, shared, scene))",
    )
    (dynamic.OUT / "AC_RUNTIME_SCENE_DIAG.lua").write_text(diagnostic, encoding="utf-8")
    shutil.copy2(
        ROOT / "lua" / "UI 0.1.72.lua",
        dynamic.OUT / "UI 0.1.72.lua",
    )
