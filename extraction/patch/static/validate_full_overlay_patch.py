#!/usr/bin/env python3
"""Independently validate a complete Track-24 Korean overlay build."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import sys
from pathlib import Path


ROOT = Path(r"C:\snatcher")
STATIC_DIR = ROOT / "extraction" / "patch" / "static"
sys.path.insert(0, str(STATIC_DIR))

import build_disc_patch as common  # noqa: E402
import build_full_overlay_layout as layout  # noqa: E402
import build_track24_loader_proof as track24  # noqa: E402


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def fail(message: str) -> None:
    raise RuntimeError(message)


def validate(build_dir: Path) -> dict[str, int | str]:
    manifest = json.loads((build_dir / "manifest.json").read_text(encoding="utf-8"))
    version = manifest["version"]
    source02 = Path(r"C:\snatcher\rom(japan)\Snatcher CD-ROMantic (Japan)\Snatcher CD-ROMantic (Japan) (Track 02).bin")
    source24 = Path(r"C:\snatcher\rom(japan)\Snatcher CD-ROMantic (Japan)\Snatcher CD-ROMantic (Japan) (Track 24).bin")
    patched02 = build_dir / f"Snatcher CD-ROMantic (Japan) (Track 02) [KO {version}].bin"
    patched24 = build_dir / f"Snatcher CD-ROMantic (Japan) (Track 24) [KO {version}].bin"

    for path, expected in (
        (source02, manifest["source_track02_sha256"]),
        (source24, manifest["source_track24_sha256"]),
        (patched02, manifest["patched_track02_sha256"]),
        (patched24, manifest["patched_track24_sha256"]),
    ):
        actual = sha256_file(path)
        if actual != expected:
            fail(f"SHA-256 mismatch: {path}: {actual} != {expected}")

    # Reviewed tables are immutable inputs to this build.
    for key in ("speaker_name_standard", "ui_text"):
        path = Path(manifest["layout"][key])
        actual = sha256_file(path)
        expected = manifest["layout"][f"{key}_sha256"]
        if actual != expected:
            fail(f"reviewed table changed after build: {path}")

    # CUE must reference exactly the 24 staged files, all of which must exist.
    cue = build_dir / manifest["cue"]
    cue_text = cue.read_text(encoding="utf-8-sig")
    cue_files = re.findall(r'^FILE\s+"([^"]+)"\s+BINARY$', cue_text, flags=re.MULTILINE)
    if len(cue_files) != 24 or len(set(cue_files)) != 24:
        fail(f"CUE has {len(cue_files)} file entries, expected 24 unique entries")
    for name in cue_files:
        path = build_dir / name
        if not path.is_file() or path.stat().st_size % track24.RAW_SECTOR_SIZE:
            fail(f"missing or unaligned CUE track: {path}")

    # Track 24 is append-only: the complete original byte stream is preserved.
    source24_bytes = source24.read_bytes()
    with patched24.open("rb") as handle:
        if handle.read(len(source24_bytes)) != source24_bytes:
            fail("patched Track 24 does not preserve the original prefix")
        appended = handle.read()
    raw_overlay = (build_dir / "track24_appended_raw.bin").read_bytes()
    if appended != raw_overlay:
        fail("Track 24 appended bytes differ from the archived overlay")
    if len(appended) != manifest["appended_raw_bytes"]:
        fail("Track 24 appended length does not match manifest")

    # Recreate every raw sector, validating order, LBA headers, EDC and ECC.
    lookup_user = (layout.DEFAULT_OUT / "lookup_user_sectors.bin").read_bytes()
    asset_user = (layout.DEFAULT_OUT / "asset_user_sectors.bin").read_bytes()
    user_overlay = lookup_user + asset_user
    sector_count = len(user_overlay) // track24.USER_DATA_SIZE
    if sector_count != manifest["appended_sectors"]:
        fail("runtime layout sector count does not match patch manifest")
    rebuilt = bytearray()
    first_lba = manifest["first_appended_lba"]
    for index in range(sector_count):
        start = index * track24.USER_DATA_SIZE
        user_data = user_overlay[start:start + track24.USER_DATA_SIZE]
        rebuilt.extend(track24.make_mode1_sector(first_lba + index, user_data))
    if bytes(rebuilt) != appended:
        fail("raw Track 24 sectors fail Mode1 LBA/EDC/ECC reproduction")

    # Verify every compact lookup row against its serialized fixed-size record.
    lookup_rows_path = build_dir / "lookup_records.tsv"
    with lookup_rows_path.open(encoding="utf-8-sig", newline="") as handle:
        lookup_rows = list(csv.DictReader(handle, delimiter="\t"))
    if len(lookup_rows) != manifest["layout"]["record_count"]:
        fail("lookup row count mismatch")
    for row in lookup_rows:
        source = bytes.fromhex(row["source_hex"])
        signature = layout.source_fingerprint(source)
        expected = (
            int(row["source_length"]),
            int(row["source_xor"], 16),
            int(row["source_cumulative"], 16),
        )
        if signature != expected or layout.hash10(source) != int(row["bucket"]):
            fail(f"lookup fingerprint mismatch: {row['reference']}")

    assets = asset_user
    asset_count = manifest["layout"]["asset_count"]
    if len(assets) != asset_count * track24.USER_DATA_SIZE:
        fail("asset payload length mismatch")
    for index in range(asset_count):
        payload = assets[index * track24.USER_DATA_SIZE:(index + 1) * track24.USER_DATA_SIZE]
        if payload[:4] != b"AST2":
            fail(f"asset {index} has invalid header")
        encoded_length = payload[4]
        if not encoded_length or payload[layout.ASSET_HEADER_SIZE + encoded_length - 1] != 0xFF:
            fail(f"asset {index} has invalid encoded terminator")
        if int.from_bytes(payload[6:8], "little") != layout.FONT_BYTES:
            fail(f"asset {index} has invalid font length")

    # Track 02 must differ only in the declared raw sectors.
    changed: list[int] = []
    with source02.open("rb") as old, patched02.open("rb") as new:
        sector = 0
        while True:
            left = old.read(track24.RAW_SECTOR_SIZE)
            right = new.read(track24.RAW_SECTOR_SIZE)
            if not left and not right:
                break
            if left != right:
                changed.append(sector)
            sector += 1
    declared = sorted(int(value, 16) for value in manifest["modified_track02_sectors"])
    if changed != declared:
        fail(f"Track 02 changed sectors {changed}, expected {declared}")

    return {
        "version": version,
        "cue_tracks": len(cue_files),
        "records": len(lookup_rows),
        "assets": asset_count,
        "appended_sectors": sector_count,
        "changed_track02_sectors": len(changed),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("build_dir", type=Path)
    args = parser.parse_args()
    result = validate(args.build_dir)
    print("FULL OVERLAY VALIDATION OK " + " ".join(f"{key}={value}" for key, value in result.items()))


if __name__ == "__main__":
    main()
