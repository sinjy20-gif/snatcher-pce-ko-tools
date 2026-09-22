#!/usr/bin/env python3
"""Build ac_0.1.12: ac_0.1.11 plus sector-safe resident destinations."""

from __future__ import annotations

import csv
import shutil
import sys
from pathlib import Path


ROOT = Path(r"C:\snatcher")
STATIC = ROOT / "extraction" / "patch" / "static"
sys.path.insert(0, str(STATIC))

import build_ac_dynamic_0_1_11 as previous  # noqa: E402


dynamic = previous.dynamic
VERSION = "ac_0.1.12"
dynamic.VERSION = VERSION
dynamic.OUT = ROOT / "build" / "patch" / VERSION


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
        writer.writerows(previous.RUNTIME_EVIDENCE)
    shutil.copy2(
        ROOT / "snatcher_tool" / "translation" / "master_conflict_exclusions.tsv",
        dynamic.OUT / "master_conflict_exclusions.tsv",
    )
    diagnostic = (
        ROOT / "build" / "patch" / "ac_0.1.10" / "AC_RUNTIME_SCENE_DIAG.lua"
    ).read_text(encoding="utf-8")
    diagnostic = diagnostic.replace("ac_0.1.10", VERSION).replace("AC110", "AC112")
    (dynamic.OUT / "AC_RUNTIME_SCENE_DIAG.lua").write_text(diagnostic, encoding="utf-8")
    shutil.copy2(
        ROOT / "lua" / "UI 0.1.72.lua",
        dynamic.OUT / "UI 0.1.72.lua",
    )
