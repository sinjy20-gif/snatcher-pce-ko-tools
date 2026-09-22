#!/usr/bin/env python3
"""Build the complete generated-translation Track-24 patch.

This is the production successor to the one-line and speaker/UI proofs.  It
keeps every original script byte intact.  The renderer-entry hook hashes the
completed Japanese buffer, loads one exact-byte lookup bucket, then loads one
asset sector containing both the Korean replacement and its complete local
font pack before the first glyph is drawn.
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
LAYOUT_DIR = ROOT / "build" / "translation" / "current" / "runtime_layout"
STATIC_DIR = ROOT / "extraction" / "patch" / "static"
TRANSLATION_DIR = ROOT / "extraction" / "translation"
sys.path[:0] = [str(STATIC_DIR), str(TRANSLATION_DIR)]

import build_disc_patch as common  # noqa: E402
import build_full_overlay_layout as layout  # noqa: E402
import build_speaker_ui_proof as proof  # noqa: E402
import build_track24_loader_proof as track24  # noqa: E402


EXPECTED_TRACK02_SHA256 = common.EXPECTED_SOURCE_SHA256
EXPECTED_TRACK24_SHA256 = track24.EXPECTED_TRACK24_SHA256
VERSION_DEFAULT = "0.2.0"

BIOS_CD_BASE = 0xE006
BIOS_CD_READ = 0xE009

CACHE_BASE = 0x5B80
ASSET_TEXT = CACHE_BASE + layout.ASSET_HEADER_SIZE
GLYPH_CACHE = CACHE_BASE + layout.ASSET_FONT_OFFSET
RUNTIME_START = 0x5E40
RUNTIME_END = 0x6000
FONT_WRAPPER = 0x7F50
SECTOR_LOADER = 0x7F88
PRIVATE_BASE = 0x7FEC

STATE_LO = PRIVATE_BASE + 0
STATE_HI = PRIVATE_BASE + 1
READ_STATUS = PRIVATE_BASE + 2
SECTOR_LO = PRIVATE_BASE + 3
SECTOR_MID = PRIVATE_BASE + 4
HASH_LO = PRIVATE_BASE + 5
HASH_HI = PRIVATE_BASE + 6
SOURCE_LEN = PRIVATE_BASE + 7
SIG_XOR = PRIVATE_BASE + 8
SIG_CUMULATIVE = PRIVATE_BASE + 9
ASSET_LO = PRIVATE_BASE + 10
ASSET_HI = PRIVATE_BASE + 11
NEXT_LO = PRIVATE_BASE + 12
NEXT_HI = PRIVATE_BASE + 13
PASS_NO = PRIVATE_BASE + 14
RECORD_COUNT = PRIVATE_BASE + 15
MATCH_LO = PRIVATE_BASE + 16
MATCH_HI = PRIVATE_BASE + 17

FONT_CALL = 0x648C
RENDERER_ENTRY = 0x66E5
ORIGINAL_FONT_CALL = bytes.fromhex("20 C2 69")
ORIGINAL_RENDERER_ENTRY = bytes.fromhex("AD 71 34")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def align(value: int, boundary: int = 0x10) -> int:
    return (value + boundary - 1) // boundary * boundary


def emit_cd_base(a: common.Assembler, base_sector: int) -> None:
    for zp, value in (
        (0xF8, (base_sector >> 16) & 0xFF),
        (0xF9, (base_sector >> 8) & 0xFF),
        (0xFA, base_sector & 0xFF),
        (0xFB, 0x00),
        (0xFC, 0x01),
    ):
        a.emit(0xA9, value, 0x85, zp)
    a.abs(0x20, BIOS_CD_BASE)


def build_sector_loader(
    origin: int,
    track24_index1_lba: int,
    track02_index1_lba: int,
) -> bytes:
    """Read 704 bytes from one relative Track-24 sector into $5B80."""

    a = common.Assembler(origin)
    # The renderer preloader owns register and $F8-$FF preservation.  Keeping
    # this helper leaf-like lets it fit beside the font wrapper in bank $6A.
    for zp, value in (
        (0xF8, (track24_index1_lba >> 16) & 0xFF),
        (0xF9, (track24_index1_lba >> 8) & 0xFF),
        (0xFA, track24_index1_lba & 0xFF),
        (0xFB, 0x00),
        (0xFC, 0x01),
    ):
        a.emit(0xA9, value, 0x85, zp)
    a.abs(0x20, BIOS_CD_BASE)
    for zp, value in (
        (0xF8, layout.ASSET_READ_BYTES & 0xFF),
        (0xF9, layout.ASSET_READ_BYTES >> 8),
        (0xFA, CACHE_BASE & 0xFF),
        (0xFB, CACHE_BASE >> 8),
        (0xFC, 0x00),
    ):
        a.emit(0xA9, value, 0x85, zp)
    a.abs(0xAD, SECTOR_MID)
    a.emit(0x85, 0xFD)
    a.abs(0xAD, SECTOR_LO)
    a.emit(0x85, 0xFE)
    a.emit(0xA9, 0x00, 0x85, 0xFF)
    a.abs(0x20, BIOS_CD_READ)
    a.abs(0x8D, READ_STATUS)

    # $FB/$FC already contain the CD_BASE mode used by both bases.
    for zp, value in (
        (0xF8, (track02_index1_lba >> 16) & 0xFF),
        (0xF9, (track02_index1_lba >> 8) & 0xFF),
        (0xFA, track02_index1_lba & 0xFF),
        (0xFB, 0x00),
        (0xFC, 0x01),
    ):
        a.emit(0xA9, value, 0x85, zp)
    a.abs(0x20, BIOS_CD_BASE)
    # Both BIOS calls may use normal zero page.  Recreate the authoritative
    # renderer pointer before returning to the lookup routine.
    a.abs(0xAD, 0x3471)
    a.emit(0x85, 0x03)
    a.abs(0xAD, 0x3472)
    a.emit(0x85, 0x04)
    a.abs(0xAD, READ_STATUS)
    a.emit(0x60)
    return a.finish()


def build_font_wrapper(origin: int) -> bytes:
    """Resolve F040-F052 from the already preloaded local font pack."""

    a = common.Assembler(origin)
    a.emit(0xA5, 0xF9, 0xC9, 0xF0)
    a.branch(0xF0, "lead_ok")
    a.abs(0x4C, 0x69C2)
    a.label("lead_ok")
    a.emit(0xA5, 0xF8, 0xC9, 0x40)
    a.branch(0x90, "fallback")
    a.emit(0xC9, 0x40 + layout.FONT_GLYPH_CAPACITY)
    a.branch(0xB0, "fallback")
    a.emit(0x38, 0xE9, 0x40)  # index
    a.emit(0x48, 0x18, 0x69, 0x07, 0x4A, 0x4A, 0x4A)
    a.emit(0x18, 0x69, GLYPH_CACHE >> 8, 0x85, 0x01)
    a.emit(0x68, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A)
    a.emit(0x18, 0x69, GLYPH_CACHE & 0xFF, 0x85, 0x00)
    a.emit(0x82)
    a.abs(0x20, 0x69FC)
    a.emit(0x62, 0x60)
    a.label("fallback")
    a.abs(0x4C, 0x69C2)
    return a.finish()


def build_renderer_preloader(
    origin: int,
    loader_address: int,
    bucket_relative: int,
    asset_relative: int,
) -> bytes:
    """Match source, load Korean text/font, and recreate LDA $3471."""

    if not 0 <= bucket_relative < 0x10000:
        raise RuntimeError("bucket relative sector exceeds 16 bits")
    if not 0 <= asset_relative < 0x10000:
        raise RuntimeError("asset relative sector exceeds 16 bits")

    a = common.Assembler(origin)
    a.emit(0xDA, 0x5A)  # PHX / PHY
    for zp in range(0x05, 0x09):
        a.emit(0xA5, zp, 0x48)
    a.emit(0xA2, 0x07)
    a.label("save_bios_zp")
    a.emit(0xB5, 0xF8, 0x48, 0xCA)
    a.branch(0x10, "save_bios_zp")

    a.abs(0xAD, 0x3471)
    a.emit(0x85, 0x03, 0xC9, 0x19)
    a.branch(0xF0, "low_ok")
    a.abs(0x4C, "done")
    a.label("low_ok")
    a.abs(0xAD, 0x3472)
    a.emit(0x85, 0x04, 0xC9, 0x36)
    a.branch(0xF0, "pointer_ok")
    a.abs(0x4C, "done")
    a.label("pointer_ok")

    # MPR6 is the already-measured scene pack stored in the master.  Seed a
    # zero state as $01xx for explicit root_mode=AUTO records.  The existing
    # miss path retries state zero, so unmarked roots remain byte-for-byte in
    # lookup semantics (only the first state comparison is new).
    a.abs(0xAD, STATE_LO)
    a.abs(0x0D, STATE_HI)
    a.branch(0xD0, "context_state_ready")
    a.emit(0x43, 0x40)  # TMA #$40 (MPR6)
    a.abs(0x8D, STATE_LO)
    a.emit(0xA9, 0x01)
    a.abs(0x8D, STATE_HI)
    a.label("context_state_ready")

    # Hash = unsigned sum(source bytes) modulo 1024; source length excludes FF.
    a.emit(0xA2, 0x04)
    a.label("clear_signatures")
    a.abs(0x9E, HASH_LO)  # STZ abs,X
    a.emit(0xCA)
    a.branch(0x10, "clear_signatures")
    a.emit(0xA0, 0x00)
    a.label("hash_loop")
    a.emit(0xB1, 0x03, 0xC9, 0xFF)
    a.branch(0xF0, "hash_done")
    a.abs(0x4D, SIG_XOR)  # EOR abs
    a.abs(0x8D, SIG_XOR)
    a.emit(0xB1, 0x03)
    a.emit(0x18)
    a.abs(0x6D, HASH_LO)  # ADC abs
    a.abs(0x8D, HASH_LO)
    a.abs(0xAD, HASH_HI)
    a.emit(0x69, 0x00, 0x29, 0x03)
    a.abs(0x8D, HASH_HI)
    a.abs(0xAD, SIG_CUMULATIVE)
    a.emit(0x18)
    a.abs(0x6D, HASH_LO)
    a.abs(0x8D, SIG_CUMULATIVE)
    a.emit(0xC8, 0xC0, 0x40)
    a.branch(0x90, "hash_loop")
    a.abs(0x4C, "no_match")
    a.label("hash_done")
    a.emit(0x98)
    a.abs(0x8D, SOURCE_LEN)

    # Load the selected lookup sector.
    a.emit(0x18)
    a.abs(0xAD, HASH_LO)
    a.emit(0x69, bucket_relative & 0xFF)
    a.abs(0x8D, SECTOR_LO)
    a.abs(0xAD, HASH_HI)
    a.emit(0x69, (bucket_relative >> 8) & 0xFF)
    a.abs(0x8D, SECTOR_MID)
    a.abs(0x20, loader_address)
    a.emit(0xC9, 0x00)
    a.branch(0xF0, "bucket_loaded")
    a.abs(0x4C, "no_match")
    a.label("bucket_loaded")
    a.abs(0xAD, CACHE_BASE + 4)
    a.abs(0x8D, RECORD_COUNT)
    a.abs(0xAD, STATE_LO)
    a.abs(0x8D, MATCH_LO)
    a.abs(0xAD, STATE_HI)
    a.abs(0x8D, MATCH_HI)
    a.abs(0x9C, PASS_NO)

    a.label("restart_scan")
    a.emit(0xA9, (CACHE_BASE + layout.BUCKET_HEADER_SIZE) & 0xFF, 0x85, 0x05)
    a.emit(0xA9, (CACHE_BASE + layout.BUCKET_HEADER_SIZE) >> 8, 0x85, 0x06)
    a.abs(0xAD, CACHE_BASE + 4)
    a.abs(0x8D, RECORD_COUNT)

    a.label("scan_record")
    a.abs(0xAD, RECORD_COUNT)
    a.branch(0xD0, "have_record")
    a.abs(0xAD, PASS_NO)
    a.branch(0xF0, "retry_root_state")
    a.abs(0x4C, "no_match")
    a.label("retry_root_state")
    a.abs(0xAD, MATCH_LO)
    a.abs(0x0D, MATCH_HI)  # ORA abs
    a.branch(0xD0, "have_parent_state")
    a.abs(0x4C, "no_match")
    a.label("have_parent_state")
    a.abs(0x9C, MATCH_LO)
    a.abs(0x9C, MATCH_HI)
    a.emit(0xA9, 0x01)
    a.abs(0x8D, PASS_NO)
    a.abs(0x4C, "restart_scan")

    a.label("have_record")
    # Exact state first.  During the root pass, FFFF wildcard speaker/UI
    # records are also eligible.
    a.emit(0xA0, 0x00, 0xB1, 0x05)
    a.abs(0xCD, MATCH_LO)
    a.branch(0xD0, "try_wildcard")
    a.emit(0xC8, 0xB1, 0x05)
    a.abs(0xCD, MATCH_HI)
    a.branch(0xF0, "state_ok")
    a.label("try_wildcard")
    a.abs(0xAD, MATCH_LO)
    a.abs(0x0D, MATCH_HI)
    a.branch(0xF0, "wildcard_pass")
    a.abs(0x4C, "skip_record")
    a.label("wildcard_pass")
    a.emit(0xA0, 0x00, 0xB1, 0x05, 0xC9, 0xFF)
    a.branch(0xF0, "wildcard_low_ok")
    a.abs(0x4C, "skip_record")
    a.label("wildcard_low_ok")
    a.emit(0xC8, 0xB1, 0x05, 0xC9, 0xFF)
    a.branch(0xF0, "state_ok")
    a.abs(0x4C, "skip_record")

    a.label("state_ok")
    a.emit(0xA0, 0x06, 0xB1, 0x05)
    a.abs(0xCD, SOURCE_LEN)
    a.branch(0xF0, "length_ok")
    a.abs(0x4C, "skip_record")
    a.label("length_ok")
    a.emit(0xC8, 0xB1, 0x05)
    a.abs(0xCD, SIG_XOR)
    a.branch(0xF0, "xor_ok")
    a.abs(0x4C, "skip_record")
    a.label("xor_ok")
    a.emit(0xC8, 0xB1, 0x05)
    a.abs(0xCD, SIG_CUMULATIVE)
    a.branch(0xF0, "signature_ok")
    a.abs(0x4C, "skip_record")
    a.label("signature_ok")

    # Preserve the record result before the asset read replaces the bucket.
    a.emit(0xA0, 0x02, 0xB1, 0x05)
    a.abs(0x8D, NEXT_LO)
    a.emit(0xC8, 0xB1, 0x05)
    a.abs(0x8D, NEXT_HI)
    a.emit(0xC8, 0xB1, 0x05)
    a.abs(0x8D, ASSET_LO)
    a.emit(0xC8, 0xB1, 0x05)
    a.abs(0x8D, ASSET_HI)
    a.abs(0xAD, NEXT_LO)
    a.abs(0x8D, STATE_LO)
    a.abs(0xAD, NEXT_HI)
    a.abs(0x8D, STATE_HI)

    a.emit(0x18)
    a.abs(0xAD, ASSET_LO)
    a.emit(0x69, asset_relative & 0xFF)
    a.abs(0x8D, SECTOR_LO)
    a.abs(0xAD, ASSET_HI)
    a.emit(0x69, (asset_relative >> 8) & 0xFF)
    a.abs(0x8D, SECTOR_MID)
    a.abs(0x20, loader_address)
    a.emit(0xC9, 0x00)
    a.branch(0xF0, "asset_loaded")
    a.abs(0x4C, "no_match")
    a.label("asset_loaded")
    # Copy exactly the encoded length, including FF, into the original output
    # buffer.  The loaded font already occupies $5BE0-$5E3F.
    a.abs(0xAE, CACHE_BASE + 4)
    a.emit(0xA9, ASSET_TEXT & 0xFF, 0x85, 0x07)
    a.emit(0xA9, ASSET_TEXT >> 8, 0x85, 0x08)
    a.emit(0xA0, 0x00)
    a.label("copy_text")
    a.emit(0xB1, 0x07, 0x91, 0x03, 0xC8, 0xCA)
    a.branch(0xD0, "copy_text")
    a.abs(0x4C, "done")

    a.label("skip_record")
    a.emit(0x18, 0xA5, 0x05, 0x69, layout.RECORD_SIZE, 0x85, 0x05)
    a.emit(0xA5, 0x06, 0x69, 0x00, 0x85, 0x06)
    a.abs(0xCE, RECORD_COUNT)
    a.abs(0x4C, "scan_record")

    a.label("no_match")
    a.abs(0x9C, STATE_LO)
    a.abs(0x9C, STATE_HI)
    a.label("done")
    a.emit(0xA2, 0x00)
    a.label("restore_bios_zp")
    a.emit(0x68, 0x95, 0xF8, 0xE8, 0xE0, 0x08)
    a.branch(0x90, "restore_bios_zp")
    for zp in reversed(range(0x05, 0x09)):
        a.emit(0x68, 0x85, zp)
    a.emit(0x7A, 0xFA)
    a.abs(0xAD, 0x3471)  # recreate the overwritten renderer instruction
    a.emit(0x60)
    return a.finish()


def write_tsv(path: Path, rows: list[dict[str, str]]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]), delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def build(version: str, force: bool) -> Path:
    output_dir = BUILD_ROOT / version
    if output_dir.exists():
        if not force:
            raise SystemExit(f"build already exists: {output_dir} (use --force)")
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)

    if sha256_file(SOURCE_TRACK02) != EXPECTED_TRACK02_SHA256:
        raise RuntimeError("unexpected Track 02 SHA-256")
    if sha256_file(SOURCE_TRACK24) != EXPECTED_TRACK24_SHA256:
        raise RuntimeError("unexpected Track 24 SHA-256")

    layout_manifest = layout.build(
        layout.DEFAULT_MASTER,
        layout.DEFAULT_SPEAKERS,
        layout.DEFAULT_UI,
        LAYOUT_DIR,
        layout.DEFAULT_COMPILED,
        clean=True,
    )
    lookup_user = (LAYOUT_DIR / "lookup_user_sectors.bin").read_bytes()
    asset_user = (LAYOUT_DIR / "asset_user_sectors.bin").read_bytes()
    user_sectors = [
        lookup_user[index:index + track24.USER_DATA_SIZE]
        for index in range(0, len(lookup_user), track24.USER_DATA_SIZE)
    ] + [
        asset_user[index:index + track24.USER_DATA_SIZE]
        for index in range(0, len(asset_user), track24.USER_DATA_SIZE)
    ]

    starts, original_disc_sectors = track24.disc_track_starts()
    track24_sectors = SOURCE_TRACK24.stat().st_size // track24.RAW_SECTOR_SIZE
    first_appended_lba = starts[24] + track24_sectors
    if first_appended_lba != original_disc_sectors:
        raise RuntimeError("Track 24 is not the final source track")
    track02_index1_lba = starts[2] + 225
    track24_index1_lba = starts[24] + 225
    bucket_relative = first_appended_lba - track24_index1_lba
    asset_relative = bucket_relative + layout.BUCKET_COUNT

    loader_code = build_sector_loader(SECTOR_LOADER, track24_index1_lba, track02_index1_lba)
    preloader_address = RUNTIME_START
    preloader_code = build_renderer_preloader(
        preloader_address,
        SECTOR_LOADER,
        bucket_relative,
        asset_relative,
    )
    wrapper_code = build_font_wrapper(FONT_WRAPPER)
    if preloader_address + len(preloader_code) > RUNTIME_END:
        raise RuntimeError(
            f"runtime ends at ${preloader_address + len(preloader_code):04X}, beyond ${RUNTIME_END:04X}"
        )
    if FONT_WRAPPER + len(wrapper_code) > SECTOR_LOADER:
        raise RuntimeError("font wrapper overlaps sector loader")
    if SECTOR_LOADER + len(loader_code) > PRIVATE_BASE:
        raise RuntimeError("sector loader overlaps private state")

    patches = [
        common.Patch(
            "font_call",
            common.bank6a_iso(FONT_CALL),
            ORIGINAL_FONT_CALL,
            bytes((0x20, FONT_WRAPPER & 0xFF, FONT_WRAPPER >> 8)),
            FONT_CALL,
        ),
        common.Patch(
            "renderer_preload_call",
            common.bank6a_iso(RENDERER_ENTRY),
            ORIGINAL_RENDERER_ENTRY,
            bytes((0x20, preloader_address & 0xFF, preloader_address >> 8)),
            RENDERER_ENTRY,
        ),
        common.Patch(
            "sector_loader",
            common.bank6a_iso(SECTOR_LOADER),
            bytes((0xFF,)) * len(loader_code),
            loader_code,
            SECTOR_LOADER,
        ),
        common.Patch(
            "renderer_preloader",
            common.bank68_iso(preloader_address),
            bytes((0xFF,)) * len(preloader_code),
            preloader_code,
            preloader_address,
        ),
        common.Patch(
            "font_wrapper",
            common.bank6a_iso(FONT_WRAPPER),
            bytes((0xFF,)) * len(wrapper_code),
            wrapper_code,
            FONT_WRAPPER,
        ),
        common.Patch(
            "private_state_init",
            common.bank6a_iso(PRIVATE_BASE),
            bytes((0xFF,)) * (0x8000 - PRIVATE_BASE),
            bytes((0x00,)) * (0x8000 - PRIVATE_BASE),
            PRIVATE_BASE,
        ),
    ]
    for patch in patches:
        actual = proof.read_user_bytes(SOURCE_TRACK02, patch.iso_offset, len(patch.old))
        if actual != patch.old:
            raise RuntimeError(f"preflight mismatch for {patch.name} at ${patch.iso_offset:06X}")

    patched02 = output_dir / f"Snatcher CD-ROMantic (Japan) (Track 02) [KO {version}].bin"
    modified02 = proof.apply_patches_streaming(SOURCE_TRACK02, patched02, patches)

    patched24 = output_dir / f"Snatcher CD-ROMantic (Japan) (Track 24) [KO {version}].bin"
    shutil.copyfile(SOURCE_TRACK24, patched24)
    appended = bytearray()
    for index, user_data in enumerate(user_sectors):
        lba = first_appended_lba + index
        sector = track24.make_mode1_sector(lba, user_data)
        track24.verify_mode1_sector(sector, lba)
        appended.extend(sector)
    with patched24.open("ab") as handle:
        handle.write(appended)

    cue = output_dir / f"Snatcher CD-ROMantic (Japan) [KO {version}].cue"
    staged = track24.stage_cue(cue, patched02, patched24)
    shutil.copyfile(LAYOUT_DIR / "lookup_records.tsv", output_dir / "lookup_records.tsv")
    shutil.copyfile(LAYOUT_DIR / "assets.tsv", output_dir / "assets.tsv")
    shutil.copyfile(LAYOUT_DIR / "runtime_layout.json", output_dir / "runtime_layout.json")
    (output_dir / "track24_appended_raw.bin").write_bytes(appended)

    patch_rows = [
        {
            "name": patch.name,
            "cpu_address": f"{patch.cpu_address:04X}" if patch.cpu_address is not None else "",
            "iso_offset": f"{patch.iso_offset:06X}",
            "length": str(len(patch.new)),
            "old_hex": patch.old.hex(" ").upper(),
            "new_hex": patch.new.hex(" ").upper(),
        }
        for patch in patches
    ]
    write_tsv(output_dir / "track02_patches.tsv", patch_rows)

    manifest = {
        "version": version,
        "status": "full-generated-translation-track24-runtime",
        "translation_policy": "use current generated Korean draft without manual-review gate",
        "source_track02_sha256": EXPECTED_TRACK02_SHA256,
        "source_track24_sha256": EXPECTED_TRACK24_SHA256,
        "patched_track02_sha256": sha256_file(patched02),
        "patched_track24_sha256": sha256_file(patched24),
        "cue": cue.name,
        "cue_tracks": staged,
        "first_appended_lba": first_appended_lba,
        "track24_index1_lba": track24_index1_lba,
        "bucket_relative_sector": bucket_relative,
        "asset_relative_sector": asset_relative,
        "lookup_sectors": layout.BUCKET_COUNT,
        "asset_sectors": layout_manifest["asset_count"],
        "appended_sectors": len(user_sectors),
        "appended_raw_bytes": len(appended),
        "runtime": {
            "sector_loader": f"{SECTOR_LOADER:04X}",
            "sector_loader_bytes": len(loader_code),
            "renderer_preloader": f"{preloader_address:04X}",
            "renderer_preloader_bytes": len(preloader_code),
            "font_wrapper": f"{FONT_WRAPPER:04X}",
            "font_wrapper_bytes": len(wrapper_code),
            "private_state": f"{PRIVATE_BASE:04X}-7FFF",
            "cache": f"{CACHE_BASE:04X}-{CACHE_BASE + layout.ASSET_READ_BYTES - 1:04X}",
        },
        "layout": layout_manifest,
        "modified_track02_sectors": [f"{sector:06X}" for sector in sorted(modified02)],
    }
    (output_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    (output_dir / "TEST_IN_MESEN.txt").write_text(
        "Load the KO cue, power-cycle, and open the reception dialogue/menu.\n"
        "Expected: generated Korean dialogue, reviewed speaker name, and reviewed UI labels.\n"
        "This is the first full-table runtime build; retain 0.1.14 as the rollback baseline.\n",
        encoding="utf-8-sig",
    )
    return output_dir


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default=VERSION_DEFAULT)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    out = build(args.version, args.force)
    print(out)


if __name__ == "__main__":
    main()
