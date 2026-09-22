#!/usr/bin/env python3
"""Build the full static UI/speaker Card-RAM font-cache proof.

Unlike the earlier two-glyph proof, this packs every currently reviewed UI
label and speaker name into a Track-24 atlas, loads it once into Card-RAM
bank $6B, and maps that bank only while the native renderer copies a glyph.
UI and speaker glyphs are intentionally rendered one scanline higher.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
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

# The portable Studio owns the live editing tables.  Do not silently fall back
# to the historical root-level TSVs: a build must consume exactly what the
# user sees and edits in SnatcherTranslationStudio.
STUDIO_TRANSLATION = ROOT / "snatcher_tool" / "translation"
UI_TSV = STUDIO_TRANSLATION / "ui_text.tsv"
SPEAKER_TSV = STUDIO_TRANSLATION / "speaker_name_standard.tsv"
VERSION_DEFAULT = "ui-speaker-cardram-cache-poc-v1"

FONT_CALL = 0x648C
FONT_CALL_OLD = bytes((0x20, 0xC2, 0x69))
ENTRY = 0x66E5
ENTRY_OLD = bytes.fromhex("AD 71 34 85 03 AD 72 34 85 04")
LOADER, LOADER_END = 0x5E40, 0x6000
WRAPPER, WRAPPER_END = 0x7F50, 0x8000
CACHE_BANK, CACHE_CPU = 0x6B, 0x8000
FLAG, STATUS, POOL_ACTIVE, SAVED_MPR2, MAGIC = 0x5C60, 0x5C61, 0x5C62, 0x5C63, 0xA5
CD_BASE, CD_READ = 0xE006, 0xE009
SLOTS_PER_LEAD = len(tuple(range(0x40, 0x7F))) + len(tuple(range(0x80, 0xFD)))
POOL_SLOT_BYTES = 32
MAX_UI_CELLS = 8


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-16", newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def write_tsv(path: Path, rows: list[dict[str, str]]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8-sig")
        return
    fields = list(rows[0])
    for row in rows:
        for field in row:
            if field not in fields:
                fields.append(field)
    with path.open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, delimiter="\t", lineterminator="\n")
        w.writeheader(); w.writerows(rows)


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest().upper()


def code(index: int) -> bytes:
    """Return a parser-safe F0-F6 custom code; reserve F7 for pool markers."""
    # F7 must never be allocated to an atlas glyph.  The Card-RAM string
    # dispatcher uses F7 xx as its private marker, while F8-FE belong to the
    # game's own control-code range.
    if not 0 <= index < SLOTS_PER_LEAD * 7:
        raise RuntimeError(f"atlas glyph index out of range: {index}")
    lead, within = divmod(index, SLOTS_PER_LEAD)
    trail = within + 0x40
    if trail >= 0x7F:
        trail += 1
    return bytes((0xF0 + lead, trail))


def parse_offsets(raw: str) -> list[int]:
    """Read UI offsets, including the one legacy row with thousands commas."""
    parts = [p.strip() for p in raw.split(",") if p.strip()]
    if parts and all(re.fullmatch(r"[0-9A-Fa-f]{3}", p) for p in parts):
        if len(parts) % 2:
            raise RuntimeError(f"odd 3-digit UI offset list: {raw!r}")
        parts = [parts[i] + parts[i + 1] for i in range(0, len(parts), 2)]
    if not all(re.fullmatch(r"[0-9A-Fa-f]{5,6}", p) for p in parts):
        raise RuntimeError(f"invalid UI offset list: {raw!r}")
    return [int(p, 16) for p in parts]


def shift_up(glyph: bytes) -> bytes:
    return glyph[2:] + b"\0\0"


def make_atlas(ui_rows: list[dict[str, str]], speakers: list[dict[str, str]]):
    # The main runtime owns F040/F041/F042.  Static UI uses F043 onward,
    # avoiding any dependency on the main dialogue's font bank.
    chars = ordered_hangul([r["ko_text"] for r in ui_rows] + [r["ko_name"] for r in speakers])
    found = common.parse_bdf(common.FONT_BDF, {ord(c) for c in chars})
    missing = [c for c in chars if ord(c) not in found]
    if missing:
        raise RuntimeError(f"Galmuri glyphs missing: {missing}")
    # Keep the codec-reserved punctuation usable in this isolated atlas too.
    # All three are lifted one scanline, like the UI/speaker Hangul glyphs.
    period = bytes(22) + bytes((0x0C, 0x00, 0x0C, 0x00)) + bytes(6)
    blank = bytes(32)
    ellipsis = bytes(22) + bytes((0x22, 0x20, 0x22, 0x20)) + bytes(6)
    atlas = bytearray(period + blank + ellipsis)  # F040/F041/F042
    custom: dict[str, bytes] = {}
    rows: list[dict[str, str]] = []
    for index, char in enumerate(chars, start=3):
        glyph = common.glyph_1bpp_left_shifted(*found[ord(char)])
        custom[char] = code(index)
        atlas.extend(shift_up(glyph))
        rows.append({"index": str(index), "game_code": code(index).hex().upper(),
                     "character": char, "font_offset": f"{index * 32:04X}",
                     "render_y_shift": "-1"})
    if len(atlas) > 0x2000:
        raise RuntimeError(f"atlas {len(atlas)} bytes exceeds one Card-RAM bank")
    return bytes(atlas), custom, rows


def visible_cells(text: str) -> int:
    """The UI line budget: controls do not occupy a visible cell; … is one."""
    clean = re.sub(r"\{(?:FE:[0-4]|EMPTY)\}", "", text)
    return len(clean.replace("...", "…"))


def build_string_pool(
    ui_rows: list[dict[str, str]],
    speakers: list[dict[str, str]],
    custom: dict[str, bytes],
) -> tuple[bytes, dict[str, int], dict[str, int], list[dict[str, str]]]:
    """Build fixed-size long-string slots for records that cannot fit in place.

    The original short UI record becomes ``F7 + index + FF``.  F7 is reserved
    by this patch and is parser-safe; F8-FE are game control commands.  The
    loader recognises those markers only in the UI/speaker buffers
    and redirects the normal renderer to this pool.  Fixed slots keep the
    in-game dispatcher tiny and deterministic.
    """
    pool = bytearray()
    ui_slots: dict[str, int] = {}
    speaker_slots: dict[str, int] = {}
    report: list[dict[str, str]] = []

    def add_slot(kind: str, ident: str, text: str, slots: dict[str, int]) -> None:
        cells = visible_cells(text)
        if cells > MAX_UI_CELLS:
            report.append({"kind": kind, "id": ident, "result": "SKIPPED_OVER_8_CELLS",
                           "cells": str(cells)})
            return
        encoded = encode_game_text(text, custom)
        if len(encoded) + 1 > POOL_SLOT_BYTES:
            report.append({"kind": kind, "id": ident, "result": "SKIPPED_POOL_SLOT_OVERFLOW",
                           "cells": str(cells)})
            return
        index = len(pool) // POOL_SLOT_BYTES
        if index >= 0x3F:
            raise RuntimeError("UI/speaker string-pool marker range exhausted")
        slots[ident] = index
        pool.extend((encoded + b"\xFF").ljust(POOL_SLOT_BYTES, b"\xFF"))
        report.append({"kind": kind, "id": ident, "result": "POOLED",
                       "cells": str(cells), "slot": str(index)})

    for row in ui_rows:
        old = row["jp_text"].encode("cp932") + b"\xFF"
        encoded = encode_game_text(row["ko_text"], custom)
        if fit(encoded, old, row["ui_id"]) is None:
            add_slot("ui", row["ui_id"], row["ko_text"], ui_slots)
    for row in speakers:
        old = row["jp_name"].encode("cp932") + b"\xFF"
        encoded = encode_game_text(row["ko_name"], custom)
        if fit(encoded, old, f"speaker {row['speaker_id']}") is None:
            add_slot("speaker", row["speaker_id"], row["ko_name"], speaker_slots)
    return bytes(pool), ui_slots, speaker_slots, report


def set_base(a: common.Assembler, lba: int) -> None:
    for zp, val in ((0xF8,lba>>16),(0xF9,lba>>8),(0xFA,lba),(0xFB,0),(0xFC,1)):
        a.emit(0xA9, val & 0xFF, 0x85, zp)
    a.abs(0x20, CD_BASE)


def read_sector(a: common.Assembler, relative: int, dest: int, tag: str) -> None:
    for zp, val in ((0xF8,0),(0xF9,8),(0xFA,dest),(0xFB,dest>>8),
                    (0xFC,relative>>16),(0xFD,relative>>8),(0xFE,relative),(0xFF,0)):
        a.emit(0xA9, val & 0xFF, 0x85, zp)
    a.abs(0x20, CD_READ); a.abs(0x8D, STATUS)
    a.branch(0xD0, tag)


def make_loader(
    t24base: int, t02base: int, relative: int, sectors: int,
    pool_base: int, ui_pool_count: int, speaker_pool_count: int,
) -> bytes:
    a = common.Assembler(LOADER)
    a.emit(0xDA,0x5A)
    for zp in range(0xF8,0x100): a.emit(0xA5,zp,0x48)
    # The full atlas makes `restore` farther than a relative branch permits.
    a.abs(0xAD,FLAG); a.emit(0xC9,MAGIC); a.branch(0xD0,"load")
    a.abs(0x4C,"restore")
    a.label("load")
    a.emit(0x43,0x10,0x48,0xA9,CACHE_BANK,0x53,0x10)
    set_base(a,t24base)
    for i in range(sectors): read_sector(a,relative+i,CACHE_CPU+i*0x800,"restore_mpr")
    a.emit(0xA9,MAGIC); a.abs(0x8D,FLAG)
    a.label("restore_mpr"); a.emit(0x68,0x53,0x10); set_base(a,t02base)
    a.label("restore")
    # The original renderer keeps fetching a character over several calls.
    # Keep MPR2 on the pool while that stream is active, then restore it when
    # the next normal UI/speaker buffer begins.
    a.abs(0xAD, 0x3471); a.emit(0x85, 3)
    a.abs(0xAD, 0x3472); a.emit(0x85, 4)
    a.abs(0xAD, POOL_ACTIVE); a.branch(0xF0, "check_marker")
    a.emit(0xA5, 4, 0xC9, 0x40); a.branch(0xF0, "done_dispatch")
    a.abs(0xAD, SAVED_MPR2); a.emit(0x53, 0x04, 0x9C, POOL_ACTIVE)

    a.label("check_marker")
    # Only the two live text buffers can contain our markers: UI $34xx and
    # speaker names $36xx.  Narrative text elsewhere therefore remains raw.
    a.emit(0xA5, 4, 0xC9, 0x34); a.branch(0xF0, "read_marker")
    a.emit(0xC9, 0x36); a.branch(0xD0, "done_dispatch")
    a.label("read_marker")
    # F7 is a private pool marker.  Do not use F8-FE: those are game controls.
    a.emit(0xA0, 0x00, 0xB1, 3, 0xC9, 0xF7); a.branch(0xD0, "done_dispatch")
    # This first safe marker POC routes UI records only.  The speaker branch
    # is retained below for the later range-split implementation.
    a.abs(0x4C, "ui_marker")
    a.label("speaker_marker")
    a.emit(0xA0, 0x01, 0xB1, 3, 0x38, 0xE9, 0x40, 0xC9, speaker_pool_count)
    a.branch(0xB0, "done_dispatch"); a.emit(0x85, 2); a.abs(0x4C, "pool_pointer_speaker")
    a.label("ui_marker")
    a.emit(0xA0, 0x01, 0xB1, 3, 0x38, 0xE9, 0x40, 0xC9, ui_pool_count)
    a.branch(0xB0, "done_dispatch"); a.emit(0x85, 2)
    a.label("pool_pointer_ui")
    a.emit(0xA2, pool_base & 0xFF, 0xA9, pool_base >> 8)
    a.abs(0x4C, "pool_pointer_common")
    a.label("pool_pointer_speaker")
    a.emit(0xA2, (pool_base + ui_pool_count * POOL_SLOT_BYTES) & 0xFF,
           0xA9, (pool_base + ui_pool_count * POOL_SLOT_BYTES) >> 8)
    a.label("pool_pointer_common")
    # $02 = slot index, X/A = Card-RAM base address.  Add index * 32.
    a.emit(0x8A, 0x85, 3, 0x85, 4, 0xA6, 2)
    a.label("slot_loop")
    a.emit(0xE0, 0x00); a.branch(0xF0, "map_pool")
    a.emit(0x18, 0xA5, 3, 0x69, POOL_SLOT_BYTES, 0x85, 3,
           0xA5, 4, 0x69, 0x00, 0x85, 4, 0xCA)
    a.branch(0x80, "slot_loop")
    a.label("map_pool")
    a.emit(0x43, 0x04); a.abs(0x8D, SAVED_MPR2)
    a.emit(0xA9, CACHE_BANK, 0x53, 0x04)
    a.emit(0xA5, 3); a.abs(0x8D, 0x3471)
    a.emit(0xA5, 4, 0x18, 0x69, 0x40); a.abs(0x8D, 0x3472)
    a.emit(0xA9, MAGIC); a.abs(0x8D, POOL_ACTIVE)
    a.label("done_dispatch")
    for zp in reversed(range(0xF8,0x100)): a.emit(0x68,0x85,zp)
    a.emit(0xFA,0x7A)
    a.abs(0xAD,0x3471); a.emit(0x85,3); a.abs(0xAD,0x3472); a.emit(0x85,4,0x60)
    return a.finish()


def make_wrapper() -> bytes:
    """Copy F0-F7 atlas glyph through native $69FC, then restore MPR4."""
    a = common.Assembler(WRAPPER)
    a.abs(0xAD,0x3471); a.emit(0x38,0xE9,1,0x85,0)
    a.abs(0xAD,0x3472); a.emit(0xE9,0,0x85,1)
    a.emit(0xA0,0,0xB1,0,0xC9,0xF0); a.branch(0x90,"native")
    a.emit(0xC9,0xF8); a.branch(0xB0,"native")
    a.emit(0x85,2,0xC8,0xB1,0,0x38,0xE9,0x40)
    # `code()` skips the invalid trail byte $7F.  Undo that hole before
    # treating the trail as a linear atlas index (F080 represents index 63).
    a.emit(0xC9,0x40); a.branch(0x90,"trail_ok")
    a.emit(0x3A)  # DEC A
    a.label("trail_ok")
    a.emit(0xC9,SLOTS_PER_LEAD); a.branch(0xB0,"native")
    # $03 = trail index.  The high byte chooses a 188-character page:
    # index = (lead - $F0) * 188 + trail.  Keep this separate from the
    # trail; the old code accidentally used the trail as the page counter.
    a.emit(0x85,3,0xA5,2,0x38,0xE9,0xF0,0xAA,0xA5,3)
    a.label("lead_loop"); a.emit(0xE0,0x00); a.branch(0xF0,"index_done")
    a.emit(0x18,0x69,SLOTS_PER_LEAD,0xCA); a.branch(0x80,"lead_loop")
    a.label("index_done"); a.emit(0x85,2,0x48,0x4A,0x4A,0x4A,0x18,0x69,0x80,0x85,1,0x68)
    a.emit(0x0A,0x0A,0x0A,0x0A,0x0A,0x85,0)
    a.emit(0x43,0x10,0x48,0xA9,CACHE_BANK,0x53,0x10,0x82)
    a.abs(0x20,0x69FC); a.emit(0x68,0x53,0x10,0x62,0x60)
    a.label("native"); a.abs(0x20,0x69C2); a.emit(0x60)
    return a.finish()


def fit(encoded: bytes, old: bytes, label: str) -> bytes | None:
    if len(encoded) > len(old): return None
    return encoded + b"\xFF" * (len(old)-len(encoded))


def build(version: str, force: bool, only_ui: str | None = None, no_speakers: bool = False) -> Path:
    out = OUTROOT / version
    if out.exists():
        if not force: raise RuntimeError(f"exists: {out}")
        shutil.rmtree(out)
    out.mkdir(parents=True)
    if sha(SOURCE02) != common.EXPECTED_SOURCE_SHA256: raise RuntimeError("unexpected Track 02")
    if sha(SOURCE24) != track24.EXPECTED_TRACK24_SHA256: raise RuntimeError("unexpected Track 24")
    ui = [r for r in read_tsv(UI_TSV) if r.get("ko_text","").strip() and r.get("status") in {"review","final"}]
    if only_ui is not None:
        ui = [r for r in ui if r.get("ui_id") == only_ui]
        if len(ui) != 1:
            raise RuntimeError(f"expected exactly one reviewed UI row for {only_ui!r}, got {len(ui)}")
    speakers = [] if no_speakers else [r for r in read_tsv(SPEAKER_TSV) if r.get("ko_name","").strip() and r.get("status") in {"review","final"}]
    atlas, custom, map_rows = make_atlas(ui,speakers)
    pool, ui_slots, speaker_slots, pool_report = build_string_pool(ui, speakers, custom)
    pool_base = len(atlas)
    packed_data = atlas + pool
    if len(packed_data) > 0x2000:
        raise RuntimeError(f"atlas + string pool {len(packed_data)} bytes exceeds one Card-RAM bank")
    sectors = (len(packed_data)+2047)//2048
    starts,total = track24.disc_track_starts(); old24sectors=SOURCE24.stat().st_size//track24.RAW_SECTOR_SIZE
    first=starts[24]+old24sectors
    if first != total: raise RuntimeError("Track24 final-track check failed")
    t02base, t24base = starts[2]+225, starts[24]+225
    loader=make_loader(t24base,t02base,first-t24base,sectors,pool_base,len(ui_slots),len(speaker_slots)); wrapper=make_wrapper()
    if LOADER+len(loader)>LOADER_END: raise RuntimeError(f"loader {len(loader)} > cave {LOADER_END-LOADER}")
    if WRAPPER+len(wrapper)>WRAPPER_END: raise RuntimeError(f"wrapper {len(wrapper)} > cave {WRAPPER_END-WRAPPER}")
    patches=[common.Patch("ui_speaker_loader",common.bank68_iso(LOADER),b"\xFF"*len(loader),loader,LOADER),
             common.Patch("ui_speaker_wrapper",common.bank6a_iso(WRAPPER),b"\xFF"*len(wrapper),wrapper,WRAPPER),
             common.Patch("ui_speaker_fontcall",common.bank6a_iso(FONT_CALL),FONT_CALL_OLD,bytes((0x20,WRAPPER&255,WRAPPER>>8)),FONT_CALL),
             common.Patch("ui_speaker_entry",common.bank6a_iso(ENTRY),ENTRY_OLD,bytes((0x20,LOADER&255,LOADER>>8))+b"\xEA"*7,ENTRY),
             common.Patch("ui_speaker_state",common.bank68_iso(FLAG),b"\xFF\xFF\xFF\xFF",b"\0\xFF\0\xFF",FLAG)]
    report=[]; seen={}
    def add(name,off,old,new,kind):
        if new is None: report.append({"kind":kind,"id":name,"result":"SKIPPED_TOO_LONG","offset":f"{off:06X}"}); return
        prior=seen.get(off)
        if prior and (prior[0]!=old or prior[1]!=new): raise RuntimeError(f"overlapping static patches at {off:06X}: {name}")
        if not prior: patches.append(common.Patch(name,off,old,new)); seen[off]=(old,new)
        report.append({"kind":kind,"id":name,"result":"PATCHED","offset":f"{off:06X}"})
    pool_status = {r["id"]: r for r in pool_report}
    for r in ui:
        old=r["jp_text"].encode("cp932")+b"\xFF"; new=fit(encode_game_text(r["ko_text"],custom),old,r["ui_id"])
        if new is None:
            state = pool_status.get(r["ui_id"], {})
            if state.get("result") == "POOLED":
                new = bytes((0xF7, 0x40 + ui_slots[r["ui_id"]], 0xFF)).ljust(len(old), b"\xFF")
            else:
                for n, offset in enumerate(parse_offsets(r["all_disc_offsets"]), 1):
                    report.append({"kind":"ui","id":f"{r['ui_id']}_{n}","result":state.get("result","SKIPPED_TOO_LONG"),"offset":f"{offset:06X}","cells":state.get("cells","")})
                continue
        for n, offset in enumerate(parse_offsets(r["all_disc_offsets"]), 1):
            add(f"{r['ui_id']}_{n}", offset, old, new, "ui")
    for r in speakers:
        old=r["jp_name"].encode("cp932")+b"\xFF"; new=fit(encode_game_text(r["ko_name"],custom),old,f"speaker {r['speaker_id']}")
        if new is None:
            state = pool_status.get(r["speaker_id"], {})
            if state.get("result") == "POOLED":
                new = bytes((0xF7, 0x40 + speaker_slots[r["speaker_id"]], 0xFF)).ljust(len(old), b"\xFF")
            else:
                report.append({"kind":"speaker","id":f"speaker_{r['speaker_id']}","result":state.get("result","SKIPPED_TOO_LONG"),"offset":f"{int(r['disc_offset'],16)+1:06X}","cells":state.get("cells","")})
                continue
        add(f"speaker_{r['speaker_id']}",int(r["disc_offset"],16)+1,old,new,"speaker")
    for p in patches:
        if stream.read_user_bytes(SOURCE02,p.iso_offset,len(p.old))!=p.old: raise RuntimeError(f"preflight mismatch: {p.name}")
    out02=out/f"Snatcher CD-ROMantic (Japan) (Track 02) [{version}].bin"; modified=stream.apply_patches_streaming(SOURCE02,out02,patches)
    out24=out/f"Snatcher CD-ROMantic (Japan) (Track 24) [{version}].bin"; shutil.copyfile(SOURCE24,out24)
    packed=packed_data.ljust(sectors*2048,b"\0")
    with out24.open("ab") as f:
        for i in range(sectors):
            sec=track24.make_mode1_sector(first+i,packed[i*2048:(i+1)*2048]); track24.verify_mode1_sector(sec,first+i); f.write(sec)
    cue=out/f"Snatcher CD-ROMantic (Japan) [{version}].cue"; staged=track24.stage_cue(cue,out02,out24)
    write_tsv(out/"glyph_map.tsv",map_rows); write_tsv(out/"static_patch_report.tsv",report)
    (out/"manifest.json").write_text(json.dumps({"version":version,"kind":"full-ui-speaker-cardram-cache","cache_bank":"6B","atlas_bytes":len(atlas),"string_pool_bytes":len(pool),"ui_string_slots":len(ui_slots),"speaker_string_slots":len(speaker_slots),"max_ui_cells":MAX_UI_CELLS,"sectors":sectors,"glyphs":len(map_rows),"glyph_y_shift":-1,"loader_bytes":len(loader),"wrapper_bytes":len(wrapper),"patched_records":sum(r['result']=='PATCHED' for r in report),"skipped_records":sum(r['result']!='PATCHED' for r in report),"cue_tracks":staged,"modified_track02_sectors":[f"{x:06X}" for x in sorted(modified)]},ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    (out/"TEST_IN_MESEN.txt").write_text("Load the CUE and power-cycle. Test reception speakers and blue action menus.\nExpected: all patched UI/speaker glyphs are shifted one pixel upward and menus remain native-speed.\nLong records use the Card-RAM string pool; rows over 8 visible cells are intentionally skipped. See static_patch_report.tsv.\n",encoding="utf-8-sig")
    return out

if __name__ == "__main__":
    ap=argparse.ArgumentParser(); ap.add_argument("--version",default=VERSION_DEFAULT); ap.add_argument("--force",action="store_true")
    ap.add_argument("--only-ui", help="build one UI long-string proof only")
    ap.add_argument("--no-speakers", action="store_true", help="omit speaker-name patches")
    ns=ap.parse_args(); print(build(ns.version,ns.force,ns.only_ui,ns.no_speakers))
