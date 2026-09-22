#!/usr/bin/env python3
"""Build ac_0.1.10: split residents plus runtime-to-scene assignment."""

from __future__ import annotations

import csv
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(r"C:\snatcher")
STATIC = ROOT / "extraction" / "patch" / "static"
sys.path.insert(0, str(STATIC))

import build_ac_dynamic_0_1_9 as split  # noqa: E402

dynamic = split.dynamic
BASE_RECORDS = ROOT / "build" / "patch" / "0.3.0-uitest" / "direct_records.tsv"
AUDIT_DIR = ROOT / "snatcher_tool" / "logs" / "audit_archive"

# These three predate the surviving audit catalogs, but their original master
# first_seq values (69, 205, 555) and text context are all inside scene 111800.
EXPLICIT_RECOVERY = {
    "RUNTIME_0000_AFF0F2DF:1": "111800",
    "RUNTIME_0070_F5634C88:1": "111800",
    "RUNTIME_0000_44B11DD6:1": "111800",
}


def build_runtime_scene_map() -> tuple[dict[str, str], list[dict[str, object]]]:
    with BASE_RECORDS.open("r", encoding="utf-8-sig", newline="") as handle:
        runtime_rows = [
            row for row in csv.DictReader(handle, delimiter="\t")
            if row["reference"].startswith("RUNTIME_")
        ]
    assignments: dict[str, str] = {}
    evidence: list[dict[str, object]] = []
    for catalog_path in sorted(AUDIT_DIR.glob("runtime_text_catalog_*.tsv"), reverse=True):
        with catalog_path.open("r", encoding="utf-16", newline="") as handle:
            catalog = list(csv.DictReader(handle, delimiter="\t"))
        single_scene = [
            row for row in catalog
            if row["scene"].strip() and "," not in row["scene"] and row["first_seq"].isdigit()
        ]
        by_signature: defaultdict[tuple[str, str], list[dict[str, str]]] = defaultdict(list)
        for row in catalog:
            by_signature[(row["source_hex"].strip(), row["state"].upper().zfill(4))].append(row)
        for direct in runtime_rows:
            reference = direct["reference"]
            if reference in assignments:
                continue
            candidates = by_signature[(direct["source_hex"].strip(), direct["state"].upper().zfill(4))]
            if not candidates:
                candidates = [
                    row for row in catalog
                    if reference in row["references"].split(",") and row["first_seq"].isdigit()
                ]
            if not candidates or not single_scene or not candidates[0]["first_seq"].isdigit():
                continue
            runtime_seq = int(candidates[0]["first_seq"])
            nearest = min(single_scene, key=lambda row: abs(int(row["first_seq"]) - runtime_seq))
            scene = nearest["scene"].strip()
            assignments[reference] = scene
            evidence.append({
                "reference": reference,
                "scene": scene,
                "method": "nearest-single-scene-sequence",
                "runtime_seq": runtime_seq,
                "scene_seq": int(nearest["first_seq"]),
                "sequence_distance": abs(int(nearest["first_seq"]) - runtime_seq),
                "catalog": catalog_path.name,
            })
    for reference, scene in EXPLICIT_RECOVERY.items():
        if reference not in assignments:
            assignments[reference] = scene
            evidence.append({
                "reference": reference,
                "scene": scene,
                "method": "recovered-master-sequence-context",
                "runtime_seq": "",
                "scene_seq": "",
                "sequence_distance": "",
                "catalog": "uitest_master.tsv",
            })
    return assignments, sorted(evidence, key=lambda row: str(row["reference"]))


RUNTIME_SCENES, RUNTIME_EVIDENCE = build_runtime_scene_map()


def classify_runtime_scene(row: dict[str, str]) -> str:
    if row["reference"].startswith("RUNTIME_"):
        scene = RUNTIME_SCENES.get(row["reference"])
        return f"scene_{scene}" if scene else "runtime_unassigned"
    return split.classify_split_common(row)


dynamic.VERSION = "ac_0.1.10"
dynamic.OUT = ROOT / "build" / "patch" / dynamic.VERSION
dynamic.classify = classify_runtime_scene


if __name__ == "__main__":
    dynamic.main()
    audit_path = dynamic.OUT / "runtime_scene_assignment.tsv"
    with audit_path.open("w", encoding="utf-8-sig", newline="") as handle:
        fields = ("reference", "scene", "method", "runtime_seq", "scene_seq", "sequence_distance", "catalog")
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t")
        writer.writeheader()
        writer.writerows(RUNTIME_EVIDENCE)
