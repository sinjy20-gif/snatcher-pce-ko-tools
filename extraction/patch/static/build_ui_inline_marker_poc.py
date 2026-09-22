#!/usr/bin/env python3
"""One long Korean UI label without any Card-RAM bank mapping.

This isolates the F7 marker/renderer route from the failed Card-RAM pool
experiment.  Code, a tiny glyph atlas, and one redirected UI string all live
in the verified unused $5E40-$5FFF area of the normal MPR2 bank.
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
VERSION = "ui-inline-ui0003-single-marker-poc-v1"
UI_ID = "UI0003"  # 聞く -> 묻다

FONT_CALL = 0x648C
FONT_CALL_OLD = bytes((0x20, 0xC2, 0x69))
ENTRY = 0x66E5
ENTRY_OLD = bytes.fromhex("AD 71 34 85 03 AD 72 34 85 04")
LOADER = 0x5E40
ATLAS = 0x5E80
POOL = 0x5FC0
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


def read_ui() -> dict[str, str]:
    with UI_TSV.open("r", encoding="utf-16", newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    matches = [r for r in rows if r.get("ui_id") == UI_ID and r.get("status") in {"review", "final"}]
    if len(matches) != 1:
        raise RuntimeError(f"expected one reviewed {UI_ID} row, found {len(matches)}")
    return matches[0]


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


def make_atlas(text: str) -> tuple[bytes, dict[str, bytes], list[dict[str, str]]]:
    chars = ordered_hangul([text])
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


def make_loader() -> bytes:
    """Redirect only UI buffer F7 40 FF to the inline pool at $5FC0."""
    a = common.Assembler(LOADER)
    a.abs(0xAD, 0x3471); a.emit(0x85, 3)
    a.abs(0xAD, 0x3472); a.emit(0x85, 4)
    a.emit(0xA5, 4, 0xC9, 0x34); a.branch(0xD0, "done")
    a.emit(0xA0, 0x00, 0xB1, 3, 0xC9, 0xF7); a.branch(0xD0, "done")
    a.emit(0xC8, 0xB1, 3, 0xC9, 0x40); a.branch(0xD0, "done")
    a.emit(0xA9, POOL & 0xFF); a.abs(0x8D, 0x3471)
    a.emit(0xA9, POOL >> 8); a.abs(0x8D, 0x3472)
    a.label("done")
    a.abs(0xAD, 0x3471); a.emit(0x85, 3)
    a.abs(0xAD, 0x3472); a.emit(0x85, 4, 0x60)
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
    row = read_ui()
    old = row["jp_text"].encode("cp932") + b"\xFF"
    if len(old) < 3:
        raise RuntimeError("source slot too short for F7 marker")
    atlas, custom, glyphs = make_atlas(row["ko_text"])
    encoded = encode_game_text(row["ko_text"], custom)
    if len(encoded) > 0x40:
        raise RuntimeError("inline pool overflow")
    loader, wrapper = make_loader(), make_wrapper()
    if LOADER + len(loader) > ATLAS or ATLAS + len(atlas) > POOL or POOL + len(encoded) > CAVE_END:
        raise RuntimeError("inline cave layout overflow")
    marker = bytes((0xF7, 0x40, 0xFF)).ljust(len(old), b"\xFF")
    patches = [
        common.Patch("inline_loader", common.bank68_iso(LOADER), b"\xFF" * len(loader), loader, LOADER),
        common.Patch("inline_atlas", common.bank68_iso(ATLAS), b"\xFF" * len(atlas), atlas, ATLAS),
        common.Patch("inline_pool", common.bank68_iso(POOL), b"\xFF" * len(encoded), encoded, POOL),
        common.Patch("inline_wrapper", common.bank6a_iso(WRAPPER), b"\xFF" * len(wrapper), wrapper, WRAPPER),
        common.Patch("font_call", common.bank6a_iso(FONT_CALL), FONT_CALL_OLD, bytes((0x20, WRAPPER & 0xFF, WRAPPER >> 8)), FONT_CALL),
        common.Patch("renderer_entry", common.bank6a_iso(ENTRY), ENTRY_OLD, bytes((0x20, LOADER & 0xFF, LOADER >> 8)) + b"\xEA" * 7, ENTRY),
    ]
    for number, offset in enumerate(parse_offsets(row["all_disc_offsets"]), 1):
        patches.append(common.Patch(f"{UI_ID}_{number}", offset, old, marker))
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
        "Power-cycle after loading the CUE. Test only UI0003 (聞く -> 묻다) without a freeze.\n"
        "This build deliberately has no Card-RAM string mapping and patches no other UI/speakers.\n",
        encoding="utf-8-sig",
    )
    (out / "manifest.json").write_text(json.dumps({"version": VERSION, "ui_id": UI_ID, "jp": row["jp_text"], "ko": row["ko_text"], "marker": "F7 40 FF", "atlas_bytes": len(atlas), "pool_bytes": len(encoded), "loader_bytes": len(loader), "wrapper_bytes": len(wrapper), "modified_sectors": sorted(f"{n:06X}" for n in modified)}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return out


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    print(build(args.force))
