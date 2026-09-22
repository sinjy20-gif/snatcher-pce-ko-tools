#!/usr/bin/env python3
"""Four independently-addressed Korean action-menu labels without Card-RAM mapping.

This isolates the F7 marker/renderer route from the failed Card-RAM pool
experiment. Code, a tiny glyph atlas, and redirected UI strings all live in
the verified unused Track-02 code cave of the normal MPR2 bank.
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
OUTROOT = ROOT / "build" / "patch"
STATIC = ROOT / "extraction" / "patch" / "static"
TRANS = ROOT / "extraction" / "translation"
sys.path[:0] = [str(STATIC), str(TRANS)]

import build_disc_patch as common
import build_speaker_ui_proof as stream
import build_track24_loader_proof as track24
from game_text_codec import encode_game_text, ordered_hangul

UI_TSV = ROOT / "snatcher_tool" / "translation" / "ui_text.tsv"
# UI-only test builds use a simple sequential name.  Keep unrelated POC
# artifacts separate so the user can identify the exact menu test at a glance.
VERSION = "UI 0.1.9"
# One verified reception action-menu record only. These four records are
# contiguous and have the menu's 00..03 item index immediately before them.
# Do not use all_disc_offsets: the same words also occur in unrelated script
# data where that item-index invariant does not exist.
UI_IDS = ("UI0006", "UI0002", "UI0003", "UI0004")
TEST_OFFSETS = {
    "UI0006": (0x0DB870,),
    "UI0002": (0x0DB879,),
    "UI0003": (0x0DB883,),
    "UI0004": (0x0DB88B,),
}
UI_ID = "UI0006"  # 中に入る -> 안으로 들어간다

FONT_CALL = 0x648C
FONT_CALL_OLD = bytes((0x20, 0xC2, 0x69))
ENTRY = 0x66E5
ENTRY_OLD = bytes.fromhex("AD 71 34 85 03 AD 72 34 85 04")
LOADER = common.CAVE_CPU_START
ATLAS = 0x5D00
POOL = 0x5F00
CAVE_END = 0x6000
WRAPPER = 0x7F50
WRAPPER_END = 0x8000
SLOTS_PER_LEAD = 188


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest().upper()


def read_ui() -> list[dict[str, str]]:
    with UI_TSV.open("r", encoding="utf-16", newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    matches = [r for r in rows if r.get("ui_id") in UI_IDS and r.get("status") in {"review", "final"}]
    by_id = {r["ui_id"]: r for r in matches}
    missing = [ui_id for ui_id in UI_IDS if ui_id not in by_id]
    if missing:
        raise RuntimeError(f"missing reviewed UI rows: {', '.join(missing)}")
    return [by_id[ui_id] for ui_id in UI_IDS]


def parse_offsets(raw: str) -> list[int]:
    return [int(item.strip(), 16) for item in raw.split(",") if item.strip()]


def custom_code(index: int) -> bytes:
    # F7 is deliberately unallocated: it is our private pool marker.
    if not 0 <= index < SLOTS_PER_LEAD * 7:
        raise RuntimeError("too many inline POC glyphs")
    lead, within = divmod(index, SLOTS_PER_LEAD)
    trail = within + 0x40
    if trail >= 0x7F:
        trail += 1
    return bytes((0xF0 + lead, trail))


def make_atlas(texts: list[str]) -> tuple[bytes, dict[str, bytes], list[dict[str, str]]]:
    chars = ordered_hangul(texts)
    found = common.parse_bdf(common.FONT_BDF, {ord(c) for c in chars})
    missing = [c for c in chars if ord(c) not in found]
    if missing:
        raise RuntimeError(f"missing glyphs: {missing}")
    period = bytes(22) + bytes((0x0C, 0x00, 0x0C, 0x00)) + bytes(6)
    blank = bytes(32)
    ellipsis = bytes(22) + bytes((0x22, 0x20, 0x22, 0x20)) + bytes(6)
    atlas = bytearray(period + blank + ellipsis)
    custom: dict[str, bytes] = {}
    report: list[dict[str, str]] = []
    for index, char in enumerate(chars, start=3):
        glyph = common.glyph_1bpp_left_shifted(*found[ord(char)])
        glyph = glyph[2:] + b"\0\0"  # UI baseline is one scanline higher.
        custom[char] = custom_code(index)
        atlas.extend(glyph)
        report.append({"character": char, "game_code": custom[char].hex().upper(), "atlas_cpu": f"{ATLAS + index * 32:04X}"})
    return bytes(atlas), custom, report


def make_loader(pool_offsets: list[int]) -> bytes:
    """Redirect one marker, then restore the original UI cursor at its FF."""
    a = common.Assembler(LOADER)
    # The renderer's X and Y are live.  The earlier multi-marker POC changed
    # both; preserve them before reading the menu header/item byte.
    a.emit(0xDA, 0x5A)  # PHX, PHY
    a.abs(0xAD, 0x3471); a.emit(0x85, 3)
    a.abs(0xAD, 0x3472); a.emit(0x85, 4)
    # While drawing a Korean pool string the game still advances $3471/$3472.
    # When it reaches that pool string's FF, put the original marker's FF back
    # before the normal renderer consumes it.  This lets the UI state machine
    # finish its own string normally instead of retaining a cave pointer.
    a.abs(0xAD, "active"); a.branch(0xF0, "check_marker")
    a.emit(0xA5, 4, 0xC9, POOL >> 8); a.branch(0xD0, "check_marker")
    a.emit(0xA0, 0x00, 0xB1, 3, 0xC9, 0xFF); a.branch(0xD0, "check_marker")
    a.abs(0xAD, "resume_lo"); a.abs(0x8D, 0x3471); a.emit(0x85, 3)
    a.abs(0xAD, "resume_hi"); a.abs(0x8D, 0x3472); a.emit(0x85, 4)
    a.emit(0xA9, 0x00); a.abs(0x8D, "active")
    a.abs(0x4C, "done")
    a.label("check_marker")
    a.emit(0xA5, 4, 0xC9, 0x34); a.branch(0xD0, "done")
    a.emit(0xA0, 0x00, 0xB1, 3, 0xC9, 0xF7); a.branch(0xD0, "done")
    a.emit(0xC8, 0xB1, 3, 0xC9, 0x40); a.branch(0xD0, "done")
    # The UI buffer layout is [item-index] F7 40 FF and $3471/$3472 points
    # at the item index.  Save the actual original terminator (source + 3),
    # not the F7 trail byte at source + 2.
    a.emit(0xA5, 3, 0x18, 0x69, 0x03); a.abs(0x8D, "resume_lo")
    a.emit(0xA5, 4, 0x69, 0x00); a.abs(0x8D, "resume_hi")
    a.emit(0xA9, 0x01); a.abs(0x8D, "active")
    # $3498 is the original UI item's index (00..03) immediately before its
    # text pointer at $3499.  Indexed-indirect adds Y (so Y=$FF would mean
    # pointer+255, not pointer-1); decrement the scratch pointer instead.
    a.emit(0xC6, 3)  # DEC $03
    a.branch(0xD0, "item_pointer_ready")
    a.emit(0xC6, 4)  # borrow into $04 (not expected for UI $3499, but safe)
    a.label("item_pointer_ready")
    a.emit(0xA0, 0x00, 0xB1, 3)
    a.emit(0xC9, len(pool_offsets)); a.branch(0xB0, "done")
    a.emit(0x0A, 0xAA)  # index * 2 -> X
    a.abs(0xBD, "pointer_table"); a.abs(0x8D, 0x3471)
    a.emit(0xE8)
    a.abs(0xBD, "pointer_table"); a.abs(0x8D, 0x3472)
    a.label("done")
    a.abs(0xAD, 0x3471); a.emit(0x85, 3)
    a.abs(0xAD, 0x3472); a.emit(0x85, 4, 0x7A, 0xFA, 0x60)  # PLY, PLX, RTS
    a.label("pointer_table")
    for offset in pool_offsets:
        a.emit((POOL + offset) & 0xFF)
        a.emit((POOL + offset) >> 8)
    a.label("resume_lo"); a.emit(0x00)
    a.label("resume_hi"); a.emit(0x00)
    a.label("active"); a.emit(0x00)
    return a.finish()


def make_wrapper() -> bytes:
    """Read F0-F6 atlas glyphs directly from the same stable MPR2 bank."""
    a = common.Assembler(WRAPPER)
    a.abs(0xAD, 0x3471); a.emit(0x38, 0xE9, 1, 0x85, 0)
    a.abs(0xAD, 0x3472); a.emit(0xE9, 0, 0x85, 1)
    a.emit(0xA0, 0, 0xB1, 0, 0xC9, 0xF0); a.branch(0x90, "native")
    a.emit(0xC9, 0xF7); a.branch(0xB0, "native")
    a.emit(0x85, 2, 0xC8, 0xB1, 0, 0x38, 0xE9, 0x40)
    a.emit(0xC9, 0x40); a.branch(0x90, "trail_ok")
    a.emit(0x3A)
    a.label("trail_ok")
    a.emit(0xC9, SLOTS_PER_LEAD); a.branch(0xB0, "native")
    a.emit(0x85, 3, 0xA5, 2, 0x38, 0xE9, 0xF0, 0xAA, 0xA5, 3)
    a.label("lead_loop"); a.emit(0xE0, 0); a.branch(0xF0, "index_done")
    a.emit(0x18, 0x69, SLOTS_PER_LEAD, 0xCA); a.branch(0x80, "lead_loop")
    a.label("index_done")
    # $00/$01 = ATLAS + (index * 32), with carry from the low byte preserved.
    a.emit(0x85, 2, 0x48, 0x4A, 0x4A, 0x4A, 0x18, 0x69, ATLAS >> 8, 0x85, 1, 0x68)
    a.emit(0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x18, 0x69, ATLAS & 0xFF, 0x85, 0)
    a.branch(0x90, "source_ready"); a.emit(0xE6, 1)
    a.label("source_ready"); a.abs(0x20, 0x69FC); a.emit(0x62, 0x60)
    a.label("native"); a.abs(0x20, 0x69C2); a.emit(0x60)
    return a.finish()


def build(force: bool) -> Path:
    out = OUTROOT / VERSION
    if out.exists():
        if not force:
            raise RuntimeError(f"exists: {out}")
        shutil.rmtree(out)
    out.mkdir(parents=True)
    if sha(SOURCE02) != common.EXPECTED_SOURCE_SHA256:
        raise RuntimeError("unexpected Track 02")
    if sha(SOURCE24) != track24.EXPECTED_TRACK24_SHA256:
        raise RuntimeError("unexpected Track 24")
    rows = read_ui()
    atlas, custom, glyphs = make_atlas([row["ko_text"] for row in rows])
    encoded_rows = [encode_game_text(row["ko_text"], custom) for row in rows]
    pool_offsets: list[int] = []
    encoded = bytearray()
    for item in encoded_rows:
        pool_offsets.append(len(encoded))
        encoded.extend(item)
    loader, wrapper = make_loader(pool_offsets), make_wrapper()
    if LOADER + len(loader) > ATLAS or ATLAS + len(atlas) > POOL or POOL + len(encoded) > CAVE_END:
        raise RuntimeError("inline cave layout overflow")
    patches = [
        common.Patch("inline_loader", common.bank68_iso(LOADER), b"\xFF" * len(loader), loader, LOADER),
        common.Patch("inline_atlas", common.bank68_iso(ATLAS), b"\xFF" * len(atlas), atlas, ATLAS),
        common.Patch("inline_pool", common.bank68_iso(POOL), b"\xFF" * len(encoded), encoded, POOL),
        common.Patch("inline_wrapper", common.bank6a_iso(WRAPPER), b"\xFF" * len(wrapper), wrapper, WRAPPER),
        common.Patch("font_call", common.bank6a_iso(FONT_CALL), FONT_CALL_OLD, bytes((0x20, WRAPPER & 0xFF, WRAPPER >> 8)), FONT_CALL),
        common.Patch("renderer_entry", common.bank6a_iso(ENTRY), ENTRY_OLD, bytes((0x20, LOADER & 0xFF, LOADER >> 8)) + b"\xEA" * 7, ENTRY),
    ]
    for marker_id, row in enumerate(rows):
        old = row["jp_text"].encode("cp932") + b"\xFF"
        if len(old) < 3:
            raise RuntimeError(f"source slot too short for {row['ui_id']}")
        # F7 41..43 are not inert in every UI path.  Use the one verified
        # safe marker for all four labels; make_loader dispatches via $3498.
        marker = bytes((0xF7, 0x40, 0xFF)).ljust(len(old), b"\xFF")
        for number, offset in enumerate(TEST_OFFSETS[row["ui_id"]], 1):
            patches.append(common.Patch(f"{row['ui_id']}_{number}", offset, old, marker))
    for patch in patches:
        actual = stream.read_user_bytes(SOURCE02, patch.iso_offset, len(patch.old))
        if actual != patch.old:
            raise RuntimeError(f"preflight mismatch: {patch.name}")
    out02 = out / f"Snatcher CD-ROMantic (Japan) (Track 02) [{VERSION}].bin"
    modified = stream.apply_patches_streaming(SOURCE02, out02, patches)
    out24 = out / f"Snatcher CD-ROMantic (Japan) (Track 24) [{VERSION}].bin"
    shutil.copyfile(SOURCE24, out24)
    cue = out / f"Snatcher CD-ROMantic (Japan) [{VERSION}].cue"
    track24.stage_cue(cue, out02, out24)
    (out / "glyph_map.json").write_text(json.dumps(glyphs, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (out / "TEST_IN_MESEN.txt").write_text(
        "Power-cycle after loading the CUE. Test the four primary action-menu items without a freeze.\n"
        "Expected Korean: 보다 / 조사하다 / 묻다 / 대화하다.\n"
        "This build deliberately has no Card-RAM string mapping and patches no other UI/speakers.\n",
        encoding="utf-8-sig",
    )
    (out / "manifest.json").write_text(json.dumps({"version": VERSION, "ui": [{"ui_id": row["ui_id"], "jp": row["jp_text"], "ko": row["ko_text"], "marker": "F7 40 FF", "menu_item": index} for index, row in enumerate(rows)], "atlas_bytes": len(atlas), "pool_bytes": len(encoded), "loader_bytes": len(loader), "wrapper_bytes": len(wrapper), "modified_sectors": sorted(f"{n:06X}" for n in modified)}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return out


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    print(build(args.force))
