#!/usr/bin/env python3
"""Experimental 0.4.5.9: preload the complete KO AC image with subtitles.

The ordinary translation helper performs its 1.07 MiB Track24 -> AC transfer
on the first Korean renderer call.  This build moves the same image into the
already-proven native subtitle boot loader, then marks the translation state
page as initialised.  Runtime text lookup therefore performs no CD read.

This is deliberately a separate experiment.  It does not include the dynamic
subtitle VRAM allocator.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

import build_snatcher_0_4_5_9_collection_native_r3 as collection
import subtitle_layout as subtitle_mem


ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "build" / "patch" / "0.4.5.9-collection-base"
OUT = ROOT / "build" / "patch" / "0.4.5.9-boot-ac-subtitle"
BUILD = ROOT / "build" / "cutscene_subs"
TRANSLATION_IMAGE = BASE / "ac_dynamic_packs" / "disc_package_image.bin"

BIOS = ROOT / "build" / "bios_font" / "Syscard3_galmuri_0_4_5_9_boot_ac_subtitle.pce"
BIOS_INFO = ROOT / "build" / "bios_font" / "subtitle_native_0_4_5_9_boot_ac_subtitle.json"
APPEND_RAW = BUILD / "subtitle_track24_append_0_4_5_9_boot_ac.raw"
APPEND_USER = BUILD / "subtitle_track24_append_0_4_5_9_boot_ac.user.bin"

TRANSLATION_AC = 0x000000
TRANSLATION_LIMIT = 0x160000
TRANSLATION_MAGIC = bytes((0xAC, 0x15, 0x51))
TRANSLATION_PACKS = 3
SET_STATE_ADDRESS = 0xBF32
AC_DATA = 0x1A00
REVISION = "0.4.5.9-boot-ac-subtitle"
DISPLAY = "0.4.5.9 boot AC subtitle"
DISC_TAG = f"KO {DISPLAY}"


def pack_with_adpcm_master():
    """팩 preload 행 하나로 팩과 ADPCM LBA 마스터를 같이 싣는다."""
    pack = (BUILD / "subtitle_pack.bin").read_bytes()
    master = (BUILD / "adpcm_lba_master_index.bin").read_bytes()
    offset = subtitle_mem.AC_ADPCM_LBA_MASTER - subtitle_mem.AC_PACK
    if len(pack) > offset:
        raise SystemExit(
            f"subtitle pack {len(pack):,} B가 ADPCM master 자리 "
            f"${subtitle_mem.AC_ADPCM_LBA_MASTER:06X}를 침범한다")
    return pack + bytes((0xFF,)) * (offset - len(pack)) + master


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def payloads():
    r3 = collection.r3
    renderer = r3.make_keyed_renderer()
    return [
        ("translation_all", TRANSLATION_IMAGE.read_bytes(), TRANSLATION_AC),
        ("subtitle_pack", pack_with_adpcm_master(), r3.base.PACK_AT),
        ("subtitle_helper", (BUILD / "resident_helper_slot_native_poll_0_8_3.bin").read_bytes(),
         r3.base.HELPER_AT),
        ("subtitle_renderer", renderer, r3.base.RENDERER_AT),
    ]


def build_loader(rows):
    """Build a four-item Bank69 load_blob trampoline in the BIOS cave."""
    r1 = collection.r3.bios_r1
    base = r1.base
    a = base.Assembler(base.CAVE)

    # Proven native-poll state machine, unchanged.
    a.abs(0xAD, base.STATE); a.emit(0xC9, 0xFF); a.branch(0xF0, "preload")
    a.emit(0xC9, 0xFE); a.branch(0xF0, "idle")
    a.emit(0xC9, 0x02); a.branch(0xF0, "active")
    a.emit(0xC9, 0x00); a.branch(0xD0, "ret")
    a.abs(0xAD, 0x22A6); a.branch(0xD0, "idle")
    a.abs(0xAD, 0x22A7); a.emit(0xC9, 0x68); a.branch(0xD0, "idle")
    a.abs(0xAD, 0x22AA); a.emit(0xC9, 0x0E); a.branch(0xD0, "idle")
    a.abs(0xAD, 0x180D); a.emit(0x29, 0x20); a.branch(0xF0, "idle")
    a.emit(0xA9, 1); a.abs(0x8D, base.STATE); a.emit(0x60)
    a.label("active"); a.abs(0xAD, 0x180D); a.emit(0x29, 0x20); a.branch(0xD0, "still")
    a.emit(0xA9, 3); a.abs(0x8D, base.STATE); a.emit(0x60)
    a.label("still"); a.emit(0xA9, 2, 0x60)
    a.label("idle"); a.emit(0xA9, 0)
    a.label("ret"); a.emit(0x60)

    # Keep the shipped Bank69 helper mapped while load_blob and
    # set_state_address execute; both contain absolute $BFxx operands.
    a.label("preload")
    a.emit(0x08, 0x78, 0xDA, 0x5A)                       # PHP SEI PHX PHY
    a.emit(0x43, 0x20, 0x48)                             # TMA #$20, PHA
    a.emit(0xA9, 0x69, 0x53, 0x20)                       # Bank69 -> MPR5

    a.emit(0xA0, 0); a.abs(0x20, "load_one"); a.branch(0xD0, "fail_translation")

    # The normal helper writes these bytes after its first-demand load.  Since
    # boot loaded the exact same image, publish the same state immediately:
    # magic AC 15 51 followed by one loaded flag for every resident pack.
    a.emit(0xA9, 0); a.abs(0x20, SET_STATE_ADDRESS)
    for value in TRANSLATION_MAGIC + bytes((1,)) * TRANSLATION_PACKS:
        a.emit(0xA9, value); a.abs(0x8D, AC_DATA)

    a.emit(0xA0, 8);  a.abs(0x20, "load_one"); a.branch(0xD0, "fail_pack")
    a.emit(0xA0, 16); a.abs(0x20, "load_one"); a.branch(0xD0, "fail_helper")
    a.emit(0xA0, 24); a.abs(0x20, "load_one"); a.branch(0xD0, "fail_renderer")
    a.abs(0x9C, base.STATE)
    a.branch(0x80, "restore_window")

    for label, value in (("fail_translation", 0xF0), ("fail_pack", 0xF1),
                         ("fail_helper", 0xF2), ("fail_renderer", 0xF3)):
        a.label(label); a.emit(0xA9, value); a.abs(0x8D, base.STATE)
        a.branch(0x80, "restore_window")

    a.label("restore_window")
    a.emit(0x68, 0x53, 0x20)                             # PLA, TAM #$20
    a.emit(0x7A, 0xFA, 0x28, 0xA9, 0, 0x60)             # PLY PLX PLP LDA#0 RTS

    a.label("load_one"); a.emit(0xA2, 0)
    a.label("load_copy"); a.abs(0xB9, "load_table"); a.emit(0x9D); a.word(0xBFE0)
    a.emit(0xC8, 0xE8, 0xE0, 8); a.branch(0xD0, "load_copy")
    a.abs(0x20, 0xBE64); a.emit(0x60)
    a.label("load_table")
    for row in rows:
        sector, dest = row["relative_sector"], row["destination"]
        if sector > 0xFFFF:
            raise SystemExit("relative sector exceeds 16 bit")
        a.emit(sector & 0xFF, sector >> 8, row["full_chunks"], row["final_sectors"],
               dest & 0xFF, (dest >> 8) & 0xFF, (dest >> 16) & 0xFF, 0)
    return a.finish()


def build_bios_payload():
    r3 = collection.r3
    base = r3.base
    base.BASE24 = collection.SOURCE24
    base.OUT = BIOS
    base.INFO = BIOS_INFO
    base.RAW_PAYLOAD = APPEND_RAW
    base.USER_PAYLOAD = APPEND_USER
    base.payloads = payloads
    base.build = build_loader
    base.main()

    info = json.loads(BIOS_INFO.read_text(encoding="utf-8"))
    info.update({
        "revision": REVISION,
        "base_build": str(BASE),
        "translation_image": str(TRANSLATION_IMAGE),
        "translation_magic": TRANSLATION_MAGIC.hex(" ").upper(),
        "translation_loaded_flags": TRANSLATION_PACKS,
        "runtime_cd_reads_expected": 0,
        "dynamic_vram_allocator": False,
    })
    BIOS_INFO.write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")
    return info


def build_disc():
    disc = collection.r3.disc
    disc.BASE = BASE
    disc.SOURCE02 = collection.SOURCE02
    disc.SOURCE24 = collection.SOURCE24
    disc.APPEND = APPEND_RAW
    disc.OUT = OUT
    disc.NAME02 = f"Snatcher CD-ROMantic (Japan) (Track 02) [{DISC_TAG}].bin"
    disc.NAME24 = f"Snatcher CD-ROMantic (Japan) (Track 24) [{DISC_TAG}].bin"
    original_stage_cue = disc.stage_cue

    def stage_cue(target02, target24):
        cue = original_stage_cue(target02, target24)
        target = cue.with_name(f"Snatcher CD-ROMantic (Japan) [{DISC_TAG}].cue")
        cue.replace(target)
        return target

    disc.stage_cue = stage_cue
    disc.main()
    return disc


def verify(info, disc):
    rows = info["rows"]
    blobs = payloads()
    if len(rows) != len(blobs):
        raise SystemExit("boot payload row count mismatch")
    translation = blobs[0][1]
    if len(translation) > TRANSLATION_LIMIT:
        raise SystemExit("translation image overlaps subtitle AC reserve")
    if rows[0]["destination"] != 0 or rows[1]["destination"] < TRANSLATION_LIMIT:
        raise SystemExit("AC layout is not translation-low / subtitle-high")

    track24 = OUT / disc.NAME24
    raw = track24.read_bytes()
    for row, (name, blob, _dest) in zip(rows, blobs):
        # The native Track24 loader pads every payload sector with $FF.
        padded = blob + bytes((0xFF,)) * (-len(blob) % 2048)
        file_sector = row["absolute_lba"] - 234924
        got = bytearray()
        for i in range(row["sectors"]):
            at = (file_sector + i) * 2352 + 16
            got.extend(raw[at:at + 2048])
        if bytes(got) != padded:
            raise SystemExit(f"Track24 byte verification failed: {name}")
    print("  verification: four payloads byte-exact; AC ranges do not overlap")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    info = build_bios_payload()
    disc = build_disc()
    verify(info, disc)
    print(f"\n{DISPLAY} experiment")
    for row in info["rows"]:
        print(f"  {row['name']:19} {row['bytes']:8,d} B -> AC ${row['destination']:06X}")
    print("  BIOS   ", sha256(BIOS))
    print("  Track02", sha256(OUT / disc.NAME02))
    print("  Track24", sha256(OUT / disc.NAME24))
    print("  ->", OUT)


if __name__ == "__main__":
    main()
