#!/usr/bin/env python3
"""Build the first persistent speaker-name and menu/UI Korean proof.

Version 0.1.6 deliberately patches only strings whose Korean encoding fits
inside the original FF-terminated CP932 record:

* speaker ``受付嬢`` -> ``안내원``;
* menu ``見る`` -> ``보다`` at every catalogued occurrence;
* menu ``聞く`` -> ``묻다`` at every catalogued occurrence.

The strings use the canonical Korean codec and the approved Galmuri11 glyph
layout.  No Lua script is required, and the original disc dump is never
modified.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import shutil
import sys
from pathlib import Path


ROOT = Path(r"C:\snatcher")
ROM_DIR = ROOT / "rom(japan)" / "Snatcher CD-ROMantic (Japan)"
SOURCE_TRACK = ROM_DIR / "Snatcher CD-ROMantic (Japan) (Track 02).bin"
BUILD_ROOT = ROOT / "build" / "patch"
SPEAKER_TSV = ROOT / "translation" / "speaker_name_standard.tsv"
UI_TSV = ROOT / "translation" / "ui_text.tsv"

STATIC_DIR = ROOT / "extraction" / "patch" / "static"
TRANSLATION_DIR = ROOT / "extraction" / "translation"
sys.path.insert(0, str(STATIC_DIR))
sys.path.insert(0, str(TRANSLATION_DIR))

import build_disc_patch as common  # noqa: E402
from game_text_codec import (  # noqa: E402
    encode_game_text,
    ordered_hangul,
)


EXPECTED_SOURCE_SHA256 = common.EXPECTED_SOURCE_SHA256
GLYPH_BASE = common.GLYPH_BASE
FONT_WRAPPER = common.FONT_WRAPPER
FONT_CALL_CPU = common.FONT_CALL_CPU
ORIGINAL_FONT_CALL = common.ORIGINAL_FONT_CALL

TARGET_SPEAKER_JP = "受付嬢"
TARGET_UI_IDS = {"UI0001", "UI0003"}
ALLOWED_STATUS = {"review", "final"}


def sha256(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest().upper()


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-16", newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def fit_record(encoded: bytes, original_length: int, label: str) -> bytes:
    if len(encoded) > original_length:
        raise RuntimeError(
            f"{label} needs {len(encoded)} bytes but the original record has "
            f"only {original_length}"
        )
    return encoded + bytes((0xFF,)) * (original_length - len(encoded))


def code_for_index(index: int) -> bytes:
    if not 0 <= index < 0x3F:
        raise RuntimeError(f"proof glyph index is out of range: {index}")
    return bytes((0xF0, 0x40 + index))


def shift_glyph_up(glyph: bytes) -> bytes:
    if len(glyph) != 32:
        raise RuntimeError(f"bad glyph size: {len(glyph)}")
    return glyph[2:] + b"\x00\x00"


def build_context_font_pack(
    speaker_glyphs: tuple[str, ...],
    menu_glyphs: tuple[str, ...],
) -> tuple[bytes, dict[str, bytes], dict[str, bytes], list[dict[str, str]]]:
    """Build normal speaker glyphs plus menu-only one-pixel-up copies."""

    wanted = {ord(char) for char in speaker_glyphs + menu_glyphs}
    found = common.parse_bdf(common.FONT_BDF, wanted)
    missing = [char for char in speaker_glyphs + menu_glyphs if ord(char) not in found]
    if missing:
        raise RuntimeError(f"missing Galmuri11 glyphs: {missing}")

    # F040 remains the approved compact Korean period.
    period = bytes(24) + bytes((0x0C, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00))
    output = bytearray(period)
    mapping: list[dict[str, str]] = [
        {
            "index": "0",
            "game_code": "F040",
            "unicode": "U+002E",
            "character": ".",
            "font_offset": "000000",
            "kind": "punctuation",
        }
    ]
    speaker_custom: dict[str, bytes] = {}
    menu_custom: dict[str, bytes] = {}
    index = 1

    for char in speaker_glyphs:
        code = code_for_index(index)
        glyph = common.glyph_1bpp_left_shifted(*found[ord(char)])
        speaker_custom[char] = code
        output.extend(glyph)
        mapping.append(
            {
                "index": str(index),
                "game_code": code.hex().upper(),
                "unicode": f"U+{ord(char):04X}",
                "character": char,
                "font_offset": f"{index * 32:06X}",
                "kind": "speaker_hangul",
            }
        )
        index += 1

    for char in menu_glyphs:
        code = code_for_index(index)
        glyph = common.glyph_1bpp_left_shifted(*found[ord(char)])
        menu_custom[char] = code
        output.extend(shift_glyph_up(glyph))
        mapping.append(
            {
                "index": str(index),
                "game_code": code.hex().upper(),
                "unicode": f"U+{ord(char):04X}",
                "character": char,
                "font_offset": f"{index * 32:06X}",
                "kind": "menu_hangul_y_minus_1",
            }
        )
        index += 1

    return bytes(output), speaker_custom, menu_custom, mapping


def write_tsv(path: Path, rows: list[dict[str, str]]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=list(rows[0]),
            delimiter="\t",
            lineterminator="\n",
        )
        writer.writeheader()
        writer.writerows(rows)


def extract_user_data(source_raw: bytes) -> bytearray:
    output = bytearray()
    for sector_index in range(len(source_raw) // common.RAW_SECTOR_SIZE):
        start = sector_index * common.RAW_SECTOR_SIZE + common.USER_DATA_OFFSET
        output.extend(source_raw[start : start + common.USER_DATA_SIZE])
    return output


def read_user_bytes(path: Path, iso_offset: int, length: int) -> bytes:
    output = bytearray()
    cursor = iso_offset
    remaining = length
    with path.open("rb") as handle:
        while remaining:
            sector_index, within = divmod(cursor, common.USER_DATA_SIZE)
            take = min(remaining, common.USER_DATA_SIZE - within)
            raw_offset = (
                sector_index * common.RAW_SECTOR_SIZE
                + common.USER_DATA_OFFSET
                + within
            )
            handle.seek(raw_offset)
            block = handle.read(take)
            if len(block) != take:
                raise RuntimeError("short read from Track 02")
            output.extend(block)
            cursor += take
            remaining -= take
    return bytes(output)


def apply_patches_streaming(
    source_path: Path,
    target_path: Path,
    patches: list[common.Patch],
) -> set[int]:
    """Copy and patch Track 02 one raw sector at a time.

    This avoids holding both the 80 MiB source and patched image in memory,
    which is important in the desktop app's constrained Python process.
    """

    sector_parts: dict[int, list[tuple[int, bytes, bytes, str]]] = {}
    for patch in patches:
        if len(patch.old) != len(patch.new):
            raise RuntimeError(f"{patch.name} is not a fixed-size patch")
        cursor = patch.iso_offset
        consumed = 0
        while consumed < len(patch.old):
            sector_index, within = divmod(cursor, common.USER_DATA_SIZE)
            take = min(len(patch.old) - consumed, common.USER_DATA_SIZE - within)
            sector_parts.setdefault(sector_index, []).append(
                (
                    within,
                    patch.old[consumed : consumed + take],
                    patch.new[consumed : consumed + take],
                    patch.name,
                )
            )
            cursor += take
            consumed += take

    shutil.copyfile(source_path, target_path)
    with source_path.open("rb") as source, target_path.open("r+b") as target:
        for sector_index in sorted(sector_parts):
            raw_start = sector_index * common.RAW_SECTOR_SIZE
            source.seek(raw_start)
            sector = bytearray(source.read(common.RAW_SECTOR_SIZE))
            if len(sector) != common.RAW_SECTOR_SIZE:
                raise RuntimeError(f"short sector read at {sector_index}")
            for within, old, new, name in sector_parts[sector_index]:
                start = common.USER_DATA_OFFSET + within
                actual = bytes(sector[start : start + len(old)])
                if actual != old:
                    raise RuntimeError(
                        f"{name} signature mismatch in sector {sector_index:06X}: "
                        f"expected {old.hex(' ')}, got {actual.hex(' ')}"
                    )
                sector[start : start + len(new)] = new
            common.rebuild_mode1_sector(sector)
            target.seek(raw_start)
            target.write(sector)

    if target_path.stat().st_size != source_path.stat().st_size:
        raise RuntimeError("patched Track 02 size changed")
    for patch in patches:
        actual = read_user_bytes(target_path, patch.iso_offset, len(patch.new))
        if actual != patch.new:
            raise RuntimeError(f"post-write verification failed for {patch.name}")
    return set(sector_parts)


def apply_patches(
    source_raw: bytes, patches: list[common.Patch]
) -> tuple[bytes, set[int]]:
    user_data = extract_user_data(source_raw)
    patched_user = bytearray(user_data)

    for patch in patches:
        actual = bytes(
            patched_user[patch.iso_offset : patch.iso_offset + len(patch.old)]
        )
        if actual != patch.old:
            raise RuntimeError(
                f"{patch.name} signature mismatch at ISO ${patch.iso_offset:06X}: "
                f"expected {patch.old.hex(' ')}, got {actual.hex(' ')}"
            )
        if len(patch.old) != len(patch.new):
            raise RuntimeError(f"{patch.name} is not a fixed-size patch")
        patched_user[
            patch.iso_offset : patch.iso_offset + len(patch.new)
        ] = patch.new

    modified: set[int] = set()
    for patch in patches:
        first = patch.iso_offset // common.USER_DATA_SIZE
        last = (patch.iso_offset + len(patch.new) - 1) // common.USER_DATA_SIZE
        modified.update(range(first, last + 1))

    patched_raw = bytearray(source_raw)
    for sector_index in sorted(modified):
        raw_start = sector_index * common.RAW_SECTOR_SIZE
        sector = bytearray(
            patched_raw[raw_start : raw_start + common.RAW_SECTOR_SIZE]
        )
        user_start = sector_index * common.USER_DATA_SIZE
        sector[
            common.USER_DATA_OFFSET : common.USER_DATA_OFFSET + common.USER_DATA_SIZE
        ] = patched_user[user_start : user_start + common.USER_DATA_SIZE]
        common.rebuild_mode1_sector(sector)
        patched_raw[raw_start : raw_start + common.RAW_SECTOR_SIZE] = sector

    changed = {
        index
        for index in range(len(source_raw) // common.RAW_SECTOR_SIZE)
        if source_raw[
            index * common.RAW_SECTOR_SIZE : (index + 1) * common.RAW_SECTOR_SIZE
        ]
        != patched_raw[
            index * common.RAW_SECTOR_SIZE : (index + 1) * common.RAW_SECTOR_SIZE
        ]
    }
    if changed != modified:
        raise RuntimeError(
            f"unexpected changed sectors: expected {sorted(modified)}, "
            f"got {sorted(changed)}"
        )
    return bytes(patched_raw), modified


def build(version: str, force: bool) -> Path:
    output_dir = BUILD_ROOT / version
    if output_dir.exists():
        if not force:
            raise SystemExit(f"build already exists: {output_dir} (use --force)")
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)

    source_hash = sha256_file(SOURCE_TRACK)
    if source_hash != EXPECTED_SOURCE_SHA256:
        raise RuntimeError("unexpected Track 02 SHA-256")
    if SOURCE_TRACK.stat().st_size % common.RAW_SECTOR_SIZE:
        raise RuntimeError("Track 02 is not raw-sector aligned")

    speakers = read_tsv(SPEAKER_TSV)
    speaker_matches = [
        row
        for row in speakers
        if row["jp_name"] == TARGET_SPEAKER_JP
        and row["status"] in ALLOWED_STATUS
    ]
    if len(speaker_matches) != 1:
        raise RuntimeError(
            f"expected one reviewed {TARGET_SPEAKER_JP!r} speaker row, "
            f"got {len(speaker_matches)}"
        )

    ui_rows = [
        row
        for row in read_tsv(UI_TSV)
        if row["ui_id"] in TARGET_UI_IDS and row["status"] in ALLOWED_STATUS
    ]
    if {row["ui_id"] for row in ui_rows} != TARGET_UI_IDS:
        raise RuntimeError("reviewed UI proof rows are missing")

    speaker_glyphs = ordered_hangul([speaker_matches[0]["ko_name"]])
    menu_glyphs = ordered_hangul([row["ko_text"] for row in ui_rows])
    font_pack, speaker_custom, menu_custom, font_map = build_context_font_pack(
        speaker_glyphs, menu_glyphs
    )
    if GLYPH_BASE + len(font_pack) > FONT_WRAPPER:
        raise RuntimeError("proof font pack overlaps the font wrapper")
    font_wrapper = common.build_font_wrapper(len(font_map))

    patches: list[common.Patch] = [
        common.Patch(
            "font_call",
            common.bank6a_iso(FONT_CALL_CPU),
            ORIGINAL_FONT_CALL,
            bytes((0x20, FONT_WRAPPER & 0xFF, FONT_WRAPPER >> 8)),
            FONT_CALL_CPU,
        ),
        common.Patch(
            "hangul_glyphs",
            common.bank68_iso(GLYPH_BASE),
            bytes((0xFF,)) * len(font_pack),
            font_pack,
            GLYPH_BASE,
        ),
        common.Patch(
            "font_wrapper",
            common.bank68_iso(FONT_WRAPPER),
            bytes((0xFF,)) * len(font_wrapper),
            font_wrapper,
            FONT_WRAPPER,
        ),
    ]

    speaker = speaker_matches[0]
    speaker_offset = int(speaker["disc_offset"], 16) + 1
    speaker_old = speaker["jp_name"].encode("cp932") + b"\xFF"
    speaker_encoded = encode_game_text(speaker["ko_name"], speaker_custom)
    patches.append(
        common.Patch(
            "speaker_receptionist",
            speaker_offset,
            speaker_old,
            fit_record(speaker_encoded, len(speaker_old), "speaker receptionist"),
        )
    )

    proof_rows: list[dict[str, str]] = [
        {
            "kind": "speaker",
            "id": speaker["speaker_id"],
            "jp_text": speaker["jp_name"],
            "ko_text": speaker["ko_name"],
            "occurrences": "1",
            "encoded_hex": speaker_encoded.hex(" ").upper(),
        }
    ]
    for row in sorted(ui_rows, key=lambda item: item["ui_id"]):
        old = row["jp_text"].encode("cp932") + b"\xFF"
        encoded = encode_game_text(row["ko_text"], menu_custom)
        offsets = [int(value, 16) for value in row["all_disc_offsets"].split(",")]
        replacement = fit_record(encoded, len(old), row["ui_id"])
        for index, offset in enumerate(offsets, start=1):
            patches.append(
                common.Patch(
                    f"{row['ui_id'].lower()}_{index:02d}",
                    offset,
                    old,
                    replacement,
                )
            )
        proof_rows.append(
            {
                "kind": "ui",
                "id": row["ui_id"],
                "jp_text": row["jp_text"],
                "ko_text": row["ko_text"],
                "occurrences": str(len(offsets)),
                "encoded_hex": encoded.hex(" ").upper(),
            }
        )

    # Every target is checked against the pristine ISO view before any write.
    for patch in patches:
        actual = read_user_bytes(SOURCE_TRACK, patch.iso_offset, len(patch.old))
        if actual != patch.old:
            raise RuntimeError(
                f"preflight mismatch for {patch.name} at ${patch.iso_offset:06X}"
            )

    patched_track = output_dir / (
        f"Snatcher CD-ROMantic (Japan) (Track 02) [KO {version}].bin"
    )
    modified = apply_patches_streaming(SOURCE_TRACK, patched_track, patches)
    cue_path = output_dir / f"Snatcher CD-ROMantic (Japan) [KO {version}].cue"
    staged = common.make_cue(cue_path, patched_track)
    patched_hash = sha256_file(patched_track)

    write_tsv(output_dir / "hangul_code_map.tsv", font_map)
    write_tsv(output_dir / "speaker_ui_proof.tsv", proof_rows)
    patch_rows = [
        {
            "name": patch.name,
            "cpu_address": (
                f"{patch.cpu_address:04X}" if patch.cpu_address is not None else ""
            ),
            "iso_offset": f"{patch.iso_offset:06X}",
            "raw_offset": f"{common.raw_user_offset(patch.iso_offset):08X}",
            "length": str(len(patch.new)),
            "old_hex": patch.old.hex(" ").upper(),
            "new_hex": patch.new.hex(" ").upper(),
        }
        for patch in patches
    ]
    write_tsv(output_dir / "track02_patches.tsv", patch_rows)

    manifest = {
        "version": version,
        "status": "speaker-ui-static-proof",
        "source_track": str(SOURCE_TRACK),
        "source_sha256": source_hash,
        "patched_track": patched_track.name,
        "patched_sha256": patched_hash,
        "cue": cue_path.name,
        "cue_tracks": staged,
        "speaker": {
            "jp": speaker["jp_name"],
            "ko": speaker["ko_name"],
            "iso_offset": f"{speaker_offset:06X}",
        },
        "ui_ids": sorted(TARGET_UI_IDS),
        "glyph_count_including_period": len(font_map),
        "font_bytes": len(font_pack),
        "menu_glyph_y_shift": -1,
        "modified_sectors": [f"{value:06X}" for value in sorted(modified)],
    }
    (output_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    (output_dir / "verification.txt").write_text(
        "\n".join(
            [
                f"Snatcher Korean patch {version} - speaker/UI static proof",
                "",
                f"Source SHA-256:  {source_hash}",
                f"Patched SHA-256: {patched_hash}",
                f"Modified sectors: {', '.join(f'{x:06X}' for x in sorted(modified))}",
                f"Custom font bytes: {len(font_pack)}",
                "",
                "Static verification passed:",
                "- every original string signature matched",
                "- every replacement fits inside its original record",
                "- only expected Track 02 sectors changed",
                "- all 24 CUE tracks were staged",
                "",
            ]
        ),
        encoding="utf-8",
    )
    (output_dir / "TEST_IN_MESEN.txt").write_text(
        "\n".join(
            [
                f"Snatcher Korean patch {version} - speaker/UI runtime test",
                "",
                f"Open: {cue_path}",
                "Power-cycle Mesen and do not run Lua scripts.",
                "",
                "Expected:",
                "1. Reception speaker name 受付嬢 appears as 안내원 in yellow.",
                "2. Every 見る menu command appears as 보다.",
                "3. Every 聞く menu command appears as 묻다.",
                "4. Menu colors, cursor, other Japanese text, and progression stay normal.",
                "",
                "If Korean byte pairs are split or render as garbage, preserve this build",
                "and report one screenshot; the static placement itself has already passed.",
                "",
            ]
        ),
        encoding="utf-8",
    )
    return output_dir


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default="0.1.6")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    output = build(args.version, args.force)
    print(f"built: {output}")


if __name__ == "__main__":
    main()
