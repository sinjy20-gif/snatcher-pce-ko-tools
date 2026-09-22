#!/usr/bin/env python3
"""Static validation for an SRT4 direct-overlay build."""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path


ROOT = Path(r"C:\snatcher")
STATIC_DIR = ROOT / "extraction" / "patch" / "static"
sys.path.insert(0, str(STATIC_DIR))

import build_direct_overlay_layout as layout  # noqa: E402
import build_speaker_ui_proof as proof  # noqa: E402
import build_track24_loader_proof as track24  # noqa: E402


ROM_DIR = ROOT / "rom(japan)" / "Snatcher CD-ROMantic (Japan)"
SOURCE_TRACK24 = ROM_DIR / "Snatcher CD-ROMantic (Japan) (Track 24).bin"


def runtime_hash_model(state: int, source: bytes) -> int:
    """Model the HuC6280 preloader's byte-by-byte 14-bit hash arithmetic."""

    hash_lo = 0
    hash_hi = 0
    cumulative = 0
    for value in source:
        total = hash_lo + value
        hash_lo = total & 0xFF
        hash_hi = (hash_hi + (total >> 8)) & 0x3F
        cumulative = (cumulative + hash_lo) & 0xFF

    # Runtime shifts cumulative left by six, then adds cumulative once more:
    # cumulative * 64 + cumulative == cumulative * 65.
    total = hash_lo + ((cumulative << 6) & 0xFF)
    hash_lo = total & 0xFF
    hash_hi = (hash_hi + (cumulative >> 2) + (total >> 8)) & 0x3F
    total = hash_lo + cumulative
    hash_lo = total & 0xFF
    hash_hi = (hash_hi + (total >> 8)) & 0x3F

    state_lo = state & 0xFF
    state_hi = (state >> 8) & 0xFF
    total = hash_lo + state_lo
    hash_lo = total & 0xFF
    hash_hi = (hash_hi + state_hi + state_lo + (total >> 8)) & 0x3F
    return hash_lo | (hash_hi << 8)


def read_rows(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default="0.2.9")
    args = parser.parse_args()

    build_dir = ROOT / "build" / "patch" / args.version
    manifest = json.loads((build_dir / "manifest.json").read_text(encoding="utf-8"))
    runtime = json.loads((build_dir / "runtime_layout.json").read_text(encoding="utf-8"))
    if runtime["format"] != layout.FORMAT:
        raise RuntimeError(f"not an SRT4 build: {runtime['format']}")

    cue = build_dir / manifest["cue"]
    cue_text = cue.read_text(encoding="utf-8-sig")
    if cue_text.count("  TRACK ") != 24:
        raise RuntimeError("CUE does not contain 24 tracks")

    patched24 = build_dir / f"Snatcher CD-ROMantic (Japan) (Track 24) [KO {args.version}].bin"
    source_size = SOURCE_TRACK24.stat().st_size
    with SOURCE_TRACK24.open("rb") as source, patched24.open("rb") as patched:
        while True:
            expected = source.read(1 << 20)
            if not expected:
                break
            if patched.read(len(expected)) != expected:
                raise RuntimeError("original Track 24 prefix changed")

    raw = (build_dir / "track24_appended_raw.bin").read_bytes()
    if len(raw) != layout.SLOT_COUNT * track24.RAW_SECTOR_SIZE:
        raise RuntimeError("bad appended SRT4 raw length")
    first_lba = int(manifest["first_appended_lba"])
    user = bytearray()
    for index in range(layout.SLOT_COUNT):
        sector = raw[index * track24.RAW_SECTOR_SIZE:(index + 1) * track24.RAW_SECTOR_SIZE]
        track24.verify_mode1_sector(sector, first_lba + index)
        user.extend(sector[16:16 + track24.USER_DATA_SIZE])

    rows = read_rows(build_dir / "direct_records.tsv")
    max_probe = 0
    total_probe = 0
    for row in rows:
        state = int(row["state"], 16)
        source = bytes.fromhex(row["source_hex"])
        source_len, xor_value, cumulative = layout.cumulative_signature(source)
        slot = layout.direct_hash(state, source)
        runtime_slot = runtime_hash_model(state, source)
        if runtime_slot != slot:
            raise RuntimeError(
                f"runtime/layout hash mismatch: {row['reference']} "
                f"runtime={runtime_slot:04X} layout={slot:04X}"
            )
        matched = False
        for probes in range(1, int(runtime["maximum_successful_probes"]) + 1):
            payload = user[slot * track24.USER_DATA_SIZE:(slot + 1) * track24.USER_DATA_SIZE]
            if payload[:4] == bytes(4):
                break
            if (
                payload[:4] == layout.MAGIC
                and payload[5] == source_len
                and payload[6] == xor_value
                and payload[7] == cumulative
                and int.from_bytes(payload[8:10], "little") == state
            ):
                expected_slot = int(row["final_slot"], 16)
                if slot != expected_slot:
                    raise RuntimeError(f"slot mismatch: {row['reference']}")
                max_probe = max(max_probe, probes)
                total_probe += probes
                matched = True
                break
            slot = (slot + 1) & layout.SLOT_MASK
        if not matched:
            raise RuntimeError(f"unreachable SRT4 record: {row['reference']}")

    patched02 = build_dir / f"Snatcher CD-ROMantic (Japan) (Track 02) [KO {args.version}].bin"
    patch_rows = read_rows(build_dir / "track02_patches.tsv")
    for row in patch_rows:
        expected = bytes.fromhex(row["new_hex"])
        actual = proof.read_user_bytes(patched02, int(row["iso_offset"], 16), len(expected))
        if actual != expected:
            raise RuntimeError(f"Track 02 patch mismatch: {row['name']}")

    required_fractional = {
        "fractional_glyph_shift",
        "fractional_space_advance_call",
        "fractional_space_helper_init",
    }
    present = {row["name"] for row in patch_rows}
    if not required_fractional <= present:
        raise RuntimeError(
            f"missing fractional-space patches: {sorted(required_fractional - present)}"
        )

    helper = layout.FRACTIONAL_SPACE_HELPER
    helper_offset = layout.FONT_OFFSET + layout.FRACTIONAL_SPACE_HELPER_INDEX * 32
    for slot in range(layout.SLOT_COUNT):
        payload = user[slot * track24.USER_DATA_SIZE:(slot + 1) * track24.USER_DATA_SIZE]
        if payload[:4] == layout.MAGIC:
            actual_helper = payload[helper_offset:helper_offset + len(helper)]
            if actual_helper != helper:
                raise RuntimeError(f"slot {slot:04X} does not preserve fractional-space helper")

    preloader = next(row for row in patch_rows if row["name"] == "renderer_preloader_direct")
    add_cumulative = bytes.fromhex("18 AD F1 7F 6D F5 7F 8D F1 7F AD F2 7F 69 00 29 3F 8D F2 7F")
    if add_cumulative not in bytes.fromhex(preloader["new_hex"]):
        raise RuntimeError("runtime preloader is missing the cumulative *65 correction")

    preloader_bytes = bytes.fromhex(preloader["new_hex"])
    # UI localization is deliberately disabled: only the completed narrative
    # buffer ($3619) may enter the CD-backed lookup.  The menu text start
    # ($3499) must remain on the native renderer path with no lookup cost.
    cached_text = layout.TEXT_OFFSET + 0x5B80
    cache_redirect = bytes(
        (0xA9, cached_text & 0xFF, 0x8D, 0x71, 0x34,
         0xA9, cached_text >> 8, 0x8D, 0x72, 0x34)
    )
    for signature, description in (
        (bytes.fromhex("C9 19"), "$3619 source gate"),
        (cache_redirect, "cache-text redirect"),
    ):
        if signature not in preloader_bytes:
            raise RuntimeError(f"runtime preloader is missing {description}")
    if bytes.fromhex("C9 99") in preloader_bytes:
        raise RuntimeError("runtime preloader still intercepts $3499 UI text")

    average = total_probe / len(rows)
    if abs(average - float(runtime["average_successful_probes"])) > 1e-12:
        raise RuntimeError("average probe statistic mismatch")
    if max_probe != int(runtime["maximum_successful_probes"]):
        raise RuntimeError("maximum probe statistic mismatch")

    print(
        "SRT4 VALIDATION OK "
        f"version={args.version} cue_tracks=24 records={len(rows)} "
        f"avg_reads={average:.3f} max_reads={max_probe} "
        f"appended_sectors={layout.SLOT_COUNT}"
    )


if __name__ == "__main__":
    main()
