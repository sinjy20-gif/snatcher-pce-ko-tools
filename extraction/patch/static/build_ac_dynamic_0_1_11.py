#!/usr/bin/env python3
"""Build ac_0.1.11 from the current Studio O-reviewed SRT4 source."""

from __future__ import annotations

import csv
import shutil
import sys
from collections import defaultdict
from pathlib import Path


ROOT = Path(r"C:\snatcher")
STATIC = ROOT / "extraction" / "patch" / "static"
sys.path.insert(0, str(STATIC))

import build_ac_dynamic_0_1_9 as split  # noqa: E402


dynamic = split.dynamic
VERSION = "ac_0.1.11"
BASE = ROOT / "build" / "patch" / "ac_0.1.11-source"
BASE_RECORDS = BASE / "direct_records.tsv"
AUDIT_DIR = ROOT / "snatcher_tool" / "logs" / "audit_archive"

# Runtime rows recovered after the surviving catalogs were written.  The
# first ten are one contiguous seq=561..585 collection batch inside 111800;
# D5990894 is the reception's first-dialogue capture in a fresh audit session.
EXPLICIT_RECOVERY = {
    "RUNTIME_0000_AFF0F2DF:1": ("111800", "recovered-master-sequence-context"),
    "RUNTIME_0070_F5634C88:1": ("111800", "recovered-master-sequence-context"),
    "RUNTIME_0000_44B11DD6:1": ("111800", "recovered-master-sequence-context"),
    "RUNTIME_00AD_029B2221:1": ("111800", "recovered-seq-561-585-batch"),
    "RUNTIME_0000_89C11CE2:1": ("111800", "recovered-seq-561-585-batch"),
    "RUNTIME_0000_993519B6:1": ("111800", "recovered-seq-561-585-batch"),
    "RUNTIME_0000_0F146A29:1": ("111800", "recovered-seq-561-585-batch"),
    "RUNTIME_0000_3AE56BA8:1": ("111800", "recovered-seq-561-585-batch"),
    "RUNTIME_0000_C4CA73DA:1": ("111800", "recovered-seq-561-585-batch"),
    "RUNTIME_0000_6ADCD243:1": ("111800", "recovered-seq-561-585-batch"),
    "RUNTIME_0000_812AC93A:1": ("111800", "recovered-seq-561-585-batch"),
    "RUNTIME_0000_1DD44BF0:1": ("111800", "recovered-seq-561-585-batch"),
    "RUNTIME_0000_087557A0:1": ("111800", "recovered-seq-561-585-batch"),
    "RUNTIME_0000_D5990894:1": ("111800", "reception-context-new-audit-session"),
}


def runtime_rows() -> list[dict[str, str]]:
    # The entry point retargets `dynamic.BASE` to this build's stage 1/2
    # intermediate, so read from there rather than the module constant.  The
    # constant is the *frozen* ac_0.1.11-source, which only happens to be right
    # for an untagged build; a `--tag` build writes ac_0.1.11-source-<tag> and
    # then the scene map described a different record set than the one being
    # classified.  Refs that existed only in the new set fell straight through
    # `required` and surfaced as a bare KeyError instead of the readable
    # "reviewed runtime rows have no scene assignment" error.
    records = getattr(dynamic, "BASE", BASE) / "direct_records.tsv"
    with records.open("r", encoding="utf-8-sig", newline="") as handle:
        return [
            row for row in csv.DictReader(handle, delimiter="\t")
            if any(ref.startswith("RUNTIME_") for ref in row["reference"].split(","))
        ]


def build_runtime_scene_map() -> tuple[dict[str, str], list[dict[str, object]]]:
    rows = runtime_rows()
    assignments: dict[str, str] = {}
    evidence: list[dict[str, object]] = []

    # Hand-recovered assignments are authoritative and must be seeded before the
    # catalog sweep.  They used to be appended afterwards under
    # `if reference not in assignments`, which made them a fallback: whenever the
    # catalog produced a nearest-sequence guess for the same reference, the guess
    # won and the manual recovery was silently dropped.  That is how the frozen
    # pipeline stopped reproducing the shipped ac_0.1.14 — five references drifted
    # from scene 111800 to 121800.
    for reference, (scene, method) in EXPLICIT_RECOVERY.items():
        assignments[reference] = scene
        evidence.append({
            "reference": reference,
            "scene": scene,
            "method": method,
            "runtime_seq": "",
            "scene_seq": "",
            "sequence_distance": "",
            "catalog": "snatcher_ko_master.tsv",
        })

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
        for direct in rows:
            runtime_refs = [ref for ref in direct["reference"].split(",") if ref.startswith("RUNTIME_")]
            for reference in runtime_refs:
                if reference in assignments:
                    continue
                candidates = by_signature[
                    (direct["source_hex"].strip(), direct["state"].upper().zfill(4))
                ]
                if not candidates:
                    candidates = [
                        row for row in catalog
                        if reference in row["references"].split(",")
                        and row["first_seq"].isdigit()
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

    required = {
        ref
        for row in rows
        for ref in row["reference"].split(",")
        if ref.startswith("RUNTIME_")
    }

    # A capture that spans two displayed lines is one on-screen record, so its
    # lines cannot sit in different scenes.  The catalog only ever holds the
    # capture once, though, so a `KEY:2` looks up nothing and the build stops --
    # which is what happened on 2026-08-14 when three two-line runtime rows were
    # marked reviewed.  Inherit from a sibling line rather than failing.
    #
    # Deliberately after the catalog sweep and never over an existing entry:
    # a real assignment, hand-recovered or matched, always wins.
    by_capture: dict[str, str] = {}
    for reference, scene in assignments.items():
        by_capture.setdefault(reference.split(":", 1)[0], scene)
    for reference in sorted(required - assignments.keys()):
        scene = by_capture.get(reference.split(":", 1)[0])
        if scene is None:
            continue
        assignments[reference] = scene
        evidence.append({
            "reference": reference,
            "scene": scene,
            "method": "sibling-line-of-same-capture",
            "runtime_seq": "",
            "scene_seq": "",
            "sequence_distance": "",
            "catalog": "snatcher_ko_master.tsv",
        })

    missing = sorted(required - assignments.keys())
    if missing:
        raise RuntimeError(
            "reviewed runtime rows have no scene assignment:\n" + "\n".join(missing)
        )
    return assignments, sorted(
        (row for row in evidence if row["reference"] in required),
        key=lambda row: str(row["reference"]),
    )


# Built on first use, not at import.  The entry point sets `dynamic.BASE` after
# importing stage 3, so an eager map read the previous build's records -- and
# with `--tag` that is a different directory entirely.  Other modules reach in
# as `assignment.RUNTIME_EVIDENCE`, so keep the names and resolve them here.
_SCENE_MAP: tuple[dict[str, str], list[dict[str, object]]] | None = None


def scene_map() -> tuple[dict[str, str], list[dict[str, object]]]:
    """Assignments and evidence, built once, after `dynamic.BASE` is final."""
    global _SCENE_MAP
    if _SCENE_MAP is None:
        _SCENE_MAP = build_runtime_scene_map()
    return _SCENE_MAP


# Module __getattr__ covers `assignment.RUNTIME_SCENES` from the outside.  It
# does NOT cover a bare global read inside this module's own functions, so those
# call scene_map() directly -- PEP 562 hooks attribute access, not name lookup.
def __getattr__(name: str):
    if name == "RUNTIME_SCENES":
        return scene_map()[0]
    if name == "RUNTIME_EVIDENCE":
        return scene_map()[1]
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


def classify_runtime_scene(row: dict[str, str]) -> str:
    runtime_refs = [ref for ref in row["reference"].split(",") if ref.startswith("RUNTIME_")]
    if runtime_refs:
        assignments = scene_map()[0]
        scenes = {assignments[ref] for ref in runtime_refs}
        if len(scenes) != 1:
            raise RuntimeError(f"runtime record spans multiple scenes: {row['reference']}")
        return f"scene_{next(iter(scenes))}"
    return split.classify_split_common(row)


dynamic.VERSION = VERSION
dynamic.BASE = BASE
dynamic.OUT = ROOT / "build" / "patch" / VERSION
dynamic.COALESCE_SMALL_SCENES_MAX_RECORDS = 3
dynamic.classify = classify_runtime_scene


if __name__ == "__main__":
    dynamic.main()
    audit_path = dynamic.OUT / "runtime_scene_assignment.tsv"
    with audit_path.open("w", encoding="utf-8-sig", newline="") as handle:
        fields = (
            "reference", "scene", "method", "runtime_seq", "scene_seq",
            "sequence_distance", "catalog",
        )
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t")
        writer.writeheader()
        writer.writerows(scene_map()[1])
    shutil.copy2(
        ROOT / "snatcher_tool" / "translation" / "master_conflict_exclusions.tsv",
        dynamic.OUT / "master_conflict_exclusions.tsv",
    )
    diagnostic = (
        ROOT / "build" / "patch" / "ac_0.1.10" / "AC_RUNTIME_SCENE_DIAG.lua"
    ).read_text(encoding="utf-8")
    diagnostic = diagnostic.replace("ac_0.1.10", VERSION).replace("AC110", "AC111")
    (dynamic.OUT / "AC_RUNTIME_SCENE_DIAG.lua").write_text(diagnostic, encoding="utf-8")
