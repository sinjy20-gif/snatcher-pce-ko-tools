#!/usr/bin/env python3
"""Build ac_0.1.6: safe 704-byte CD read-through cache in Arcade Card RAM.

No BIOS transfer runs with a game RAM MPR remapped.  On a cache miss this
reuses the proven 0.3.0-uitest 704-byte CD read into $5B80, then copies that
unchanged record to AC RAM.  Later requests for the same SRT4 slot are served
from AC.  The fixed-size cache is flushed after 2,885 unique slots.
"""

from __future__ import annotations

import hashlib
import json
import re
import shutil
import sys
from pathlib import Path


ROOT = Path(r"C:\snatcher")
STATIC = ROOT / "extraction" / "patch" / "static"
sys.path.insert(0, str(STATIC))

import build_disc_patch as common  # noqa: E402
import build_speaker_ui_proof as proof  # noqa: E402


VERSION = "ac_0.1.6"
BASE = ROOT / "build" / "patch" / "0.3.0-uitest"
OUT = ROOT / "build" / "patch" / VERSION

SECTOR_LOADER = 0x7F88
LOADER_BYTES = 100
HELPER = 0x9CD2
HELPER_LIMIT = 0xA000
BANK69_ISO_BASE = 0x07D800

CACHE_BASE = 0x5B80
RECORD_BYTES = 704
DIRECT_RELATIVE = 33973
TRACK24_INDEX1_LBA = 235149
TRACK02_INDEX1_LBA = 0x00104E
BIOS_CD_BASE = 0xE006
BIOS_CD_READ = 0xE009

MAP_BYTES = 0x10000
RECORD_BASE = 0x10000
STATE_BASE = 0x1FFFF0
RESET_AT = 0x1FFDC0
MAGIC = (0xAC, 0x16, 0xC6)
CACHE_CAPACITY = (STATE_BASE - RECORD_BASE) // RECORD_BYTES


def bank69_iso(cpu: int) -> int:
    return BANK69_ISO_BASE + cpu - 0x8000


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def emit_cd_base(a: common.Assembler, lba: int) -> None:
    for zp, value in ((0xF8, lba >> 16), (0xF9, lba >> 8), (0xFA, lba), (0xFB, 0), (0xFC, 1)):
        a.emit(0xA9, value, 0x85, zp)
    a.abs(0x20, BIOS_CD_BASE)


def emit_set_ac_vars(a: common.Assembler, lo: int, mid: int, hi: int, increment: int = 1) -> None:
    for variable, port in ((lo, 0x1A02), (mid, 0x1A03), (hi, 0x1A04)):
        a.abs(0xAD, variable); a.abs(0x8D, port)
    a.emit(0xA9, increment); a.abs(0x8D, 0x1A07)
    a.abs(0x9C, 0x1A08)
    a.emit(0xA9, 0x11); a.abs(0x8D, 0x1A09)


def build_helper() -> tuple[bytes, int]:
    scratch = 0x9FF0
    SLOT_LO, SLOT_HI, MAP_LO, MAP_MID, REC_LO, REC_MID, REC_HI, STATUS = range(scratch, scratch + 8)

    a = common.Assembler(HELPER)
    # Three-byte generation marker makes stale/random AC contents invalid.
    a.emit(0xA9, 0); a.abs(0x20, "set_state")
    for expected in MAGIC:
        a.abs(0xAD, 0x1A00); a.emit(0xC9, expected); a.branch(0xD0, "initialize")
    a.abs(0x4C, "lookup")

    a.label("initialize")
    a.abs(0x20, "reset_cache")

    a.label("lookup")
    # Convert the requested direct-relative sector back to its SRT4 slot.
    a.emit(0x38); a.abs(0xAD, 0x7FEF); a.emit(0xE9, DIRECT_RELATIVE & 0xFF); a.abs(0x8D, SLOT_LO)
    a.abs(0xAD, 0x7FF0); a.emit(0xE9, DIRECT_RELATIVE >> 8); a.abs(0x8D, SLOT_HI)
    a.abs(0xAD, SLOT_LO); a.emit(0x0A); a.abs(0x8D, MAP_LO)
    a.abs(0xAD, SLOT_HI); a.emit(0x2A); a.abs(0x8D, MAP_MID)
    a.abs(0x0E, MAP_LO); a.abs(0x2E, MAP_MID)
    a.abs(0x9C, REC_HI)
    emit_set_ac_vars(a, MAP_LO, MAP_MID, REC_HI)
    for variable in (REC_LO, REC_MID, REC_HI):
        a.abs(0xAD, 0x1A00); a.abs(0x8D, variable)
    a.abs(0xAD, 0x1A00); a.emit(0xC9, 0xA5); a.branch(0xD0, "cache_miss")
    a.abs(0x4C, "cache_hit")

    # Safe miss path: identical 704-byte BIOS read into the normal $5B80 RAM.
    a.label("cache_miss")
    emit_cd_base(a, TRACK24_INDEX1_LBA)
    for zp, value in ((0xF8, RECORD_BYTES), (0xF9, RECORD_BYTES >> 8),
                      (0xFA, CACHE_BASE), (0xFB, CACHE_BASE >> 8), (0xFC, 0)):
        a.emit(0xA9, value, 0x85, zp)
    a.abs(0xAD, 0x7FF0); a.emit(0x85, 0xFD)
    a.abs(0xAD, 0x7FEF); a.emit(0x85, 0xFE)
    a.emit(0xA9, 0, 0x85, 0xFF)
    a.abs(0x20, BIOS_CD_READ); a.abs(0x8D, STATUS)
    emit_cd_base(a, TRACK02_INDEX1_LBA)
    a.abs(0xAD, STATUS); a.emit(0xC9, 0); a.branch(0xF0, "store_miss")
    a.abs(0x4C, "return_status")

    a.label("store_miss")
    # Read the next dense-record address from AC state.
    a.emit(0xA9, 3); a.abs(0x20, "set_state")
    for variable in (REC_LO, REC_MID, REC_HI):
        a.abs(0xAD, 0x1A00); a.abs(0x8D, variable)
    # Flush before the next 704-byte record would overlap reserved state.
    a.abs(0xAD, REC_HI); a.emit(0xC9, RESET_AT >> 16); a.branch(0xD0, "have_space")
    a.abs(0xAD, REC_MID); a.emit(0xC9, (RESET_AT >> 8) & 0xFF); a.branch(0x90, "have_space")
    a.abs(0x20, "reset_cache")
    a.emit(0xA9, RECORD_BASE); a.abs(0x8D, REC_LO)
    a.emit(0xA9, RECORD_BASE >> 8); a.abs(0x8D, REC_MID)
    a.emit(0xA9, RECORD_BASE >> 16); a.abs(0x8D, REC_HI)

    a.label("have_space")
    # CPU copy only: normal game RAM remains mapped throughout.
    emit_set_ac_vars(a, REC_LO, REC_MID, REC_HI)
    a.emit(0xE3); a.word(CACHE_BASE); a.word(0x1A00); a.word(RECORD_BYTES)  # TIA

    # Persist next_record = record + 704.
    a.emit(0x18); a.abs(0xAD, REC_LO); a.emit(0x69, RECORD_BYTES & 0xFF, 0x48)
    a.abs(0xAD, REC_MID); a.emit(0x69, RECORD_BYTES >> 8, 0xAA)
    a.abs(0xAD, REC_HI); a.emit(0x69, 0, 0xA8)
    a.emit(0xA9, 3); a.abs(0x20, "set_state")
    a.emit(0x68); a.abs(0x8D, 0x1A00)
    a.emit(0x8A); a.abs(0x8D, 0x1A00)
    a.emit(0x98); a.abs(0x8D, 0x1A00)

    # Publish slot -> dense AC record only after the copy is complete.
    emit_set_ac_vars(a, MAP_LO, MAP_MID, STATUS)  # STATUS is zero after success
    for variable in (REC_LO, REC_MID, REC_HI):
        a.abs(0xAD, variable); a.abs(0x8D, 0x1A00)
    a.emit(0xA9, 0xA5); a.abs(0x8D, 0x1A00)
    a.emit(0xA9, 0); a.abs(0x4C, "return_status")

    a.label("cache_hit")
    emit_set_ac_vars(a, REC_LO, REC_MID, REC_HI)
    a.emit(0xF3); a.word(0x1A00); a.word(CACHE_BASE); a.word(RECORD_BYTES)
    a.emit(0xA9, 0)

    a.label("return_status")
    # Preserve the original loader's source-pointer restoration contract.
    a.emit(0x48)
    a.abs(0xAD, 0x3471); a.emit(0x85, 0x03)
    a.abs(0xAD, 0x3472); a.emit(0x85, 0x04)
    a.emit(0x68, 0x60)

    a.label("reset_cache")
    # Invalidate only byte 3 of every four-byte map entry: 16,384 writes.
    a.emit(0xA9, 3); a.abs(0x8D, 0x1A02)
    a.abs(0x9C, 0x1A03); a.abs(0x9C, 0x1A04)
    a.emit(0xA9, 4); a.abs(0x8D, 0x1A07)
    a.abs(0x9C, 0x1A08)
    a.emit(0xA9, 0x11); a.abs(0x8D, 0x1A09)
    a.emit(0xA0, 0x40, 0xA2, 0, 0xA9, 0)
    a.label("clear_marker")
    a.abs(0x8D, 0x1A00); a.emit(0xCA); a.branch(0xD0, "clear_marker")
    a.emit(0x88); a.branch(0xD0, "clear_marker")
    # State = magic + next record address.
    a.emit(0xA9, 0); a.abs(0x20, "set_state")
    for value in (*MAGIC, RECORD_BASE, RECORD_BASE >> 8, RECORD_BASE >> 16):
        a.emit(0xA9, value); a.abs(0x8D, 0x1A00)
    a.emit(0x60)

    # A = low-byte offset in the reserved AC state page $1FFFF0.
    a.label("set_state")
    a.emit(0x18, 0x69, STATE_BASE & 0xFF); a.abs(0x8D, 0x1A02)
    a.emit(0xA9, (STATE_BASE >> 8) & 0xFF); a.abs(0x8D, 0x1A03)
    a.emit(0xA9, STATE_BASE >> 16); a.abs(0x8D, 0x1A04)
    a.emit(0xA9, 1); a.abs(0x8D, 0x1A07)
    a.abs(0x9C, 0x1A08)
    a.emit(0xA9, 0x11); a.abs(0x8D, 0x1A09)
    a.emit(0x60)

    code = a.finish()
    image = code + bytes((0xFF,)) * (scratch - (HELPER + len(code))) + bytes(8)
    if HELPER + len(image) > HELPER_LIMIT:
        raise RuntimeError(f"read-through helper exceeds Bank69 cave: {len(image)} bytes")
    return image, len(code)


def build_trampoline() -> bytes:
    a = common.Assembler(SECTOR_LOADER)
    a.emit(0x43, 0x10, 0x48, 0xA9, 0x69, 0x53, 0x10)
    a.abs(0x20, HELPER)
    a.abs(0x8D, 0x7FEE)
    a.emit(0x68, 0x53, 0x10)
    a.abs(0xAD, 0x7FEE); a.emit(0x60)
    code = a.finish()
    return code + bytes((0xEA,)) * (LOADER_BYTES - len(code))


def stage_cue(track02: Path) -> Path:
    source_cue = next(BASE.glob("*.cue")); pattern = re.compile(r'^FILE "([^"]+)" BINARY$'); lines = []
    for line in source_cue.read_text(encoding="ascii").splitlines():
        match = pattern.match(line)
        if not match:
            lines.append(line); continue
        source = BASE / match.group(1)
        target = track02 if "Track 02" in source.name else OUT / source.name.replace("0.3.0-uitest", VERSION)
        if target != track02 and not target.exists():
            try: target.hardlink_to(source)
            except OSError: shutil.copy2(source, target)
        lines.append(f'FILE "{target.name}" BINARY')
    cue = OUT / f"Snatcher CD-ROMantic (Japan) [KO {VERSION}].cue"
    cue.write_text("\n".join(lines) + "\n", encoding="ascii")
    return cue


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    helper, helper_code_bytes = build_helper(); trampoline = build_trampoline()
    source02 = next(BASE.glob("*Track 02*uitest*.bin"))
    old_loader = proof.read_user_bytes(source02, common.bank6a_iso(SECTOR_LOADER), LOADER_BYTES)
    old_helper = proof.read_user_bytes(source02, bank69_iso(HELPER), len(helper))
    if any(byte != 0xFF for byte in old_helper): raise RuntimeError("Bank69 helper cave is not empty")
    target02 = OUT / f"Snatcher CD-ROMantic (Japan) (Track 02) [KO {VERSION}].bin"
    proof.apply_patches_streaming(source02, target02, [
        common.Patch("ac_readthrough_loader", common.bank6a_iso(SECTOR_LOADER), old_loader, trampoline, SECTOR_LOADER),
        common.Patch("ac_readthrough_helper", bank69_iso(HELPER), old_helper, helper, HELPER),
    ])
    cue = stage_cue(target02)
    for name in ("direct_records.tsv", "assets.tsv", "runtime_layout.json"):
        shutil.copy2(BASE / name, OUT / name)
    manifest = {
        "version": VERSION,
        "base_build": str(BASE),
        "change": "safe 704-byte CD read-through cache; no BIOS transfer through remapped MPR",
        "lua_required": False,
        "cache_capacity_records": CACHE_CAPACITY,
        "map_bytes": MAP_BYTES,
        "record_base": f"{RECORD_BASE:05X}",
        "state_base": f"{STATE_BASE:05X}",
        "helper_code_bytes": helper_code_bytes,
        "helper_image_bytes": len(helper),
        "patched_track02_sha256": sha256_file(target02),
        "cue": cue.name,
        "preserved": ["$5E40 preloader", "$66E5 BODY/UI hook", "$7F50 font wrapper", "Track24 SRT4 records"],
    }
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (OUT / "TEST_IN_MESEN.txt").write_text(
        f"{VERSION}\n\nLoad {cue.name} and power-cycle. No Lua is required.\n"
        "The first request for a slot uses the original safe 704-byte CD read. Repeated requests use AC RAM.\n"
        "Verify that the opening/reception graphics remain intact, then reopen the same UI items to compare delay.\n",
        encoding="utf-8-sig",
    )
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
