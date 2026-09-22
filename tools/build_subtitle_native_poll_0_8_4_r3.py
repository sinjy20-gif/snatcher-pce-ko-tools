#!/usr/bin/env python3
"""Build 0.8.4-r3 with the fixed E6800_0E selector embedded in Track24."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

import build_subtitle_native_poll_bios_0_8_4_r1 as bios_r1
import build_subtitle_native_poll_disc_0_8_4 as disc


ROOT = Path(__file__).resolve().parents[1]
base = bios_r1.base
BUILD = ROOT / "build" / "cutscene_subs"
KEY = bytes((0x78, 0x30, 0x00, 0x00, 0x68, 0x0E))
SELECTOR = 366

RENDERER_SOURCE = BUILD / "resident_renderer_slot_native_poll_0_8_3.bin"
RENDERER_KEYED = BUILD / "resident_renderer_slot_native_poll_0_8_4_r3.bin"

base.OUT = ROOT / "build" / "bios_font" / "Syscard3_galmuri_sub_native_poll_0_8_4_r3.pce"
base.INFO = ROOT / "build" / "bios_font" / "subtitle_native_poll_0_8_4_r3.json"
base.RAW_PAYLOAD = BUILD / "subtitle_track24_append_0_8_4_r3.raw"
base.USER_PAYLOAD = BUILD / "subtitle_track24_append_0_8_4_r3.user.bin"


def make_keyed_renderer() -> bytes:
    renderer = bytearray(RENDERER_SOURCE.read_bytes())
    if len(renderer) != 671:
        raise SystemExit(f"renderer size {len(renderer)} != 671")
    if renderer[SELECTOR:SELECTOR + len(KEY)] != bytes(len(KEY)):
        raise SystemExit("renderer selector source is no longer blank")
    renderer[SELECTOR:SELECTOR + len(KEY)] = KEY
    RENDERER_KEYED.write_bytes(renderer)
    return bytes(renderer)


def payloads():
    renderer = make_keyed_renderer()
    return [
        ("pack", (BUILD / "subtitle_pack.bin").read_bytes(), base.PACK_AT),
        ("helper", (BUILD / "resident_helper_slot_native_poll_0_8_3.bin").read_bytes(), base.HELPER_AT),
        ("renderer", renderer, base.RENDERER_AT),
    ]


def build_bios_and_payload():
    base.payloads = payloads
    bios_r1.main()
    info = json.loads(base.INFO.read_text(encoding="utf-8"))
    info.update({
        "revision": "0.8.4-r3",
        "track24_index1_file_sector": 225,
        "track24_file_lba": 234924,
        "embedded_selector_offset": SELECTOR,
        "embedded_selector": KEY.hex(" ").upper(),
        "renderer_keyed": str(RENDERER_KEYED),
        "renderer_keyed_sha256": hashlib.sha256(RENDERER_KEYED.read_bytes()).hexdigest(),
    })
    base.INFO.write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")


def build_disc():
    disc.APPEND = base.RAW_PAYLOAD
    disc.OUT = ROOT / "build" / "patch" / "subtitle_native_poll_0_8_4_r3"
    disc.NAME02 = "Snatcher CD-ROMantic (Japan) (Track 02) [KO subtitle native 0.8.4-r3].bin"
    disc.NAME24 = "Snatcher CD-ROMantic (Japan) (Track 24) [KO subtitle native 0.8.4-r3].bin"

    original_stage_cue = disc.stage_cue
    def stage_cue_r3(target02, target24):
        cue = original_stage_cue(target02, target24)
        target = cue.with_name("Snatcher CD-ROMantic (Japan) [KO subtitle native 0.8.4-r3].cue")
        cue.replace(target)
        return target
    disc.stage_cue = stage_cue_r3
    disc.main()


def main():
    build_bios_and_payload()
    build_disc()
    print("renderer selector", RENDERER_KEYED.read_bytes()[SELECTOR:SELECTOR + 6].hex(" ").upper())


if __name__ == "__main__":
    main()
