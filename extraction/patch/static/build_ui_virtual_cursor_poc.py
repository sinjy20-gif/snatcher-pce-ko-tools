#!/usr/bin/env python3
"""UI 0.1.5: one long UI label through a virtual, non-global cursor.

The earlier UI pool POCs temporarily replaced $3471/$3472 with a cave address.
That draws text, but corrupts the UI state machine when it refreshes or exits.
This build leaves that global cursor on the original F7 marker.  Only $03/$04
(the renderer's per-character read pointer) is redirected to the Korean pool;
the renderer's four pointer-increment sites advance a private cursor instead.
"""
from __future__ import annotations

import csv
import hashlib
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(r"C:\snatcher")
ROM = ROOT / "rom(japan)" / "Snatcher CD-ROMantic (Japan)"
SOURCE02 = ROM / "Snatcher CD-ROMantic (Japan) (Track 02).bin"
SOURCE24 = ROM / "Snatcher CD-ROMantic (Japan) (Track 24).bin"
STATIC = ROOT / "extraction" / "patch" / "static"
TRANS = ROOT / "extraction" / "translation"
OUTROOT = ROOT / "build" / "patch"
sys.path[:0] = [str(STATIC), str(TRANS)]

import build_disc_patch as common
import build_speaker_ui_proof as stream
import build_track24_loader_proof as track24
from game_text_codec import encode_game_text, ordered_hangul

VERSION = "UI 0.1.7"
UI_ID = "UI0006"  # 中に入る -> 안으로 들어간다
UI_TSV = ROOT / "snatcher_tool" / "translation" / "ui_text.tsv"

FONT_CALL, ENTRY = 0x648C, 0x66E5
FONT_CALL_OLD = bytes((0x20, 0xC2, 0x69))
ENTRY_OLD = bytes.fromhex("AD 71 34 85 03 AD 72 34 85 04")

# Stable unused Track-02 cave, mapped through normal MPR2.
LOADER, ATLAS, POOL, PROXY, STATE = 0x5C00, 0x5D00, 0x5E60, 0x5E80, 0x5EF0
WRAPPER = 0x7F50
SLOTS_PER_LEAD = 188
# Start at each PHA, not at the later low-byte load.  The first revision
# accidentally started three bytes too late at three sites, corrupting their
# surrounding renderer instruction stream before the menu could open.
INC_SITES = (0x674D, 0x67B7, 0x67F7, 0x6840)


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest().upper()


def offsets(raw: str) -> list[int]:
    return [int(value.strip(), 16) for value in raw.split(",") if value.strip()]


def ui_row() -> dict[str, str]:
    with UI_TSV.open("r", encoding="utf-16", newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    found = [row for row in rows if row.get("ui_id") == UI_ID and row.get("status") in {"review", "final"}]
    if len(found) != 1:
        raise RuntimeError(f"expected one reviewed {UI_ID}, found {len(found)}")
    return found[0]


def code(index: int) -> bytes:
    lead, within = divmod(index, SLOTS_PER_LEAD)
    trail = within + 0x40
    if trail >= 0x7F:
        trail += 1
    return bytes((0xF0 + lead, trail))


def atlas_for(text: str) -> tuple[bytes, dict[str, bytes], list[dict[str, str]]]:
    chars = ordered_hangul([text])
    glyphs = common.parse_bdf(common.FONT_BDF, {ord(char) for char in chars})
    missing = [char for char in chars if ord(char) not in glyphs]
    if missing:
        raise RuntimeError(f"missing glyphs: {missing}")
    atlas = bytearray(bytes(32) * 3)  # dot, space, ellipsis reserved
    table: dict[str, bytes] = {}
    report: list[dict[str, str]] = []
    for index, char in enumerate(chars, start=3):
        glyph = common.glyph_1bpp_left_shifted(*glyphs[ord(char)])
        glyph = glyph[2:] + b"\0\0"  # proven UI baseline alignment
        table[char] = code(index)
        atlas.extend(glyph)
        report.append({"character": char, "code": table[char].hex(" ").upper(), "atlas": f"{ATLAS + index * 32:04X}"})
    return bytes(atlas), table, report


def make_loader() -> bytes:
    """Populate only $03/$04 from a private pool cursor; never alter $3471."""
    active, vlo, vhi, rlo, rhi = (STATE + i for i in range(5))
    a = common.Assembler(LOADER)
    a.abs(0xAD, active); a.branch(0xF0, "inactive")
    # Active stream: use virtual pointer, unless its FF has been reached.
    a.abs(0xAD, vlo); a.emit(0x85, 3)
    a.abs(0xAD, vhi); a.emit(0x85, 4)
    a.emit(0xA0, 0, 0xB1, 3, 0xC9, 0xFF); a.branch(0xD0, "done")
    # Let native parser consume the original marker terminator and finish UI.
    a.abs(0xAD, rlo); a.abs(0x8D, 0x3471); a.emit(0x85, 3)
    a.abs(0xAD, rhi); a.abs(0x8D, 0x3472); a.emit(0x85, 4)
    a.emit(0xA9, 0); a.abs(0x8D, active); a.branch(0x80, "done")
    a.label("inactive")
    a.abs(0xAD, 0x3471); a.emit(0x85, 3)
    a.abs(0xAD, 0x3472); a.emit(0x85, 4)
    # UI buffer normally begins with item index, followed by F7 40 FF.
    a.emit(0xA0, 1, 0xB1, 3, 0xC9, 0xF7); a.branch(0xD0, "done")
    a.emit(0xC8, 0xB1, 3, 0xC9, 0x40); a.branch(0xD0, "done")
    # Original terminator is source + 3: [item] F7 40 FF.
    a.emit(0xA5, 3, 0x18, 0x69, 3); a.abs(0x8D, rlo)
    a.emit(0xA5, 4, 0x69, 0); a.abs(0x8D, rhi)
    a.emit(0xA9, POOL & 0xFF); a.abs(0x8D, vlo); a.emit(0x85, 3)
    a.emit(0xA9, POOL >> 8); a.abs(0x8D, vhi); a.emit(0x85, 4)
    a.emit(0xA9, 1); a.abs(0x8D, active)
    a.label("done")
    a.emit(0x60)
    return a.finish()


def make_increment_proxy() -> bytes:
    """Exact pointer increment semantics, directed to virtual cursor if active."""
    active, vlo, vhi = STATE, STATE + 1, STATE + 2
    a = common.Assembler(PROXY)
    a.emit(0x48)  # PHA exactly as the replaced renderer sequences did
    a.abs(0xAD, active); a.branch(0xF0, "native")
    a.abs(0xAD, vlo); a.emit(0x18, 0x69, 1); a.abs(0x8D, vlo)
    a.abs(0xAD, vhi); a.emit(0x69, 0); a.abs(0x8D, vhi); a.branch(0x80, "return")
    a.label("native")
    a.abs(0xAD, 0x3471); a.emit(0x18, 0x69, 1); a.abs(0x8D, 0x3471)
    a.abs(0xAD, 0x3472); a.emit(0x69, 0); a.abs(0x8D, 0x3472)
    a.label("return"); a.emit(0x68, 0x60)
    return a.finish()


def make_wrapper() -> bytes:
    """Use the renderer's actual decoded code ($F8/$F9), not global cursor."""
    a = common.Assembler(WRAPPER)
    a.emit(0xA5, 0xF9, 0xC9, 0xF0); a.branch(0x90, "native")
    a.emit(0xC9, 0xF7); a.branch(0xB0, "native")
    a.emit(0x85, 2, 0xA5, 0xF8, 0x38, 0xE9, 0x40)
    a.emit(0xC9, 0x40); a.branch(0x90, "trail")
    a.emit(0x3A)
    a.label("trail"); a.emit(0xC9, SLOTS_PER_LEAD); a.branch(0xB0, "native")
    a.emit(0x85, 3, 0xA5, 2, 0x38, 0xE9, 0xF0, 0xAA, 0xA5, 3)
    a.label("lead_loop"); a.emit(0xE0, 0); a.branch(0xF0, "index")
    a.emit(0x18, 0x69, SLOTS_PER_LEAD, 0xCA); a.branch(0x80, "lead_loop")
    a.label("index")
    a.emit(0x85, 2, 0x48, 0x4A, 0x4A, 0x4A, 0x18, 0x69, ATLAS >> 8, 0x85, 1, 0x68)
    a.emit(0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x18, 0x69, ATLAS & 0xFF, 0x85, 0)
    a.branch(0x90, "copy"); a.emit(0xE6, 1)
    a.label("copy"); a.emit(0x82); a.abs(0x20, 0x69FC); a.emit(0x62, 0x60)
    a.label("native"); a.abs(0x20, 0x69C2); a.emit(0x60)
    return a.finish()


def build(force: bool) -> Path:
    out = OUTROOT / VERSION
    if out.exists():
        if not force:
            raise RuntimeError(f"already exists: {out}")
        shutil.rmtree(out)
    out.mkdir(parents=True)
    if sha(SOURCE02) != common.EXPECTED_SOURCE_SHA256 or sha(SOURCE24) != track24.EXPECTED_TRACK24_SHA256:
        raise RuntimeError("source checksum mismatch")
    row = ui_row()
    old = row["jp_text"].encode("cp932") + b"\xFF"
    if len(old) < 4:
        raise RuntimeError("source record cannot hold [index] F7 40 FF")
    atlas, table, glyph_report = atlas_for(row["ko_text"])
    korean = encode_game_text(row["ko_text"], table)
    loader, proxy, wrapper = make_loader(), make_increment_proxy(), make_wrapper()
    if LOADER + len(loader) > ATLAS or ATLAS + len(atlas) > POOL or POOL + len(korean) > PROXY or PROXY + len(proxy) > STATE:
        raise RuntimeError("Track-02 cave layout overflow")
    patches = [
        common.Patch("ui015_loader", common.bank68_iso(LOADER), b"\xFF" * len(loader), loader, LOADER),
        common.Patch("ui015_atlas", common.bank68_iso(ATLAS), b"\xFF" * len(atlas), atlas, ATLAS),
        common.Patch("ui015_pool", common.bank68_iso(POOL), b"\xFF" * len(korean), korean, POOL),
        common.Patch("ui015_proxy", common.bank68_iso(PROXY), b"\xFF" * len(proxy), proxy, PROXY),
        common.Patch("ui015_state", common.bank68_iso(STATE), b"\xFF" * 5, b"\0" * 5, STATE),
        common.Patch("ui015_wrapper", common.bank6a_iso(WRAPPER), b"\xFF" * len(wrapper), wrapper, WRAPPER),
        common.Patch("ui015_fontcall", common.bank6a_iso(FONT_CALL), FONT_CALL_OLD, bytes((0x20, WRAPPER & 0xFF, WRAPPER >> 8)), FONT_CALL),
        common.Patch("ui015_entry", common.bank6a_iso(ENTRY), ENTRY_OLD, bytes((0x20, LOADER & 0xFF, LOADER >> 8)) + b"\xEA" * 7, ENTRY),
    ]
    # Replace the complete PHA ... PLA increment sequence (19 bytes).  The
    # following JMP/continuation remains untouched.  Truncating this by two
    # bytes leaves half of STA $3472 behind and immediately corrupts code.
    for site in INC_SITES:
        old_inc = stream.read_user_bytes(SOURCE02, common.bank6a_iso(site), 19)
        patches.append(common.Patch(f"ui015_increment_{site:04X}", common.bank6a_iso(site), old_inc, bytes((0x20, PROXY & 0xFF, PROXY >> 8)) + b"\xEA" * 16, site))
    marker = bytes((0xF7, 0x40, 0xFF)).ljust(len(old), b"\xFF")
    for number, offset in enumerate(offsets(row["all_disc_offsets"]), 1):
        patches.append(common.Patch(f"{UI_ID}_{number}", offset, old, marker))
    for patch in patches:
        if stream.read_user_bytes(SOURCE02, patch.iso_offset, len(patch.old)) != patch.old:
            raise RuntimeError(f"preflight mismatch: {patch.name}")
    out02 = out / f"Snatcher CD-ROMantic (Japan) (Track 02) [{VERSION}].bin"
    changed = stream.apply_patches_streaming(SOURCE02, out02, patches)
    out24 = out / f"Snatcher CD-ROMantic (Japan) (Track 24) [{VERSION}].bin"
    shutil.copyfile(SOURCE24, out24)
    cue = out / f"Snatcher CD-ROMantic (Japan) [{VERSION}].cue"
    track24.stage_cue(cue, out02, out24)
    (out / "manifest.json").write_text(json.dumps({"version": VERSION, "ui": UI_ID, "jp": row["jp_text"], "ko": row["ko_text"], "model": "separate_virtual_cursor", "atlas_bytes": len(atlas), "pool_bytes": len(korean), "loader_bytes": len(loader), "increment_proxy_bytes": len(proxy), "wrapper_bytes": len(wrapper), "sectors": sorted(f"{sector:06X}" for sector in changed), "glyphs": glyph_report}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (out / "TEST_IN_MESEN.txt").write_text("Power-cycle after opening the CUE. Test only UI0006: 안으로 들어간다.\nOpen the menu, move selection repeatedly, choose it, and confirm the following dialogue advances.\n", encoding="utf-8-sig")
    return out


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true")
    print(build(parser.parse_args().force))
