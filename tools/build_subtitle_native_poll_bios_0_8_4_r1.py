#!/usr/bin/env python3
"""0.8.4-r1: run the proven Bank69 load_blob in its assembled MPR5 window."""
from __future__ import annotations

import json
from pathlib import Path

import build_subtitle_native_poll_bios_0_8_4 as base


ROOT = Path(__file__).resolve().parents[1]
base.OUT = ROOT / "build" / "bios_font" / "Syscard3_galmuri_sub_native_poll_0_8_4_r1.pce"
base.INFO = ROOT / "build" / "bios_font" / "subtitle_native_poll_0_8_4_r1.json"

LOAD_BLOB = 0xBE64
VARS = 0xBFE0
HELPER_BANK = 0x69
HELPER_MPR_MASK = 0x20              # MPR5, CPU $A000-$BFFF


def build(rows):
    a = base.Assembler(base.CAVE)

    # Same read-only polling state machine as 0.8.3/0.8.4.
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

    # load_blob was assembled at $BE64 and contains absolute $BFxx operands.
    # The failed 0.8.4 called its $7E64 physical alias, so those operands looked
    # through the wrong logical window.  Reproduce the shipped trampoline:
    # preserve P/MPR5, map Bank69 at $A000-$BFFF, then call the original label.
    a.label("preload")
    a.emit(0x08, 0x78, 0xDA, 0x5A)                 # PHP, SEI, PHX, PHY
    a.emit(0x43, HELPER_MPR_MASK, 0x48)             # TMA #$20, PHA
    a.emit(0xA9, HELPER_BANK, 0x53, HELPER_MPR_MASK)# LDA #$69, TAM #$20

    a.emit(0xA0, 0);  a.abs(0x20, "load_one"); a.branch(0xD0, "fail_pack")
    a.emit(0xA0, 8);  a.abs(0x20, "load_one"); a.branch(0xD0, "fail_helper")
    a.emit(0xA0, 16); a.abs(0x20, "load_one"); a.branch(0xD0, "fail_renderer")
    a.abs(0x9C, base.STATE)
    a.branch(0x80, "restore_window")

    a.label("fail_pack");     a.emit(0xA9, 0xF1); a.abs(0x8D, base.STATE); a.branch(0x80, "restore_window")
    a.label("fail_helper");   a.emit(0xA9, 0xF2); a.abs(0x8D, base.STATE); a.branch(0x80, "restore_window")
    a.label("fail_renderer"); a.emit(0xA9, 0xF3); a.abs(0x8D, base.STATE)

    a.label("restore_window")
    a.emit(0x68, 0x53, HELPER_MPR_MASK)             # PLA, TAM #$20
    a.emit(0x7A, 0xFA, 0x28, 0xA9, 0, 0x60)        # PLY, PLX, PLP, LDA #0, RTS

    a.label("load_one"); a.emit(0xA2, 0)
    a.label("load_copy"); a.abs(0xB9, "load_table"); a.emit(0x9D); a.word(VARS)
    a.emit(0xC8, 0xE8, 0xE0, 8); a.branch(0xD0, "load_copy")
    a.abs(0x20, LOAD_BLOB); a.emit(0x60)
    a.label("load_table")
    for row in rows:
        sector = row["relative_sector"]
        dest = row["destination"]
        if sector > 0xFFFF:
            raise SystemExit("relative sector exceeds 16 bit")
        a.emit(sector & 0xFF, sector >> 8, row["full_chunks"], row["final_sectors"],
               dest & 0xFF, (dest >> 8) & 0xFF, (dest >> 16) & 0xFF, 0)
    return a.finish()


def main():
    base.build = build
    base.main()
    info = json.loads(base.INFO.read_text(encoding="utf-8"))
    info.update({
        "revision": "0.8.4-r1",
        "load_blob_runtime": "BE64",
        "vars": "BFE0-BFE7",
        "helper_bank": "69",
        "helper_mpr_mask": "20",
        "failure_states": {"F1": "pack", "F2": "helper", "F3": "renderer"},
    })
    base.INFO.write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
