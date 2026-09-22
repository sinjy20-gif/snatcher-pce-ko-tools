"""Build the first Snatcher Track-24 Korean runtime-loader proof.

The proof keeps the proven renderer/font patch in Track 02, but stores the
replacement Korean string in newly appended MODE1/2352 sectors at the end of
Track 24.  The injected renderer hook calls the System Card ``CD_READ`` BIOS
entry ($E009) and reads that string directly into the game's normal $3619
dialogue buffer.

The historical 0.1.1-0.1.4 builds established the BIOS base-relative read
behavior and the separate CD_BASE address-type/set-mode fields.  Starting with
0.1.5, the hook temporarily selects Track 24 INDEX 01 as base 0, reads the
first appended relative record, and restores Track 02 INDEX 01. Existing Track
24 bytes and every existing disc LBA remain unchanged; only the lead-out moves.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import sys
from pathlib import Path

import build_disc_patch as common


ROOT = Path(r"C:\snatcher")
ROM_DIR = ROOT / "rom(japan)" / "Snatcher CD-ROMantic (Japan)"
SOURCE_CUE = ROM_DIR / "Snatcher CD-ROMantic (Japan).cue"
SOURCE_TRACK02 = ROM_DIR / "Snatcher CD-ROMantic (Japan) (Track 02).bin"
SOURCE_TRACK24 = ROM_DIR / "Snatcher CD-ROMantic (Japan) (Track 24).bin"
TRANSLATION_MASTER = ROOT / "translation" / "snatcher_ko_master.tsv"
BUILD_ROOT = ROOT / "build" / "patch"

sys.path.insert(0, str(ROOT / "extraction" / "translation"))
from tsv_io import read_dict_rows  # noqa: E402

EXPECTED_TRACK02_SHA256 = common.EXPECTED_SOURCE_SHA256
EXPECTED_TRACK24_SHA256 = "467F122A9C91C95D334CA1993E6A1E5316AD57DBEFDFBBA63DF6BED802D80814"

VERSION_DEFAULT = "0.1.1"
TEXT_KEY = "111800:250A"
LINE_NO = 1

RAW_SECTOR_SIZE = common.RAW_SECTOR_SIZE
USER_DATA_SIZE = common.USER_DATA_SIZE
USER_DATA_OFFSET = common.USER_DATA_OFFSET

GLYPH_BASE = common.GLYPH_BASE
FONT_WRAPPER = common.FONT_WRAPPER
FONT_CALL_CPU = common.FONT_CALL_CPU
RENDERER_ENTRY_CPU = common.RENDERER_ENTRY_CPU
ORIGINAL_FONT_CALL = common.ORIGINAL_FONT_CALL
ORIGINAL_RENDERER_ENTRY = common.ORIGINAL_RENDERER_ENTRY

SIGNATURE_ADDRESS = 0x5D80
LOADER_HOOK = 0x5DC0
LOADER_STATUS = 0x5C67
LOADER_STATUS_MAGIC = 0x5C68
BIOS_CD_READ = 0xE009

PRIMARY_CD_BASE = 2
SECONDARY_CD_BASE = 36
SIGNATURE_LENGTH = 16


def sha256(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def load_proof_line() -> tuple[str, str, str]:
    # The canonical translator sheet is UTF-16 for compatibility with the
    # user's older Excel.  Use the shared encoding-aware reader instead of
    # guessing UTF-8/CP949 here.
    _, master_rows = read_dict_rows(TRANSLATION_MASTER)
    rows = [
        row
        for row in master_rows
        if row["text_key"].upper() == TEXT_KEY and int(row["line_no"]) == LINE_NO
    ]
    if len(rows) != 1:
        raise RuntimeError(f"expected exactly one {TEXT_KEY} line {LINE_NO}, got {len(rows)}")
    row = rows[0]
    if not row["jp_text"] or not row["ko_text"]:
        raise RuntimeError(f"{TEXT_KEY} line {LINE_NO} is missing source or Korean text")
    return row["jp_text"], row["ko_text"], row["status"]


def build_loader_hook(
    signature_address: int,
    relative_sector: int,
    byte_length: int,
    remap_first_base: int | None = None,
    restore_first_base: int | None = None,
    base_address_type: int = 0,
) -> bytes:
    """Recreate the renderer prologue and fetch one matching line from Track 24."""

    if not 0 <= relative_sector <= 0xFFFFFF:
        raise ValueError("CD sector must fit in 24 bits")
    if not 1 <= byte_length <= 0xFFFF:
        raise ValueError("CD byte length must fit in 16 bits")

    sector_hi = (relative_sector >> 16) & 0xFF
    sector_md = (relative_sector >> 8) & 0xFF
    sector_lo = relative_sector & 0xFF

    a = common.Assembler(LOADER_HOOK)

    # Recreate the ten bytes replaced at the verified $66E5 renderer entry.
    a.abs(0xAD, 0x3471)  # LDA $3471
    a.emit(0x85, 0x03)  # STA $03
    a.abs(0xAD, 0x3472)  # LDA $3472
    a.emit(0x85, 0x04)  # STA $04

    # Only the first segment of a completed narrative buffer is eligible.
    a.emit(0xC9, 0x36)  # CMP #$36
    a.branch(0xF0, "high_ok")  # BEQ
    a.abs(0x4C, "done")
    a.label("high_ok")
    a.emit(0xA5, 0x03, 0xC9, 0x19)  # LDA $03 / CMP #$19
    a.branch(0xF0, "pointer_ok")  # BEQ
    a.abs(0x4C, "done")
    a.label("pointer_ok")

    # Compare the first 16 source bytes.  This preserves speaker names, menus,
    # and every unrelated dialogue even though they share the same renderer.
    a.emit(0x5A)  # PHY
    a.emit(0xA0, 0x00)  # LDY #0
    a.label("compare")
    a.emit(0xB1, 0x03)  # LDA ($03),Y
    a.abs(0xD9, signature_address)  # CMP signature,Y
    a.branch(0xF0, "byte_ok")  # BEQ
    a.abs(0x4C, "no_match")
    a.label("byte_ok")
    a.emit(0xC8, 0xC0, SIGNATURE_LENGTH)  # INY / CPY #16
    a.branch(0xD0, "compare")

    # CD_READ may alter A/X/Y and uses $F8-$FF as its documented parameter
    # block.  Save all of them before loading a local-address byte transfer.
    a.emit(0xDA)  # PHX
    for zp in range(0xF8, 0x100):
        a.emit(0xA5, zp, 0x48)  # LDA zp / PHA

    a.emit(0xA9, 0x01)
    a.abs(0x8D, LOADER_STATUS)  # status=attempted

    def emit_set_first_base(base_sector: int) -> None:
        # CD_BASE parameters: AL/AH/BL = sector hi/md/lo, BH = address
        # type, CL = set mode.  The BIOS manual documents these as distinct
        # fields.  0.1.4 incorrectly copied CL=1 into BH too, which Mesen
        # interpreted as track-number addressing: AL=03 selected Track 03.
        # BH=0 selects a binary record number; CL=1 changes only base 0.
        values = (
            (0xF8, (base_sector >> 16) & 0xFF),
            (0xF9, (base_sector >> 8) & 0xFF),
            (0xFA, base_sector & 0xFF),
            (0xFB, base_address_type),
            (0xFC, 0x01),
        )
        for zp, value in values:
            a.emit(0xA9, value, 0x85, zp)
        a.abs(0x20, 0xE006)

    if remap_first_base is not None:
        if restore_first_base is None:
            raise ValueError("a temporary CD base requires a restore value")
        emit_set_first_base(remap_first_base)

    # AX = byte length, BX = destination, CL/CH/DL = 24-bit sector,
    # DH = address type 0 (local address, byte count).
    parameters = (
        (0xF8, byte_length & 0xFF),
        (0xF9, (byte_length >> 8) & 0xFF),
        (0xFA, 0x19),
        (0xFB, 0x36),
        (0xFC, sector_hi),
        (0xFD, sector_md),
        (0xFE, sector_lo),
        (0xFF, 0x00),
    )
    for zp, value in parameters:
        a.emit(0xA9, value, 0x85, zp)  # LDA #value / STA zp

    a.abs(0x20, BIOS_CD_READ)
    a.abs(0x8D, LOADER_STATUS)  # BIOS result: 0 = success

    if restore_first_base is not None:
        emit_set_first_base(restore_first_base)

    # Restore the exact renderer/game scratch state in reverse stack order.
    for zp in reversed(range(0xF8, 0x100)):
        a.emit(0x68, 0x85, zp)  # PLA / STA zp
    a.emit(0xFA)  # PLX
    a.emit(0x7A)  # PLY

    # BIOS internals are free to use normal zero page.  Re-establish the
    # renderer's pointer pair before returning to the original instruction.
    a.abs(0xAD, 0x3471)
    a.emit(0x85, 0x03)
    a.abs(0xAD, 0x3472)
    a.emit(0x85, 0x04)
    a.emit(0x60)  # RTS

    a.label("no_match")
    a.emit(0x7A)  # PLY
    a.label("done")
    a.emit(0x60)  # RTS
    return a.finish()


def bcd(value: int) -> int:
    if not 0 <= value <= 99:
        raise ValueError(value)
    return ((value // 10) << 4) | (value % 10)


def lba_header(lba: int) -> bytes:
    physical = lba + 150
    minute, remainder = divmod(physical, 75 * 60)
    second, frame = divmod(remainder, 75)
    return bytes((bcd(minute), bcd(second), bcd(frame), 0x01))


def make_mode1_sector(lba: int, user_data: bytes) -> bytes:
    if len(user_data) > USER_DATA_SIZE:
        raise ValueError("MODE1 user payload exceeds 2048 bytes")
    sector = bytearray(RAW_SECTOR_SIZE)
    sector[:12] = b"\x00" + b"\xFF" * 10 + b"\x00"
    sector[12:16] = lba_header(lba)
    sector[USER_DATA_OFFSET:USER_DATA_OFFSET + len(user_data)] = user_data
    common.rebuild_mode1_sector(sector)
    return bytes(sector)


def track_files_from_cue() -> list[str]:
    pattern = re.compile(r'^FILE "([^"]+)" BINARY$')
    result = []
    for line in SOURCE_CUE.read_text(encoding="ascii").splitlines():
        match = pattern.match(line)
        if match:
            result.append(match.group(1))
    if len(result) != 24:
        raise RuntimeError(f"expected 24 CUE files, got {len(result)}")
    return result


def disc_track_starts() -> tuple[dict[int, int], int]:
    starts: dict[int, int] = {}
    cursor = 0
    for number, filename in enumerate(track_files_from_cue(), start=1):
        path = ROM_DIR / filename
        size = path.stat().st_size
        if size % RAW_SECTOR_SIZE:
            raise RuntimeError(f"track {number:02d} is not raw-sector aligned: {path}")
        starts[number] = cursor
        cursor += size // RAW_SECTOR_SIZE
    return starts, cursor


def extract_track02_user(source_raw: bytes) -> bytearray:
    user_data = bytearray()
    for sector_index in range(len(source_raw) // RAW_SECTOR_SIZE):
        start = sector_index * RAW_SECTOR_SIZE + USER_DATA_OFFSET
        user_data.extend(source_raw[start:start + USER_DATA_SIZE])
    return user_data


def apply_track02_patches(source_raw: bytes, patches: list[common.Patch]) -> tuple[bytes, set[int]]:
    user_data = extract_track02_user(source_raw)
    patched_user = bytearray(user_data)
    for patch in patches:
        actual = bytes(patched_user[patch.iso_offset:patch.iso_offset + len(patch.old)])
        if actual != patch.old:
            raise RuntimeError(
                f"{patch.name} signature mismatch at ISO ${patch.iso_offset:06X}: "
                f"expected {patch.old.hex(' ')}, got {actual.hex(' ')}"
            )
        patched_user[patch.iso_offset:patch.iso_offset + len(patch.new)] = patch.new

    modified: set[int] = set()
    for patch in patches:
        first = patch.iso_offset // USER_DATA_SIZE
        last = (patch.iso_offset + len(patch.new) - 1) // USER_DATA_SIZE
        modified.update(range(first, last + 1))

    patched_raw = bytearray(source_raw)
    for sector_index in sorted(modified):
        raw_start = sector_index * RAW_SECTOR_SIZE
        sector = bytearray(patched_raw[raw_start:raw_start + RAW_SECTOR_SIZE])
        user_start = sector_index * USER_DATA_SIZE
        sector[USER_DATA_OFFSET:USER_DATA_OFFSET + USER_DATA_SIZE] = patched_user[
            user_start:user_start + USER_DATA_SIZE
        ]
        common.rebuild_mode1_sector(sector)
        patched_raw[raw_start:raw_start + RAW_SECTOR_SIZE] = sector

    changed = {
        index
        for index in range(len(source_raw) // RAW_SECTOR_SIZE)
        if source_raw[index * RAW_SECTOR_SIZE:(index + 1) * RAW_SECTOR_SIZE]
        != patched_raw[index * RAW_SECTOR_SIZE:(index + 1) * RAW_SECTOR_SIZE]
    }
    if changed != modified:
        raise RuntimeError(f"unexpected Track 02 changed sectors: {sorted(changed ^ modified)}")
    return bytes(patched_raw), modified


def verify_mode1_sector(sector: bytes, lba: int) -> None:
    if len(sector) != RAW_SECTOR_SIZE:
        raise RuntimeError("bad appended sector length")
    if sector[:12] != b"\x00" + b"\xFF" * 10 + b"\x00":
        raise RuntimeError(f"bad sync at appended LBA {lba}")
    if sector[12:16] != lba_header(lba):
        raise RuntimeError(f"bad header at appended LBA {lba}")
    rebuilt = bytearray(sector)
    common.rebuild_mode1_sector(rebuilt)
    if rebuilt != sector:
        raise RuntimeError(f"EDC/ECC verification failed at appended LBA {lba}")


def stage_cue(
    output_path: Path,
    patched_track02: Path,
    patched_track24: Path,
) -> list[dict[str, str | int]]:
    pattern = re.compile(r'^FILE "([^"]+)" BINARY$')
    rendered: list[str] = []
    staged: list[dict[str, str | int]] = []
    for line in SOURCE_CUE.read_text(encoding="ascii").splitlines():
        match = pattern.match(line)
        if not match:
            rendered.append(line)
            continue
        filename = match.group(1)
        source = ROM_DIR / filename
        if "Track 02" in filename:
            target = patched_track02
            method = "patched"
        elif "Track 24" in filename:
            target = patched_track24
            method = "extended"
        else:
            target = output_path.parent / filename
            try:
                os.link(source, target)
                method = "hardlink"
            except OSError:
                shutil.copy2(source, target)
                method = "copy"
        if not target.is_file():
            raise RuntimeError(f"failed to stage CUE track: {filename}")
        if method in {"hardlink", "copy"} and target.stat().st_size != source.stat().st_size:
            raise RuntimeError(f"staged track size mismatch: {filename}")
        rendered.append(f'FILE "{target.name}" BINARY')
        staged.append({"file": target.name, "bytes": target.stat().st_size, "method": method})
    output_path.write_text("\n".join(rendered) + "\n", encoding="ascii")
    return staged


def build(version: str, force: bool) -> Path:
    output_dir = BUILD_ROOT / version
    if output_dir.exists():
        if not force:
            raise SystemExit(f"build already exists: {output_dir} (use --force to rebuild)")
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)

    source02 = SOURCE_TRACK02.read_bytes()
    source24 = SOURCE_TRACK24.read_bytes()
    if sha256(source02) != EXPECTED_TRACK02_SHA256:
        raise RuntimeError("unexpected Track 02 SHA-256")
    if sha256(source24) != EXPECTED_TRACK24_SHA256:
        raise RuntimeError("unexpected Track 24 SHA-256")
    if len(source02) % RAW_SECTOR_SIZE or len(source24) % RAW_SECTOR_SIZE:
        raise RuntimeError("source data tracks are not MODE1/2352 aligned")

    jp_text, ko_text, translation_status = load_proof_line()
    hangul = common.ordered_hangul(ko_text)
    glyph_pack, mapping = common.build_glyph_pack(hangul)
    encoded = common.build_korean_game_string(ko_text, hangul)
    signature = jp_text.encode("cp932")[:SIGNATURE_LENGTH]
    if len(signature) != SIGNATURE_LENGTH:
        raise RuntimeError("proof source is too short for a 16-byte signature")

    starts, original_disc_sectors = disc_track_starts()
    track24_start = starts[24]
    track24_sectors = len(source24) // RAW_SECTOR_SIZE
    first_appended_lba = track24_start + track24_sectors
    if first_appended_lba != original_disc_sectors:
        raise RuntimeError("Track 24 is not the final source track")

    track02_index1_lba = starts[2] + 225
    track24_index1_lba = starts[24] + 225

    # Preserve exact 0.1.1 reproducibility, including its now-proven bad
    # base-relative sector.  0.1.2 used the corrected absolute LBA but reduced
    # the extension to one sector and failed during boot.  Starting at 0.1.3,
    # retain 0.1.1's known-bootable 35-sector lead-out geometry and change only
    # the CD_READ argument to the corrected absolute LBA.
    legacy_relative = version == "0.1.1"
    if legacy_relative:
        cd_read_sector = first_appended_lba - PRIMARY_CD_BASE
        secondary_absolute_lba = cd_read_sector + SECONDARY_CD_BASE
        append_sector_count = secondary_absolute_lba - first_appended_lba + 1
        payload_lbas = {first_appended_lba, secondary_absolute_lba}
        sector_mode = "legacy-base-relative-failed"
    elif version == "0.1.2":
        cd_read_sector = first_appended_lba
        append_sector_count = 1
        payload_lbas = {first_appended_lba}
        sector_mode = "absolute-lba-single-sector-boot-failed"
    elif version == "0.1.3":
        cd_read_sector = first_appended_lba
        append_sector_count = SECONDARY_CD_BASE - PRIMARY_CD_BASE + 1
        secondary_absolute_lba = first_appended_lba + append_sector_count - 1
        payload_lbas = {first_appended_lba, secondary_absolute_lba}
        sector_mode = "absolute-lba-known-bootable-geometry"
        remap_first_base = None
        restore_first_base = None
    else:
        # Live 0.1.3 diagnosis proved that Snatcher's two current bases are
        # Track 02 INDEX 01 ($00104E) and Track 24 INDEX 01 ($03968D).
        # CD_READ offsets through the first valid copy, so temporarily point
        # the first base at Track 24, read the appended relative sector, then
        # restore the original Track 02 base.
        cd_read_sector = first_appended_lba - track24_index1_lba
        append_sector_count = SECONDARY_CD_BASE - PRIMARY_CD_BASE + 1
        secondary_absolute_lba = first_appended_lba + append_sector_count - 1
        payload_lbas = {first_appended_lba, secondary_absolute_lba}
        sector_mode = "temporary-first-base-track24"
        remap_first_base = track24_index1_lba
        restore_first_base = track02_index1_lba

    # Preserve the exact failed 0.1.4 experiment.  Starting with 0.1.5,
    # CD_BASE uses BH=0 (record address) and CL=1 (set first base).
    base_address_type = 0x01 if version == "0.1.4" else 0x00

    if version in {"0.1.1", "0.1.2", "0.1.3"}:
        remap_first_base = None
        restore_first_base = None

    payload = bytearray(USER_DATA_SIZE)
    payload[:len(encoded)] = encoded
    marker = {
        "magic": "SKO1",
        "version": version,
        "text_key": TEXT_KEY,
        "line_no": LINE_NO,
        "sector_mode": sector_mode,
        "cd_read_sector": cd_read_sector,
        "first_appended_lba": first_appended_lba,
        "track02_index1_lba": track02_index1_lba,
        "track24_index1_lba": track24_index1_lba,
        "temporary_first_base": remap_first_base,
        "restored_first_base": restore_first_base,
        "payload_absolute_lbas": sorted(payload_lbas),
        "encoded_length": len(encoded),
        "encoded_sha256": sha256(encoded),
    }
    marker_bytes = json.dumps(marker, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    marker_offset = 0x100
    if marker_offset + len(marker_bytes) > USER_DATA_SIZE:
        raise RuntimeError("payload marker does not fit")
    payload[marker_offset:marker_offset + len(marker_bytes)] = marker_bytes

    appended = bytearray()
    for index in range(append_sector_count):
        lba = first_appended_lba + index
        sector_user = bytes(payload) if lba in payload_lbas else bytes(USER_DATA_SIZE)
        appended.extend(make_mode1_sector(lba, sector_user))
    patched24 = source24 + appended

    font_wrapper = common.build_font_wrapper(len(hangul))
    loader_hook = build_loader_hook(
        SIGNATURE_ADDRESS,
        cd_read_sector,
        len(encoded),
        remap_first_base,
        restore_first_base,
        base_address_type,
    )
    if GLYPH_BASE + len(glyph_pack) > SIGNATURE_ADDRESS:
        raise RuntimeError("glyph pack overlaps source signature")
    if SIGNATURE_ADDRESS + len(signature) > LOADER_HOOK:
        raise RuntimeError("source signature overlaps loader hook")
    if LOADER_HOOK + len(loader_hook) > FONT_WRAPPER:
        raise RuntimeError(
            f"loader hook ends at ${LOADER_HOOK + len(loader_hook):04X}, "
            f"overlapping font wrapper at ${FONT_WRAPPER:04X}"
        )
    if FONT_WRAPPER + len(font_wrapper) > common.CAVE_CPU_END:
        raise RuntimeError("font wrapper exceeds Track 02 cave")

    status_blob = bytes((0xFF, 0x53, 0x4B, 0x4F, 0x31))
    track02_blobs = [
        ("loader_status", LOADER_STATUS, status_blob),
        ("hangul_glyphs", GLYPH_BASE, glyph_pack),
        ("source_signature", SIGNATURE_ADDRESS, signature),
        ("track24_loader_hook", LOADER_HOOK, loader_hook),
        ("font_wrapper", FONT_WRAPPER, font_wrapper),
    ]
    patches = [
        common.Patch(
            "font_call",
            common.bank6a_iso(FONT_CALL_CPU),
            ORIGINAL_FONT_CALL,
            bytes((0x20, FONT_WRAPPER & 0xFF, FONT_WRAPPER >> 8)),
            FONT_CALL_CPU,
        ),
        common.Patch(
            "renderer_entry",
            common.bank6a_iso(RENDERER_ENTRY_CPU),
            ORIGINAL_RENDERER_ENTRY,
            bytes((0x20, LOADER_HOOK & 0xFF, LOADER_HOOK >> 8)) + bytes([0xEA]) * 7,
            RENDERER_ENTRY_CPU,
        ),
    ]
    for name, address, data in track02_blobs:
        patches.append(
            common.Patch(
                name,
                common.bank68_iso(address),
                bytes([0xFF]) * len(data),
                data,
                address,
            )
        )
    patched02, modified02 = apply_track02_patches(source02, patches)

    # Static round-trip and integrity verification.
    if patched24[:len(source24)] != source24:
        raise RuntimeError("existing Track 24 prefix changed")
    if len(patched24) != len(source24) + append_sector_count * RAW_SECTOR_SIZE:
        raise RuntimeError("extended Track 24 has the wrong length")
    for index in range(append_sector_count):
        lba = first_appended_lba + index
        start = len(source24) + index * RAW_SECTOR_SIZE
        sector = patched24[start:start + RAW_SECTOR_SIZE]
        verify_mode1_sector(sector, lba)
        user = sector[USER_DATA_OFFSET:USER_DATA_OFFSET + USER_DATA_SIZE]
        if lba in payload_lbas:
            if user != payload:
                raise RuntimeError(f"payload mismatch at LBA {lba}")
        elif user != bytes(USER_DATA_SIZE):
            raise RuntimeError(f"filler user data is not zero at LBA {lba}")

    patched02_path = output_dir / f"Snatcher CD-ROMantic (Japan) (Track 02) [KO {version}].bin"
    patched24_path = output_dir / f"Snatcher CD-ROMantic (Japan) (Track 24) [KO {version}].bin"
    patched02_path.write_bytes(patched02)
    patched24_path.write_bytes(patched24)
    cue_path = output_dir / f"Snatcher CD-ROMantic (Japan) [KO {version}].cue"
    staged = stage_cue(cue_path, patched02_path, patched24_path)
    common.write_mapping(output_dir / "hangul_code_map.tsv", mapping)
    (output_dir / "track24_payload_user.bin").write_bytes(payload)
    (output_dir / "track24_appended_raw.bin").write_bytes(appended)

    patch_rows = []
    for patch in patches:
        patch_rows.append(
            {
                "name": patch.name,
                "cpu_address": f"{patch.cpu_address:04X}" if patch.cpu_address is not None else "",
                "iso_offset": f"{patch.iso_offset:06X}",
                "raw_offset": f"{common.raw_user_offset(patch.iso_offset):08X}",
                "length": len(patch.new),
                "old_hex": patch.old.hex(" ").upper(),
                "new_hex": patch.new.hex(" ").upper(),
            }
        )
    with (output_dir / "track02_patches.tsv").open(
        "w", encoding="utf-8-sig", newline=""
    ) as handle:
        writer = csv.DictWriter(
            handle, fieldnames=list(patch_rows[0]), delimiter="\t", lineterminator="\n"
        )
        writer.writeheader()
        writer.writerows(patch_rows)

    manifest = {
        "version": version,
        "status": "track24-runtime-loader-proof",
        "translation_master": str(TRANSLATION_MASTER),
        "translation_master_sha256": sha256(TRANSLATION_MASTER.read_bytes()),
        "proof": {
            "text_key": TEXT_KEY,
            "line_no": LINE_NO,
            "jp_text": jp_text,
            "ko_text": ko_text,
            "translation_status": translation_status,
            "source_signature_hex": signature.hex(" ").upper(),
            "encoded_hex": encoded.hex(" ").upper(),
            "encoded_length": len(encoded),
        },
        "track02": {
            "source": str(SOURCE_TRACK02),
            "source_sha256": sha256(source02),
            "patched": patched02_path.name,
            "patched_sha256": sha256(patched02),
            "modified_sectors": [f"{sector:06X}" for sector in sorted(modified02)],
            "loader_hook_cpu": f"{LOADER_HOOK:04X}",
            "loader_hook_bytes": len(loader_hook),
            "loader_status_cpu": f"{LOADER_STATUS:04X}",
            "bios_cd_read": f"{BIOS_CD_READ:04X}",
            "patches": patch_rows,
        },
        "track24": {
            "source": str(SOURCE_TRACK24),
            "source_sha256": sha256(source24),
            "source_bytes": len(source24),
            "source_sectors": track24_sectors,
            "disc_start_lba": track24_start,
            "patched": patched24_path.name,
            "patched_sha256": sha256(patched24),
            "patched_bytes": len(patched24),
            "appended_sectors": append_sector_count,
            "sector_mode": sector_mode,
            "cd_read_sector": cd_read_sector,
            "track02_index1_lba": track02_index1_lba,
            "track24_index1_lba": track24_index1_lba,
            "temporary_first_base": remap_first_base,
            "restored_first_base": restore_first_base,
            "failed_0_1_1_sector": first_appended_lba - PRIMARY_CD_BASE,
            "failed_0_1_1_sector_user_data": "all zero",
            "payload_absolute_lbas": sorted(payload_lbas),
            "first_appended_header_hex": lba_header(first_appended_lba).hex(" ").upper(),
            "last_appended_header_hex": lba_header(
                first_appended_lba + append_sector_count - 1
            ).hex(" ").upper(),
            "existing_prefix_identical": True,
            "all_appended_edc_ecc_verified": True,
        },
        "cue": cue_path.name,
        "cue_tracks": staged,
        "hangul_codes": {row["character"]: row["game_code"] for row in mapping},
    }
    (output_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    verification = [
        f"Snatcher Korean patch {version} — Track 24 runtime-loader proof",
        "",
        f"Track 02 source SHA-256:  {sha256(source02)}",
        f"Track 02 patched SHA-256: {sha256(patched02)}",
        f"Track 24 source SHA-256:  {sha256(source24)}",
        f"Track 24 patched SHA-256: {sha256(patched24)}",
        f"Track 24 source bytes:    {len(source24)}",
        f"Track 24 patched bytes:   {len(patched24)}",
        f"Track 24 appended sectors:{append_sector_count}",
        f"CD_READ sector mode:      {sector_mode}",
        f"CD_READ sector:           {cd_read_sector} (${cd_read_sector:06X})",
        f"payload absolute LBAs:    {', '.join(str(value) for value in sorted(payload_lbas))}",
        f"Korean payload bytes:     {len(encoded)}",
        f"loader hook bytes:        {len(loader_hook)}",
        "",
        "Static verification passed:",
        "- original Track 02 and Track 24 SHA-256 matched",
        "- original Track 24 prefix is byte-for-byte unchanged",
        f"- all {append_sector_count} appended raw sectors have valid LBA headers",
        "- EDC and P/Q ECC round-trip for every appended sector",
        (
            "- the loader temporarily selects Track 24 INDEX 01 as the first CD base, "
            "reads the appended relative sector, then restores Track 02 INDEX 01"
            if version not in {"0.1.1", "0.1.2", "0.1.3"}
            else "- this historical proof build retains its original CD_READ addressing experiment"
        ),
        "- Track 02 patch-site signatures and cave occupancy matched",
        "- only expected Track 02 sectors changed",
        "- all 24 tracks are staged beside the test CUE",
        "",
        "Runtime success criterion:",
        f"- {jp_text}",
        f"  must display as {ko_text}",
        "- no Lua script may be running",
        "- speaker name, next line, menu, and dialogue progression must remain normal",
    ]
    (output_dir / "verification.txt").write_text(
        "\n".join(verification) + "\n", encoding="utf-8"
    )

    test_notes = [
        f"Snatcher Korean patch {version} — Mesen runtime test",
        "",
        "Open this CUE:",
        str(cue_path),
        "",
        "1. Stop every Lua script.",
        "2. Open the CUE above and power-cycle; do not reuse an old save state.",
        "3. Reach the reception dialogue whose first line is:",
        f"   {jp_text}",
        "4. Expected first line:",
        f"   {ko_text}",
        "",
        "This build differs from 0.0.8:",
        "- the Korean sentence is not stored in the Track 02 code cave",
        "- the hook calls BIOS CD_READ ($E009)",
        "- the bytes shown on screen are loaded from appended Track 24 sectors",
        (
            "- this build temporarily maps the first CD base to Track 24 for the read, "
            "then restores the original Track 02 base"
            if version not in {"0.1.1", "0.1.2", "0.1.3"}
            else "- this historical proof build retains its original CD_READ addressing experiment"
        ),
        "",
        "Pass if the Korean first line appears and the game continues normally.",
        "If Japanese remains, the Track 24 read did not take effect.",
        "If the game freezes, keep this folder unchanged and report the screen/timing.",
    ]
    (output_dir / "TEST_IN_MESEN.txt").write_text(
        "\n".join(test_notes) + "\n", encoding="utf-8"
    )
    return output_dir


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default=VERSION_DEFAULT)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    output = build(args.version, args.force)
    print(f"build complete: {output}")


if __name__ == "__main__":
    main()
