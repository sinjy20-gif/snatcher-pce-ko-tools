#!/usr/bin/env python3
"""Build ac_0.1.3: early main-loop preload with a 24 KiB AC write window."""

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
import build_track24_loader_proof as track24  # noqa: E402


VERSION = "ac_0.1.3"
BASE = ROOT / "build" / "patch" / "ac_0.1.1"
OUT = ROOT / "build" / "patch" / VERSION
AC_DATA = ROOT / "build" / "patch" / "0.3.0-uitest" / "ac_backing_store"

INIT_ENTRY = 0x6000
ONE_SHOT_WRAPPER = 0x5BB3
PRELOAD_HELPER = 0x7CD2  # Bank $69 mapped into MPR3 ($6000-$7FFF)
BANK69_ISO_BASE = 0x07D800
BIOS_CD_BASE = 0xE006
BIOS_CD_READ = 0xE009
TRACK24_INDEX1_LBA = 235149
TRACK02_INDEX1_LBA = 0x00104E
PRELOAD_RELATIVE_SECTOR = 33973 + 0x4000
CHUNK_BYTES = 0x6000
FULL_CHUNKS = 32
FINAL_BYTES = 1408


def bank69_iso(cpu: int) -> int:
    if not 0x8000 <= cpu < 0xA000:
        raise ValueError(f"not an MPR4 CPU address: ${cpu:04X}")
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


def emit_read_args(a: common.Assembler, length: int, current_lo: int, current_hi: int) -> None:
    for zp, value in ((0xF8, length), (0xF9, length >> 8), (0xFA, 0), (0xFB, 0x80), (0xFC, 0)):
        a.emit(0xA9, value, 0x85, zp)
    a.abs(0xAD, current_hi); a.emit(0x85, 0xFD)
    a.abs(0xAD, current_lo); a.emit(0x85, 0xFE)
    a.emit(0xA9, 0, 0x85, 0xFF)


def build_preload_helper() -> bytes:
    a = common.Assembler(PRELOAD_HELPER)
    # Arcade Card port 0: base 0, increment 1, auto-increment into base.
    for address in (0x1A02, 0x1A03, 0x1A04, 0x1A08):
        a.abs(0x9C, address)
    a.emit(0xA9, 1); a.abs(0x8D, 0x1A07)
    a.emit(0xA9, 0x11); a.abs(0x8D, 0x1A09)
    emit_cd_base(a, TRACK24_INDEX1_LBA)

    # Execute from MPR3/Bank69 while MPR4-6 become one 24 KiB AC window.
    a.emit(0x43, 0x10, 0x48, 0x43, 0x20, 0x48, 0x43, 0x40, 0x48)
    a.emit(0xA9, 0x40, 0x53, 0x70)
    current_lo = PRELOAD_HELPER + 0x300
    current_hi = current_lo + 1
    count = current_lo + 2
    status = current_lo + 3
    a.emit(0xA9, PRELOAD_RELATIVE_SECTOR & 0xFF); a.abs(0x8D, current_lo)
    a.emit(0xA9, PRELOAD_RELATIVE_SECTOR >> 8); a.abs(0x8D, current_hi)
    a.abs(0x9C, count)
    a.label("full_loop")
    emit_read_args(a, CHUNK_BYTES, current_lo, current_hi)
    a.abs(0x20, BIOS_CD_READ)
    a.emit(0xC9, 0)
    a.branch(0xD0, "read_failed")
    a.emit(0x18); a.abs(0xAD, current_lo); a.emit(0x69, 12); a.abs(0x8D, current_lo)
    a.abs(0xAD, current_hi); a.emit(0x69, 0); a.abs(0x8D, current_hi)
    a.abs(0xEE, count); a.abs(0xAD, count); a.emit(0xC9, FULL_CHUNKS)
    a.branch(0x90, "full_loop")
    emit_read_args(a, FINAL_BYTES, current_lo, current_hi)
    a.abs(0x20, BIOS_CD_READ)
    a.emit(0xC9, 0)
    a.branch(0xD0, "read_failed")
    a.emit(0xA9, 0)
    a.branch(0x80, "restore")
    a.label("read_failed")
    a.emit(0xA9, 1)
    a.label("restore")
    a.abs(0x8D, status)
    a.emit(0x68, 0x53, 0x40, 0x68, 0x53, 0x20, 0x68, 0x53, 0x10)
    emit_cd_base(a, TRACK02_INDEX1_LBA)
    a.abs(0xAD, status)
    a.emit(0x60)
    code = a.finish()
    if len(code) > 0x300:
        raise RuntimeError(f"preload helper exceeds Bank69 cave budget: {len(code)}")
    return code


def build_one_shot_wrapper() -> bytes:
    a = common.Assembler(ONE_SHOT_WRAPPER)
    a.emit(0x48, 0xDA, 0x5A)  # preserve caller A/X/Y
    a.emit(0xA2, 5)
    a.label("save_work")
    a.emit(0xB5, 0, 0x48, 0xE8, 0xE0, 9); a.branch(0x90, "save_work")
    a.emit(0xA2, 7)
    a.label("save_bios")
    a.emit(0xB5, 0xF8, 0x48, 0xCA); a.branch(0x10, "save_bios")
    a.emit(0x43, 0x08, 0x48, 0xA9, 0x69, 0x53, 0x08)  # map Bank69 in MPR3
    a.abs(0x20, PRELOAD_HELPER)
    a.emit(0x85, 0x05, 0x68, 0x53, 0x08)  # status; restore MPR3
    a.emit(0xA5, 0x05)
    a.branch(0xD0, "restore")
    # Self-remove: restore the displaced JSR $6016 at the main-loop entry.
    a.emit(0xA9, 0x16); a.abs(0x8D, INIT_ENTRY + 1)
    a.emit(0xA9, 0x60); a.abs(0x8D, INIT_ENTRY + 2)
    a.label("restore")
    a.emit(0xA2, 0)
    a.label("restore_bios")
    a.emit(0x68, 0x95, 0xF8, 0xE8, 0xE0, 8); a.branch(0x90, "restore_bios")
    a.emit(0xA2, 8)
    a.label("restore_work")
    a.emit(0x68, 0x95, 0, 0xCA, 0xE0, 4); a.branch(0xD0, "restore_work")
    a.emit(0x7A, 0xFA, 0x68)  # PLY/PLX/PLA
    a.abs(0x20, 0x6016)
    a.emit(0x60)
    code = a.finish()
    if len(code) > 0x2A0:
        raise RuntimeError(f"one-shot wrapper exceeds disposable cache: {len(code)}")
    return code


def stage_cue(track02: Path, track24_path: Path) -> Path:
    source_cue = next(BASE.glob("*.cue"))
    pattern = re.compile(r'^FILE "([^"]+)" BINARY$')
    lines = []
    for line in source_cue.read_text(encoding="ascii").splitlines():
        match = pattern.match(line)
        if not match:
            lines.append(line); continue
        source = BASE / match.group(1)
        if "Track 02" in source.name:
            target = track02
        elif "Track 24" in source.name:
            target = track24_path
        else:
            target = OUT / source.name.replace("ac_0.1.1", VERSION)
            if target.exists():
                lines.append(f'FILE "{target.name}" BINARY')
                continue
            try:
                target.hardlink_to(source)
            except OSError:
                shutil.copy2(source, target)
        lines.append(f'FILE "{target.name}" BINARY')
    cue = OUT / f"Snatcher CD-ROMantic (Japan) [KO {VERSION}].cue"
    cue.write_text("\n".join(lines) + "\n", encoding="ascii")
    return cue


def main() -> None:
    if OUT.exists():
        old_manifest = OUT / "manifest.json"
        if old_manifest.exists() and json.loads(old_manifest.read_text(encoding="utf-8")).get("version") != VERSION:
            raise SystemExit(f"refusing to update unrelated output: {OUT}")
    else:
        OUT.mkdir(parents=True)
    source02 = next(BASE.glob("*Track 02*ac_0.1.1*.bin"))
    wrapper = build_one_shot_wrapper()
    helper = build_preload_helper()
    patches = [
        common.Patch("main_loop_one_shot_hook", common.bank6a_iso(INIT_ENTRY), bytes.fromhex("20 16 60"), bytes((0x20, 0xB3, 0x5B)), INIT_ENTRY),
        common.Patch("one_shot_preload_wrapper", common.bank68_iso(ONE_SHOT_WRAPPER), bytes((0xFF,)) * len(wrapper), wrapper, ONE_SHOT_WRAPPER),
        common.Patch("bank69_cd_to_ac_preloader", BANK69_ISO_BASE + (PRELOAD_HELPER - 0x6000), bytes((0xFF,)) * len(helper), helper, PRELOAD_HELPER),
    ]
    target02 = OUT / f"Snatcher CD-ROMantic (Japan) (Track 02) [KO {VERSION}].bin"
    proof.apply_patches_streaming(source02, target02, patches)

    source24 = next(BASE.glob("*Track 24*ac_0.1.1*.bin"))
    target24 = OUT / f"Snatcher CD-ROMantic (Japan) (Track 24) [KO {VERSION}].bin"
    shutil.copyfile(source24, target24)
    image = (AC_DATA / "arcade_card_preload_used.bin").read_bytes()
    padded = image + bytes((-len(image)) % track24.USER_DATA_SIZE)
    first_lba = 269122 + 0x4000
    appended = bytearray()
    for index in range(0, len(padded), track24.USER_DATA_SIZE):
        lba = first_lba + index // track24.USER_DATA_SIZE
        sector = track24.make_mode1_sector(lba, padded[index:index + track24.USER_DATA_SIZE])
        track24.verify_mode1_sector(sector, lba)
        appended.extend(sector)
    with target24.open("ab") as handle:
        handle.write(appended)
    cue = stage_cue(target02, target24)
    for name in ("direct_records.tsv", "assets.tsv", "runtime_layout.json"):
        shutil.copy2(BASE / name, OUT / name)
    manifest = {
        "version": VERSION,
        "base_build": str(BASE),
        "preload": "early main-loop one-shot Track-24 CD to Arcade Card RAM",
        "preload_bytes": len(image),
        "preload_sectors": len(padded) // track24.USER_DATA_SIZE,
        "preload_relative_sector": PRELOAD_RELATIVE_SECTOR,
        "full_chunks": FULL_CHUNKS,
        "chunk_bytes": CHUNK_BYTES,
        "final_bytes": FINAL_BYTES,
        "wrapper_bytes": len(wrapper),
        "preload_helper_bytes": len(helper),
        "patched_track02_sha256": sha256_file(target02),
        "patched_track24_sha256": sha256_file(target24),
        "cue": cue.name,
    }
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (OUT / "TEST_IN_MESEN.txt").write_text(
        f"{VERSION}\n\nLoad {cue.name} and power-cycle. Do not load any Lua.\n"
        "The Track-02 main loop performs the one-time 787840-byte preload before the first BODY text.\n"
        "Wait for the early load, then verify reception BODY/UI and absence of later Korean CD stalls.\n",
        encoding="utf-8-sig",
    )
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
