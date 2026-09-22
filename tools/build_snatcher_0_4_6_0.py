#!/usr/bin/env python3
"""Snatcher KO 0.4.6.0: true early BIOS Arcade Card preload.

The BIOS CD_READ vector is wrapped.  After the first successful game read
that has made Bank69's verified load_blob helper available, the complete
translation/subtitle payload is loaded before control returns to the game.
Nested CD_READs are routed straight to the original BIOS implementation.
The normal subtitle resident still calls $FEC4 for its read-only state
decision, but can no longer start the preload itself.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

import build_snatcher_0_4_5_9_boot_ac_subtitle as boot


ROOT = Path(__file__).resolve().parents[1]
VERSION = os.environ.get("SNATCHER_BUILD_VERSION", "0.4.6.0")
BASE = ROOT / "build" / "patch" / "TEST" / "0.4.5.9-signtest-base"
OUT = ROOT / "build" / "patch" / VERSION

ORIGINAL_CD_READ = 0xEC05
CD_READ_VECTOR = 0xE009
LOAD_BLOB = 0xBE64
SET_STATE_ADDRESS = 0xBF32
VARS = 0xBFE0
GUARD_PORTS = (0x1A32,)
GUARD_MAGIC = (0x60 + (int(VERSION.rsplit('.', 1)[1]) & 0x0F),)
STATE = 0x7FDF
HELPER_BANK = 0x69
REENTRY_BANK = 0xFF
MPR5, MPR6 = 0x20, 0x40
BOOT_HOOK = 0
LOADER_LABELS = {}


boot.BASE = BASE
boot.OUT = OUT
boot.TRANSLATION_IMAGE = BASE / "ac_dynamic_packs" / "disc_package_image.bin"
BIOS_NAME = f"Syscard3_galmuri_{VERSION}.pce"
boot.BIOS = OUT / BIOS_NAME
boot.BIOS_INFO = OUT / "bios_preload.json"
boot.APPEND_RAW = boot.BUILD / "subtitle_track24_append_0_4_6_0.raw"
boot.APPEND_USER = boot.BUILD / "subtitle_track24_append_0_4_6_0.user.bin"
boot.REVISION = VERSION
boot.DISPLAY = VERSION
boot.DISC_TAG = "KO"
boot.collection.BASE = BASE
boot.collection.SOURCE02 = next(BASE.glob("*Track 02*.bin"))
boot.collection.SOURCE24 = next(BASE.glob("*Track 24*.bin"))


def build_loader(rows):
    """Build resident decision entry plus the early CD_READ wrapper."""
    global BOOT_HOOK, LOADER_LABELS
    a = boot.collection.r3.base.Assembler(boot.collection.r3.base.CAVE)

    # $FEC4 remains the resident's decision entry.  $FF used to launch the
    # late preload; now it is simply normalised to idle because BIOS already
    # completed the preload before the game reached this resident.
    a.abs(0xAD, STATE); a.emit(0xC9, 0xFF); a.branch(0xF0, "resident_reset")
    a.emit(0xC9, 0xFE); a.branch(0xF0, "resident_idle")
    a.emit(0xC9, 0x02); a.branch(0xF0, "resident_active")
    a.emit(0xC9, 0x00); a.branch(0xD0, "resident_ret")
    a.abs(0xAD, 0x22A6); a.branch(0xD0, "resident_idle")
    a.abs(0xAD, 0x22A7); a.emit(0xC9, 0x68); a.branch(0xD0, "resident_idle")
    a.abs(0xAD, 0x22AA); a.emit(0xC9, 0x0E); a.branch(0xD0, "resident_idle")
    a.abs(0xAD, 0x180D); a.emit(0x29, 0x20); a.branch(0xF0, "resident_idle")
    a.emit(0xA9, 1); a.abs(0x8D, STATE); a.emit(0x60)
    a.label("resident_active")
    a.abs(0xAD, 0x180D); a.emit(0x29, 0x20); a.branch(0xD0, "resident_still")
    a.emit(0xA9, 3); a.abs(0x8D, STATE); a.emit(0x60)
    a.label("resident_still"); a.emit(0xA9, 2, 0x60)
    a.label("resident_reset"); a.abs(0x9C, STATE)
    a.label("resident_idle"); a.emit(0xA9, 0)
    a.label("resident_ret"); a.emit(0x60)

    # E009 jumps here. During our own load_blob calls MPR5=$69 and MPR6=$FF;
    # that unique pair bypasses the wrapper and prevents recursive preloading.
    a.label("boot_hook")
    a.emit(0x48)                                      # PHA: preserve caller A
    a.emit(0x43, MPR5, 0xC9, HELPER_BANK); a.branch(0xD0, "ordinary_read")
    a.emit(0x43, MPR6, 0xC9, REENTRY_BANK); a.branch(0xD0, "ordinary_read")
    a.emit(0x68); a.abs(0x4C, ORIGINAL_CD_READ)       # nested: original BIOS
    a.label("ordinary_read")
    a.emit(0x68); a.abs(0x20, ORIGINAL_CD_READ)
    a.emit(0x08, 0x48, 0xDA, 0x5A)                   # save P/A/X/Y result
    a.emit(0xC9, 0); a.branch(0xD0, "boot_done")
    a.emit(0x78)                                      # SEI across mapped helper/CD loads

    # Preserve both windows, map the verified Bank69 helper, and wait until
    # the game has actually loaded it. Earlier CD_READs just pass through.
    a.emit(0x43, MPR5, 0x48, 0x43, MPR6, 0x48)
    a.emit(0xA9, HELPER_BANK, 0x53, MPR5)
    for offset, value in enumerate((0x20, 0x12)):
        a.abs(0xAD, LOAD_BLOB + offset); a.emit(0xC9, value)
        a.branch(0xD0, "restore_windows")
    # Persistent one-shot guard in unused Arcade Card port-3 address latches.
    # The original game does not use the Arcade Card, and this patch uses only
    # ports 0 and 1. Reading these registers cannot disturb port-0's stream.
    for port, value in zip(GUARD_PORTS, GUARD_MAGIC):
        a.abs(0xAD, port); a.emit(0xC9, value)
        a.branch(0xD0, "preload_needed")
    a.branch(0x80, "restore_windows")
    a.label("preload_needed")
    a.emit(0xA9, REENTRY_BANK, 0x53, MPR6)

    for index, fail in ((0, "load_failed"), (8, "load_failed"),
                        (16, "load_failed"), (24, "load_failed")):
        a.emit(0xA0, index); a.abs(0x20, "load_one"); a.branch(0xD0, fail)

    # Publish exactly the state written by the old first-demand translation
    # initialiser. Future renderer calls therefore read AC immediately.
    a.emit(0xA9, 0); a.abs(0x20, SET_STATE_ADDRESS)
    # valid_pack compares state[3 + pack_id] with pack_id itself.
    for value in boot.TRANSLATION_MAGIC + bytes(range(boot.TRANSLATION_PACKS)):
        a.emit(0xA9, value); a.abs(0x8D, boot.AC_DATA)
    for port, value in zip(GUARD_PORTS, GUARD_MAGIC):
        a.emit(0xA9, value); a.abs(0x8D, port)
    a.branch(0x80, "restore_windows")
    a.label("load_failed")
    # Leave magic unpublished; a later successful game CD read may retry.
    a.label("restore_windows")
    a.emit(0x68, 0x53, MPR6, 0x68, 0x53, MPR5)
    a.label("boot_done")
    a.emit(0x7A, 0xFA, 0x68, 0x28, 0x60)             # PLY PLX PLA PLP RTS

    a.label("load_one"); a.emit(0xA2, 0)
    a.label("load_copy"); a.abs(0xB9, "load_table"); a.emit(0x9D); a.word(VARS)
    a.emit(0xC8, 0xE8, 0xE0, 8); a.branch(0xD0, "load_copy")
    a.abs(0x20, LOAD_BLOB); a.emit(0x60)
    a.label("load_table")
    for row in rows:
        sector, dest = row["relative_sector"], row["destination"]
        a.emit(sector & 0xFF, sector >> 8, row["full_chunks"], row["final_sectors"],
               dest & 0xFF, (dest >> 8) & 0xFF, (dest >> 16) & 0xFF, 0)
    code = a.finish()
    BOOT_HOOK = a.labels["boot_hook"]
    LOADER_LABELS = dict(a.labels)
    return code


def patch_cd_read_vector(info):
    image = bytearray(boot.BIOS.read_bytes())
    at = CD_READ_VECTOR - 0xE000
    old = bytes(image[at:at + 3])
    if old != bytes((0x4C, 0x05, 0xEC)):
        raise SystemExit(f"unexpected BIOS CD_READ vector: {old.hex(' ')}")
    image[at:at + 3] = bytes((0x4C, BOOT_HOOK & 0xFF, BOOT_HOOK >> 8))
    boot.BIOS.write_bytes(image)
    info.update({
        "sha256": hashlib.sha256(image).hexdigest(),
        "bios_hooks": 1,
        "version": VERSION,
        "true_bios_preload": True,
        "cd_read_vector": f"E009->{BOOT_HOOK:04X}",
        "original_cd_read": f"{ORIGINAL_CD_READ:04X}",
        "helper_ready_signature": "20 12 BF at BE64, Bank69",
        "resident_late_preload": False,
        "file_naming": "stable inside version-only folder",
        "bios_sha256": hashlib.sha256(image).hexdigest().upper(),
    })
    boot.BIOS_INFO.write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    boot.build_loader = build_loader
    info = boot.build_bios_payload()
    patch_cd_read_vector(info)
    disc = boot.build_disc()
    boot.verify(info, disc)
    manifest = {
        "version": VERSION,
        "cue": "Snatcher CD-ROMantic (Japan) [KO].cue",
        "bios": BIOS_NAME,
        "base": str(BASE),
        "goal": "AC complete before city scene; zero game-scene preload",
        "temporary_sign_text": "코나미 빌딩 / JUNKER본부",
        "payload_bytes": sum(row["bytes"] for row in info["rows"]),
        "bios_preload": info,
        "loader_labels": {key: f"{value:04X}" for key, value in LOADER_LABELS.items()},
    }
    (OUT / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"\n{VERSION} -> {OUT}")
    print(f"  BIOS CD_READ E009 -> {BOOT_HOOK:04X}; resident late preload disabled")
    print("  disc names stay stable; BIOS name includes the version")


if __name__ == "__main__":
    main()
