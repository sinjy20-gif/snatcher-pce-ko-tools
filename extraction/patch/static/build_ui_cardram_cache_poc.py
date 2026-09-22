#!/usr/bin/env python3
"""Build a one-time Track-24 -> Card-RAM UI font-cache proof.

This is deliberately a two-glyph proof (``보다``).  It verifies the final
architecture before the complete UI/speaker atlas is generated:

* Track 24 stores the font asset.
* The first renderer entry loads that asset once into Card-RAM bank $6B.
* The UI font wrapper maps $6B only for the native 32-byte glyph copy, then
  restores MPR4 immediately.

The normal Japanese renderer, main dialogue cache and all non-F0 codes retain
their original path.  The test starts from pristine Track 02/24.
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
SOURCE_TRACK02 = ROM_DIR / "Snatcher CD-ROMantic (Japan) (Track 02).bin"
SOURCE_TRACK24 = ROM_DIR / "Snatcher CD-ROMantic (Japan) (Track 24).bin"
BUILD_ROOT = ROOT / "build" / "patch"
UI_TSV = ROOT / "translation" / "ui_text.tsv"
STATIC_DIR = ROOT / "extraction" / "patch" / "static"
sys.path.insert(0, str(STATIC_DIR))

import build_disc_patch as common  # noqa: E402
import build_speaker_ui_proof as stream  # noqa: E402
import build_track24_loader_proof as track24  # noqa: E402


VERSION_DEFAULT = "ui-cardram-cache-poc-v1"
UI_ID = "UI0002"  # The proven reception action-menu record: 調べる.

FONT_DISPATCH_CPU = 0x648C
ORIGINAL_FONT_DISPATCH = bytes((0x20, 0xC2, 0x69))
RENDERER_ENTRY_CPU = 0x66E5
# $66E5's complete ten-byte renderer prologue.  The streaming patcher rightly
# refuses variable-length replacements, so verify and replace the full block.
ORIGINAL_RENDERER_ENTRY = bytes.fromhex("AD 71 34 85 03 AD 72 34 85 04")

# Track-02 code caves.  $5E40 is in the static MPR2=$68 window.  $7F50 is in
# the active renderer bank (MPR3=$6A); it is limited to 64 bytes by $7F90.
LOADER_CPU = 0x5E40
LOADER_END = 0x6000
WRAPPER_CPU = 0x7F50
WRAPPER_END = 0x7F90

# Runtime Card-RAM bank and the CPU window used only during a glyph copy.
CACHE_BANK = 0x6B
CACHE_CPU = 0x8000  # MPR4 window
LOAD_FLAG = 0x5C60
LOAD_STATUS = 0x5C61
LOAD_MAGIC = 0xA5

BIOS_CD_BASE = 0xE006
BIOS_CD_READ = 0xE009


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-16", newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def build_atlas() -> tuple[bytes, list[dict[str, str]]]:
    chars = ("보", "다")
    parsed = common.parse_bdf(common.FONT_BDF, {ord(char) for char in chars})
    atlas = bytearray()
    rows: list[dict[str, str]] = []
    for index, char in enumerate(chars):
        atlas.extend(common.glyph_1bpp_left_shifted(*parsed[ord(char)]))
        rows.append({
            "game_code": f"F0{0x40 + index:02X}",
            "character": char,
            "cardram_bank": f"{CACHE_BANK:02X}",
            "cardram_cpu": f"{CACHE_CPU + index * 32:04X}",
        })
    return bytes(atlas), rows


def emit_set_cd_base(a: common.Assembler, sector: int) -> None:
    # Base 0, binary-record address type.  This is the proven 0.1.5+ setup.
    for zp, value in (
        (0xF8, (sector >> 16) & 0xFF),
        (0xF9, (sector >> 8) & 0xFF),
        (0xFA, sector & 0xFF),
        (0xFB, 0x00),
        (0xFC, 0x01),
    ):
        a.emit(0xA9, value, 0x85, zp)
    a.abs(0x20, BIOS_CD_BASE)


def build_loader(track24_index1_lba: int, track02_index1_lba: int, relative_sector: int) -> bytes:
    """One-time 2 KiB read into MPR4=$6B, then reproduce $66E5's prologue."""

    a = common.Assembler(LOADER_CPU)
    a.emit(0xDA, 0x5A)  # PHX / PHY
    for zp in range(0xF8, 0x100):
        a.emit(0xA5, zp, 0x48)  # save BIOS parameter block

    a.abs(0xAD, LOAD_FLAG)
    a.emit(0xC9, LOAD_MAGIC)
    a.branch(0xF0, "restore")

    # Save current MPR4, map the dedicated Card-RAM page at $8000-$9FFF.
    a.emit(0x43, 0x10, 0x48)  # TMA #$10 / PHA
    a.emit(0xA9, CACHE_BANK, 0x53, 0x10)  # LDA #$6B / TAM #$10

    emit_set_cd_base(a, track24_index1_lba)
    # AX=2048, BX=$8000, CL/CH/DL=relative sector, DH=local byte transfer.
    for zp, value in (
        (0xF8, 0x00), (0xF9, 0x08),
        (0xFA, CACHE_CPU & 0xFF), (0xFB, CACHE_CPU >> 8),
        (0xFC, (relative_sector >> 16) & 0xFF),
        (0xFD, (relative_sector >> 8) & 0xFF),
        (0xFE, relative_sector & 0xFF), (0xFF, 0x00),
    ):
        a.emit(0xA9, value, 0x85, zp)
    a.abs(0x20, BIOS_CD_READ)
    a.abs(0x8D, LOAD_STATUS)

    # Put the original page back before any more game/BIOS code runs.
    a.emit(0x68, 0x53, 0x10)  # PLA / TAM #$10
    emit_set_cd_base(a, track02_index1_lba)
    a.abs(0xAD, LOAD_STATUS)
    a.branch(0xD0, "restore")
    a.emit(0xA9, LOAD_MAGIC)
    a.abs(0x8D, LOAD_FLAG)

    a.label("restore")
    for zp in reversed(range(0xF8, 0x100)):
        a.emit(0x68, 0x85, zp)
    a.emit(0xFA, 0x7A)  # PLX / PLY
    # Recreate the overwritten renderer entry exactly.
    a.abs(0xAD, 0x3471)
    a.emit(0x85, 0x03)
    a.abs(0xAD, 0x3472)
    a.emit(0x85, 0x04, 0x60)
    return a.finish()


def build_wrapper() -> bytes:
    """F040/F041 -> MPR4=$6B atlas; every other code -> native $69C2.

    It intentionally fits in the 64-byte $7F50-$7F8F cave.
    """

    a = common.Assembler(WRAPPER_CPU)
    # $3471/$3472 have advanced to the trail byte when this caller executes.
    # Rewind by one without a branch, leaving $00/$01 as native copy scratch.
    a.abs(0xAD, 0x3471)
    a.emit(0x38, 0xE9, 0x01, 0x85, 0x00)  # low - 1
    a.abs(0xAD, 0x3472)
    a.emit(0xE9, 0x00, 0x85, 0x01)        # high - borrow
    a.emit(0xA0, 0x00, 0xB1, 0x00, 0xC9, 0xF0)
    a.branch(0xD0, "fallback")
    a.emit(0xC8, 0xB1, 0x00, 0x38, 0xE9, 0x40, 0xC9, 0x02)
    a.branch(0xB0, "fallback")
    a.emit(0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x85, 0x00)
    a.emit(0xA9, CACHE_CPU >> 8, 0x85, 0x01)
    a.emit(0x43, 0x10, 0x48)              # save MPR4
    a.emit(0xA9, CACHE_BANK, 0x53, 0x10)  # map $6B at $8000
    a.emit(0x82)
    a.abs(0x20, 0x69FC)
    a.emit(0x68, 0x53, 0x10, 0x62, 0x60)  # restore MPR4 / CLA / RTS
    a.label("fallback")
    a.abs(0x20, 0x69C2)
    a.emit(0x60)
    return a.finish()


def write_tsv(path: Path, rows: list[dict[str, str]]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]), delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def build(version: str, force: bool) -> Path:
    output_dir = BUILD_ROOT / version
    if output_dir.exists():
        if not force:
            raise RuntimeError(f"already exists: {output_dir} (use --force)")
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)

    if sha256_file(SOURCE_TRACK02) != common.EXPECTED_SOURCE_SHA256:
        raise RuntimeError("unexpected Track 02 SHA-256")
    if sha256_file(SOURCE_TRACK24) != track24.EXPECTED_TRACK24_SHA256:
        raise RuntimeError("unexpected Track 24 SHA-256")

    starts, original_disc_sectors = track24.disc_track_starts()
    track24_sectors = SOURCE_TRACK24.stat().st_size // track24.RAW_SECTOR_SIZE
    first_appended_lba = starts[24] + track24_sectors
    if first_appended_lba != original_disc_sectors:
        raise RuntimeError("Track 24 is not the final source track")
    track02_index1_lba = starts[2] + 225
    track24_index1_lba = starts[24] + 225
    relative_sector = first_appended_lba - track24_index1_lba

    rows = read_tsv(UI_TSV)
    row = next((item for item in rows if item["ui_id"] == UI_ID), None)
    if row is None:
        raise RuntimeError(f"missing {UI_ID}")
    original = row["jp_text"].encode("cp932") + b"\xFF"
    replacement = bytes((0xF0, 0x40, 0xF0, 0x41, 0xFF)).ljust(len(original), b"\xFF")
    if len(replacement) != len(original):
        raise RuntimeError("the UI proof record is too short")

    atlas, glyph_rows = build_atlas()
    loader = build_loader(track24_index1_lba, track02_index1_lba, relative_sector)
    wrapper = build_wrapper()
    if LOADER_CPU + len(loader) > LOADER_END:
        raise RuntimeError(f"loader needs {len(loader)} bytes, cave has {LOADER_END - LOADER_CPU}")
    if WRAPPER_CPU + len(wrapper) > WRAPPER_END:
        raise RuntimeError(f"wrapper needs {len(wrapper)} bytes, cave has {WRAPPER_END - WRAPPER_CPU}")

    patches: list[common.Patch] = [
        common.Patch("ui_cache_loader", common.bank68_iso(LOADER_CPU), b"\xFF" * len(loader), loader, LOADER_CPU),
        common.Patch("ui_cache_wrapper", common.bank6a_iso(WRAPPER_CPU), b"\xFF" * len(wrapper), wrapper, WRAPPER_CPU),
        common.Patch("ui_cache_font_dispatch", common.bank6a_iso(FONT_DISPATCH_CPU), ORIGINAL_FONT_DISPATCH, bytes((0x20, WRAPPER_CPU & 0xFF, WRAPPER_CPU >> 8)), FONT_DISPATCH_CPU),
        common.Patch("ui_cache_renderer_entry", common.bank6a_iso(RENDERER_ENTRY_CPU), ORIGINAL_RENDERER_ENTRY, bytes((0x20, LOADER_CPU & 0xFF, LOADER_CPU >> 8)) + b"\xEA" * 7, RENDERER_ENTRY_CPU),
        common.Patch("ui_cache_state", common.bank68_iso(LOAD_FLAG), b"\xFF\xFF", b"\x00\xFF", LOAD_FLAG),
    ]
    for number, offset in enumerate(int(value, 16) for value in row["all_disc_offsets"].split(",")):
        patches.append(common.Patch(f"{UI_ID.lower()}_{number + 1:02d}", offset, original, replacement))

    for patch in patches:
        actual = stream.read_user_bytes(SOURCE_TRACK02, patch.iso_offset, len(patch.old))
        if actual != patch.old:
            raise RuntimeError(f"preflight mismatch {patch.name} at ${patch.iso_offset:06X}")

    patched02 = output_dir / f"Snatcher CD-ROMantic (Japan) (Track 02) [{version}].bin"
    modified = stream.apply_patches_streaming(SOURCE_TRACK02, patched02, patches)
    user_data = bytearray(track24.USER_DATA_SIZE)
    user_data[:len(atlas)] = atlas
    sector = track24.make_mode1_sector(first_appended_lba, bytes(user_data))
    track24.verify_mode1_sector(sector, first_appended_lba)
    patched24 = output_dir / f"Snatcher CD-ROMantic (Japan) (Track 24) [{version}].bin"
    shutil.copyfile(SOURCE_TRACK24, patched24)
    with patched24.open("ab") as handle:
        handle.write(sector)
    cue = output_dir / f"Snatcher CD-ROMantic (Japan) [{version}].cue"
    staged = track24.stage_cue(cue, patched02, patched24)

    write_tsv(output_dir / "glyph_map.tsv", glyph_rows)
    (output_dir / "manifest.json").write_text(json.dumps({
        "kind": "ui-cardram-cache-poc",
        "version": version,
        "cache_bank": f"{CACHE_BANK:02X}",
        "cache_window": "MPR4 / $8000-$9FFF",
        "atlas_bytes": len(atlas),
        "loader_cpu": f"{LOADER_CPU:04X}",
        "loader_bytes": len(loader),
        "wrapper_cpu": f"{WRAPPER_CPU:04X}",
        "wrapper_bytes": len(wrapper),
        "track24_relative_sector": relative_sector,
        "cue_tracks": staged,
        "modified_track02_sectors": [f"{sector:06X}" for sector in sorted(modified)],
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (output_dir / "TEST_IN_MESEN.txt").write_text(
        "Load the CUE, power-cycle, then open the reception action menu.\n"
        "Expected: the proven UI record reads '보다' at native speed; reopen it twice.\n"
        "This verifies the one-time Track-24 -> Card-RAM $6B atlas cache.\n",
        encoding="utf-8-sig",
    )
    return output_dir


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default=VERSION_DEFAULT)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    print(build(args.version, args.force))
