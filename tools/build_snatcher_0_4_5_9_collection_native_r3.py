#!/usr/bin/env python3
"""Add the proven native subtitle r3 POC to the current-master collection disc."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

import build_subtitle_native_poll_0_8_4_r3 as r3


ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "build" / "patch" / "0.4.5.9-collection-base"
OUT = ROOT / "build" / "patch" / "0.4.5.9-subtitle-collection"
BUILD = ROOT / "build" / "cutscene_subs"

SOURCE02 = next(BASE.glob("*Track 02*.bin"))
SOURCE24 = next(BASE.glob("*Track 24*.bin"))
BIOS = ROOT / "build" / "bios_font" / "Syscard3_galmuri_0_4_5_9_subtitle_collection.pce"
BIOS_INFO = ROOT / "build" / "bios_font" / "subtitle_native_0_4_5_9_collection.json"
APPEND_RAW = BUILD / "subtitle_track24_append_0_4_5_9_collection.raw"
APPEND_USER = BUILD / "subtitle_track24_append_0_4_5_9_collection.user.bin"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def build_bios_payload():
    base = r3.base
    base.BASE24 = SOURCE24
    base.OUT = BIOS
    base.INFO = BIOS_INFO
    base.RAW_PAYLOAD = APPEND_RAW
    base.USER_PAYLOAD = APPEND_USER
    base.payloads = r3.payloads
    r3.bios_r1.main()

    info = json.loads(BIOS_INFO.read_text(encoding="utf-8"))
    info.update({
        "revision": "0.4.5.9-subtitle-collection",
        "base_build": str(BASE),
        "track24_index1_file_sector": 225,
        "track24_file_lba": 234924,
        "embedded_selector_offset": r3.SELECTOR,
        "embedded_selector": r3.KEY.hex(" ").upper(),
        "scope": "collection POC; fixed E6800_0E selector only",
    })
    BIOS_INFO.write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")
    return info


def build_disc():
    disc = r3.disc
    disc.BASE = BASE
    disc.SOURCE02 = SOURCE02
    disc.SOURCE24 = SOURCE24
    disc.APPEND = APPEND_RAW
    disc.OUT = OUT
    disc.NAME02 = "Snatcher CD-ROMantic (Japan) (Track 02) [KO 0.4.5.9 subtitle collection].bin"
    disc.NAME24 = "Snatcher CD-ROMantic (Japan) (Track 24) [KO 0.4.5.9 subtitle collection].bin"

    original_stage_cue = disc.stage_cue
    def stage_cue_collection(target02, target24):
        cue = original_stage_cue(target02, target24)
        target = cue.with_name("Snatcher CD-ROMantic (Japan) [KO 0.4.5.9 subtitle collection].cue")
        cue.replace(target)
        return target
    disc.stage_cue = stage_cue_collection
    disc.main()
    return disc


def main():
    info = build_bios_payload()
    disc = build_disc()
    print("0.4.5.9 subtitle collection")
    for row in info["rows"]:
        print(f"  {row['name']}: ${row['relative_sector']:04X} -> AC ${row['destination']:06X}")
    print("  BIOS   ", sha256(BIOS))
    print("  Track02", sha256(OUT / disc.NAME02))
    print("  Track24", sha256(OUT / disc.NAME24))


if __name__ == "__main__":
    main()
