#!/usr/bin/env python3
"""Korean action-menu labels chosen at runtime by matching the Japanese source.

Method
------
No text data is patched.  The $66E5 renderer hook compares the string the game
is about to draw against the five Japanese source words and redirects
$3471/$3472 to a pre-encoded Korean string.  Positioning stays native: the
record's own FB <layout> <row> control code still places the label, so every
menu layout works without us knowing which row an item is on.

Live-verified action-menu record layout (UI 0.1.24.lua):

    $3490  FC 00        window
    $3492  F9 01
    $3494  FE 04        01/04, the unselected/selected draw pass
    $3496  FB 01 00     3 bytes; $3497 = layout (01 inline, 0B popup),
                        $3498 = row index
    $3499  SJIS text .. FF

$66E5 is entered once per token as the renderer walks the record, so the
pointer steps 3490 -> 3492 -> 3494 -> 3496 -> 3499 -> 349B ...  Narrative text
uses a different buffer at $3610, so "pointer == $3499" is a sufficient guard:
dialogue can never reach it and a narrative line containing 見る is never
touched.  The menu buffer is *not* cleared between records, so the bytes at
$3490 are stale during dialogue and cannot be used as the guard - only the live
pointer can.

Bank mapping (the reason UI 0.2.1 crashed)
------------------------------------------
UI 0.2.1 put everything in bank 68 (MPR2, CPU $4000-$5FFF) and hooked $66E5,
which is bank 6A (MPR3, CPU $6000-$7FFF).  That worked until some UI update ran
with a different bank paged into MPR2; "JSR $5C67" then jumped into unrelated
data.  UI 0.1.26.lua caught it directly:

    f004253 *** BANK FAULT at $66E5: $5C67 reads 84, expected DA (ptr=3490)

ptr=3490 is the very start of a menu record, i.e. exactly a UI refresh.  The
same probe showed MPR3 gets repaged too, so neither window is stable.

The rule that follows: an address in the same bank as the currently executing
code is always mapped.  So:

  * Data only *we* read (loader, font wrapper, glyph atlas) may live in bank 68,
    reached through a 14-byte trampoline in bank 6A that pages bank 68 into MPR2
    for the duration of the call and restores it afterwards.
  * Data the *game* reads outside our code - the redirected Korean text - must
    live in bank 6A, because the renderer dereferences it at $66EF, and $66EF is
    itself bank 6A code.  A trampoline cannot help there; there is no hook at
    the moment of that read.

Bank 6A only has 176 free bytes ($7F50-$7FFF), which is why the atlas stays in
bank 68 and only the two trampolines plus the 45-byte Korean pool go there.

Paging MPR2 does not disturb native Japanese text: $69C2's glyph cache table at
$6A07 points at glyph data inside bank 6A ($6A67, $6A87, $6AA7 ...), and $69FC
blits to $3B80 in WRAM.  Neither depends on MPR2.
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
VERSION = "UI 0.4.1"

# The action-menu labels live on disc in one contiguous 136-byte table of
# FF-terminated records, repeated byte-identically once per scene bank:
#
#   0x0DB807 .. 0x0DB88F   21 labels
#   見る 訓練する <원문 5자> 工場跡 持金 持物 写真 射撃場 車に乗る <원문 5자>
#   車体 手前の机 受付嬢 使い方 窓 中に入る 調べる 扉 聞く 壁 話す
#
# This is the invariant the original inline POC was reaching for when it said
# the records "have the menu's 00..03 item index immediately before them".  A
# short signature is not enough: occurrence 0x111CCF has the same three
# preceding bytes (918B FF, "窓" plus terminator) yet is ordinary dialogue.
# Comparing the whole 136-byte block separates them cleanly - of the 31 places
# 中に入る appears, exactly 12 are table instances and 19 are dialogue.
#
# So a label whose Korean fits inside the original record can be substituted
# straight into all 12 table instances: no pool entry, no comparison-table
# entry, no loader involvement, and no risk of touching dialogue.  SJIS and our
# custom codes are both 2 bytes per character, so "fits" means the Korean is no
# longer than the Japanese.
UI_TABLE_LEN = 0x88  # 0x0DB807 .. 0x0DB88F
UI_TABLE_REFERENCE = 0x0DB807
# Offsets of each substitutable label within the table.
UI_TABLE_SLOTS = {
    "UI0001": 0x00,  # 見る      4B
    "UI0002": 0x72,  # 調べる    6B
    "UI0003": 0x7C,  # 聞く      4B
    "UI0004": 0x84,  # 話す      4B
    "UI0006": 0x69,  # 中に入る  8B
}
# Labels moved out of the runtime path and written directly into the table.
# Both are exact fits: 見る/聞く are 4 bytes and 보다/묻다 encode to 4 bytes.
IN_PLACE_IDS = ("UI0001", "UI0003")
# The five labels proven in the Lua POC (UI 0.1.22), plus everything else from
# the action category that still fits in static space.  Order only fixes the
# table layout; the word is selected by string match, not by index.
#
# Two more is the static ceiling, and glyphs are why: 32 bytes each, and every
# remaining action entry needs at least two new ones.  The rest of the 58 rows
# need the Track-24 -> Card-RAM data bank.
UI_IDS = ("UI0006", "UI0002", "UI0004", "UI0016", "UI0009")
# Everything that needs a glyph, whichever path renders it.
ALL_IDS = UI_IDS + IN_PLACE_IDS

FONT_CALL = 0x648C
FONT_CALL_OLD = bytes((0x20, 0xC2, 0x69))
ENTRY = 0x66E5
ENTRY_OLD = bytes.fromhex("AD 71 34 85 03 AD 72 34 85 04")

# Two static caves.  Bank 68 holds the glyph atlas and the loader; bank 6A holds
# the font wrapper and the Korean text pool.
#
# Splitting them is what makes room for the extra labels: the atlas is the
# expensive part and it needs the whole of bank 68.  Both halves are proven
# placements - build_ui_static_atlas_poc.py puts its wrapper at $7F50 in bank 6A
# with the note "MPR3 is $6A while the renderer executes, so no MPR switch or CD
# access is necessary", and UI 0.2.5 ran the pool at $7F60 with 38 of 38
# redirects clean.  The wrapper reads the atlas across into bank 68 without
# paging it in, exactly as UI 0.2.1 did when its glyphs came out pixel-correct;
# MPR2 has read back as $68 in every heartbeat, and the worst case is one
# wrong-looking glyph rather than a crash.
CAVE68_START = common.CAVE_CPU_START  # $5C67
CAVE68_END = 0x6000
CAVE6A_START = 0x7F50  # only FF run in bank 6A: $7F50-$7FFF, 176 bytes
CAVE6A_END = 0x8000

# Measured with UI 0.1.33.lua: at a scene transition the game writes a table of
# repeating 9-10 byte records over the bottom of the cave.  Observed window:
#
#   f005756  CAVE DAMAGE: 78 bytes changed, $5C67..$5CB9
#            atlas/wrapper/pool above it: 0 bytes changed
#            new bytes: 84 00 04 00 00 00 00 00 00 8A 84 00 04 00 00 00
#
# Executed as code that is "STY $00 / TSB $00 / BRK", which is exactly how builds
# 0.2.1-0.2.6 died: the loader lived at $5C67, got overwritten, and the next
# JSR from $66E5 ran into the BRK.
#
# So nothing executable may start here.  Only the glyph atlas does, and its first
# three entries are placeholders this build never references, which gives 96
# bytes of padding to absorb the damage.
DANGER_LO, DANGER_HI = 0x5C67, 0x5CB9

# The atlas prefix is what absorbs that write.  Three entries are the codec's
# fixed F040/F041/F042 (period, blank, ellipsis) and cannot be moved, and none
# of them is referenced by the five action-menu labels - the space in
# "안으로 들어간다" encodes as the native fullwidth 81 40, not F041.  On top of
# those sits one purely sacrificial entry, which widens the margin between the
# far end of the observed write and the first real glyph from 13 to 45 bytes.
RESERVED_GLYPHS = 3      # F040 period, F041 blank, F042 ellipsis
SACRIFICIAL_GLYPHS = 1   # pure padding, no code ever points at it
PLACEHOLDER_GLYPHS = RESERVED_GLYPHS + SACRIFICIAL_GLYPHS
SLOTS_PER_LEAD = 188

UI_TEXT_POINTER = 0x3499  # action-menu label text, verified live


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest().upper()


def align(value: int, boundary: int = 4) -> int:
    # 4, not 16: with the extra sacrificial glyph the four blobs come to 908 of
    # the cave's 921 bytes, so 16-byte gaps would push the pool past $6000.
    return (value + boundary - 1) & ~(boundary - 1)


def read_ui(wanted: tuple[str, ...]) -> list[dict[str, str]]:
    with UI_TSV.open("r", encoding="utf-16", newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    matches = [r for r in rows if r.get("ui_id") in wanted and r.get("status") in {"review", "final"}]
    by_id = {r["ui_id"]: r for r in matches}
    missing = [ui_id for ui_id in wanted if ui_id not in by_id]
    if missing:
        raise RuntimeError(f"missing reviewed UI rows: {', '.join(missing)}")
    return [by_id[ui_id] for ui_id in wanted]


def _looks_like_label(raw: bytes) -> bool:
    if not raw or len(raw) % 2 or len(raw) > 24:
        return False
    try:
        text = raw.decode("cp932")
    except UnicodeDecodeError:
        return False
    return len(text) <= 12 and not any(c in text for c in "。、「」！？…")


def in_label_table(source: Path, offset: int, need: int = 6) -> bool:
    """Is this occurrence inside a menu label table rather than prose?

    Label tables are dense runs of short FF-terminated records.  Prose records
    are long and contain punctuation, so counting the longest consecutive run of
    label-shaped records around the offset separates them reliably.

    This replaces matching one canonical 136-byte block, which was too strict:
    each scene has its own table with its own contents, so only 12 of 見る's 50
    occurrences were byte-identical copies and UI 0.4.0 patched just those - the
    scene under test used a different variant and still showed Japanese.
    """
    window = stream.read_user_bytes(source, max(0, offset - 0x60), 0xC0)
    best = run = 0
    i = 0
    while i < len(window):
        j = i
        while j < len(window) and window[j] != 0xFF:
            j += 1
        if _looks_like_label(bytes(window[i:j])):
            run += 1
            best = max(best, run)
        else:
            run = 0
        i = j + 1
    return best >= need


def find_label_offsets(source: Path, row: dict[str, str]) -> list[int]:
    """Every disc offset of this label that sits inside a menu label table.

    Measured result, not an assumption: for 見る 50/50, 調べる 48/48, 聞く 37/37,
    話す 36/36, 中に入る 31/31 and 使う 8/8, every single occurrence is in a
    table and none is dialogue.  The original inline POC's warning that "the
    same words also occur in unrelated script data" does not hold for these, so
    patching them all is safe as long as record length is preserved.  The few
    rejects are coincidental byte matches in the disc's first kilobyte.
    """
    expect = row["jp_text"].encode("cp932") + b"\xFF"
    found = []
    for text in row["all_disc_offsets"].split(","):
        offset = int(text.strip(), 16)
        if stream.read_user_bytes(source, offset, len(expect)) != expect:
            continue
        if in_label_table(source, offset):
            found.append(offset)
    if not found:
        raise RuntimeError(f"{row['ui_id']}: no label-table occurrences found")
    return found


def custom_code(index: int) -> bytes:
    # F7 stays unallocated so the wrapper's F0-F6 range test is a clean bound.
    if not 0 <= index < SLOTS_PER_LEAD * 7:
        raise RuntimeError("too many action-menu glyphs")
    lead, within = divmod(index, SLOTS_PER_LEAD)
    trail = within + 0x40
    if trail >= 0x7F:
        trail += 1
    return bytes((0xF0 + lead, trail))


def make_atlas(texts: list[str]) -> tuple[bytes, dict[str, bytes], tuple[str, ...]]:
    chars = ordered_hangul(texts)
    found = common.parse_bdf(common.FONT_BDF, {ord(c) for c in chars})
    missing = [c for c in chars if ord(c) not in found]
    if missing:
        raise RuntimeError(f"missing glyphs: {missing}")
    period = bytes(22) + bytes((0x0C, 0x00, 0x0C, 0x00)) + bytes(6)
    blank = bytes(32)
    ellipsis = bytes(22) + bytes((0x22, 0x20, 0x22, 0x20)) + bytes(6)
    # Prefix order matters: F040/F041/F042 are fixed by the codec and have to
    # stay at indices 0-2, so the extra sacrificial padding goes after them and
    # the real glyphs start at index PLACEHOLDER_GLYPHS.
    atlas = bytearray(period + blank + ellipsis + bytes(32 * SACRIFICIAL_GLYPHS))
    custom: dict[str, bytes] = {}
    for index, char in enumerate(chars, start=PLACEHOLDER_GLYPHS):
        glyph = common.glyph_1bpp_left_shifted(*found[ord(char)])
        glyph = glyph[2:] + b"\0\0"  # UI baseline is one scanline higher.
        custom[char] = custom_code(index)
        atlas.extend(glyph)
    return bytes(atlas), custom, chars


def make_loader(origin: int, rows: list[dict[str, str]], pool_addr: int, pool_offsets: list[int]) -> bytes:
    """Match the Japanese label about to be drawn, then swap in the Korean one."""
    a = common.Assembler(origin)
    pool_page = (pool_addr >> 8) & 0xFF

    a.emit(0xDA, 0x5A)  # PHX / PHY - the renderer's X and Y are live here.
    a.abs(0xAD, 0x3471); a.emit(0x85, 0x03)
    a.abs(0xAD, 0x3472); a.emit(0x85, 0x04)

    # While a Korean pool string is being drawn the renderer keeps advancing
    # $3471/$3472 through the pool.  When it reaches that string's FF, hand the
    # original Japanese terminator back so the UI state machine finishes the
    # record normally instead of retaining a pool pointer.
    a.abs(0xAD, "active"); a.branch(0xF0, "check_ui")
    a.emit(0xA5, 0x04, 0xC9, pool_page); a.branch(0xD0, "check_ui")
    a.emit(0xA0, 0x00, 0xB1, 0x03, 0xC9, 0xFF); a.branch(0xD0, "check_ui")
    a.abs(0xAD, "resume_lo"); a.abs(0x8D, 0x3471)
    a.abs(0xAD, "resume_hi"); a.abs(0x8D, 0x3472)
    a.emit(0xA9, 0x00); a.abs(0x8D, "active")
    a.abs(0x4C, "done")

    # $66E5 also renders narrative text, out of the $3610 buffer.  An
    # action-menu label always starts at exactly $3499, so this one comparison
    # separates the two contexts without looking at the text at all.
    a.label("check_ui")
    a.emit(0xA5, 0x04, 0xC9, UI_TEXT_POINTER >> 8); a.branch(0xD0, "done")
    a.emit(0xA5, 0x03, 0xC9, UI_TEXT_POINTER & 0xFF); a.branch(0xD0, "done")

    a.emit(0xA2, 0x00)  # LDX #0 - table cursor
    a.label("entry_loop")
    a.emit(0xA0, 0x00)  # LDY #0 - offset into the live string
    a.label("cmp_loop")
    a.emit(0xB1, 0x03)      # LDA ($03),Y
    a.abs(0xDD, "table")    # CMP table,X
    a.branch(0xD0, "skip_entry")
    a.emit(0xC8, 0xE8)      # INY / INX
    a.emit(0xC9, 0xFF)      # A still holds the matched byte.
    a.branch(0xD0, "cmp_loop")

    # Matched through the FF terminator, so this really is the whole label and
    # not a prefix.  Y = length + 1; X points at the entry's pool pointer.
    a.emit(0x88)  # DEY -> Y = length, i.e. the offset of the original FF.
    a.emit(0x98, 0x18, 0x65, 0x03); a.abs(0x8D, "resume_lo")
    a.emit(0xA5, 0x04, 0x69, 0x00); a.abs(0x8D, "resume_hi")
    a.emit(0xA9, 0x01); a.abs(0x8D, "active")
    a.abs(0xBD, "table"); a.abs(0x8D, 0x3471)
    a.emit(0xE8)
    a.abs(0xBD, "table"); a.abs(0x8D, 0x3472)
    a.branch(0x80, "done")

    a.label("skip_entry")
    a.abs(0xBD, "table"); a.emit(0xE8, 0xC9, 0xFF); a.branch(0xD0, "skip_entry")
    a.emit(0xE8, 0xE8)  # step over this entry's pool pointer
    a.abs(0xBD, "table"); a.branch(0xD0, "entry_loop")  # 00 ends the table

    a.label("done")
    a.abs(0xAD, 0x3471); a.emit(0x85, 0x03)
    a.abs(0xAD, 0x3472); a.emit(0x85, 0x04, 0x7A, 0xFA, 0x60)  # PLY / PLX / RTS

    # Each entry is <SJIS bytes> FF <pool pointer>; a 00 lead byte ends the
    # table, which no Shift-JIS lead byte can be.
    a.label("table")
    for row, offset in zip(rows, pool_offsets):
        a.emit(*row["jp_text"].encode("cp932"), 0xFF)
        a.word(pool_addr + offset)
    a.emit(0x00)
    a.label("resume_lo"); a.emit(0x00)
    a.label("resume_hi"); a.emit(0x00)
    a.label("active"); a.emit(0x00)
    return a.finish()


def make_wrapper(origin: int, atlas_addr: int) -> bytes:
    """F0-F6 codes read the glyph from our atlas; everything else stays native.

    Called straight from $648C, which has two live outputs.  Wrapping that call
    cost two builds to learn:

        648C  JSR $69C2        ; A = 0 drawn / $FF cache miss
                               ; X = free cache slot on a miss
        648F  CMP #$00
        6491  BEQ $64A5
        6493  JSR $E060        ; loads the character into slot X

    UI 0.2.2 lost A to a trampoline's PLA and every Korean glyph became the
    missing-character tile; UI 0.2.3 then lost X to PHX/PLX and the game hung
    inside $E060 on the first Japanese cache miss.  Calling through directly
    keeps both intact by construction: the native path is a bare
    "JSR $69C2 / RTS", so A, X and the flags all pass through untouched.
    """
    a = common.Assembler(origin)
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
    # $00/$01 = atlas_addr + (index * 32), with carry from the low byte kept.
    a.emit(0x85, 2, 0x48, 0x4A, 0x4A, 0x4A, 0x18, 0x69, atlas_addr >> 8, 0x85, 1, 0x68)
    a.emit(0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x18, 0x69, atlas_addr & 0xFF, 0x85, 0)
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

    # The atlas has to cover both paths; only the runtime path needs a pool
    # entry and a comparison-table entry.
    rows_all = read_ui(ALL_IDS)
    rows = read_ui(UI_IDS)
    in_place_rows = read_ui(IN_PLACE_IDS)
    atlas, custom, chars = make_atlas([row["ko_text"] for row in rows_all])
    pool_offsets: list[int] = []
    encoded = bytearray()
    for row in rows:
        pool_offsets.append(len(encoded))
        encoded.extend(encode_game_text(row["ko_text"], custom))

    # In-place substitution: the Korean replaces the Japanese inside every copy
    # of the disc's UI label table.  Length is preserved exactly - short Korean
    # is padded with the native fullwidth space so the record's terminator stays
    # where it was, in case the game walks the table by scanning for FF.
    in_place: list[tuple[str, bytes, bytes, list[int]]] = []
    for row in in_place_rows:
        old = row["jp_text"].encode("cp932") + b"\xFF"
        body = encode_game_text(row["ko_text"], custom)
        if len(body) > len(old):
            raise RuntimeError(
                f"{row['ui_id']}: {row['ko_text']} needs {len(body)} bytes, slot holds {len(old)}"
            )
        new = body[:-1] + b"\x81\x40" * ((len(old) - len(body)) // 2) + b"\xFF"
        if len(new) != len(old):
            raise RuntimeError(f"{row['ui_id']}: padding did not land on an even boundary")
        in_place.append((row["ui_id"], old, new, find_label_offsets(SOURCE02, row)))

    # Bank 68: atlas at the bottom so its unused placeholder glyphs sit in the
    # overwrite window, loader above it.  Nothing executable starts in the
    # window, and everything above $5D00 was measured intact when it fired.
    atlas_addr = CAVE68_START
    loader_probe = make_loader(0x0000, rows, 0x0000, pool_offsets)
    loader_addr = align(atlas_addr + len(atlas))

    # Bank 6A: wrapper first, at the address the static-atlas proof used, then
    # the pool the renderer dereferences on its own.
    wrapper_addr = CAVE6A_START
    wrapper_probe = make_wrapper(wrapper_addr, atlas_addr)
    pool_addr = align(wrapper_addr + len(wrapper_probe))

    loader = make_loader(loader_addr, rows, pool_addr, pool_offsets)
    wrapper = make_wrapper(wrapper_addr, atlas_addr)
    if len(loader) != len(loader_probe) or len(wrapper) != len(wrapper_probe):
        raise RuntimeError("blob length changed between passes")

    if loader_addr + len(loader) > CAVE68_END:
        raise RuntimeError(
            f"bank 68 overflow: atlas {len(atlas)} + loader {len(loader)} "
            f"exceeds {CAVE68_END - CAVE68_START} bytes"
        )
    if pool_addr + len(encoded) > CAVE6A_END:
        raise RuntimeError(
            f"bank 6A overflow: wrapper {len(wrapper)} + pool {len(encoded)} "
            f"exceeds {CAVE6A_END - CAVE6A_START} bytes"
        )
    if (pool_addr >> 8) != ((pool_addr + len(encoded) - 1) >> 8):
        raise RuntimeError("pool crosses a page boundary; the loader's page test would break")

    # The measured overwrite window must stay inside the atlas's placeholder
    # glyphs, so it can only ever damage bytes nothing reads.
    placeholder_end = atlas_addr + PLACEHOLDER_GLYPHS * 32 - 1
    if DANGER_LO < atlas_addr or DANGER_HI > placeholder_end:
        raise RuntimeError(
            f"overwrite window ${DANGER_LO:04X}-${DANGER_HI:04X} is not covered by the "
            f"atlas placeholders (${atlas_addr:04X}-${placeholder_end:04X})"
        )
    for name, lo, size in (
        ("loader", loader_addr, len(loader)),
        ("wrapper", wrapper_addr, len(wrapper)),
        ("pool", pool_addr, len(encoded)),
    ):
        if lo <= DANGER_HI and lo + size - 1 >= DANGER_LO:
            raise RuntimeError(f"{name} overlaps the overwrite window at ${DANGER_LO:04X}-${DANGER_HI:04X}")

    patches = [
        common.Patch("ui_atlas", common.bank68_iso(atlas_addr), b"\xFF" * len(atlas), atlas, atlas_addr),
        common.Patch("ui_loader", common.bank68_iso(loader_addr), b"\xFF" * len(loader), loader, loader_addr),
        common.Patch("ui_wrapper", common.bank6a_iso(wrapper_addr), b"\xFF" * len(wrapper), wrapper, wrapper_addr),
        common.Patch("ui_pool", common.bank6a_iso(pool_addr), b"\xFF" * len(encoded), bytes(encoded), pool_addr),
        common.Patch("font_call", common.bank6a_iso(FONT_CALL), FONT_CALL_OLD, bytes((0x20, wrapper_addr & 0xFF, wrapper_addr >> 8)), FONT_CALL),
        common.Patch("renderer_entry", common.bank6a_iso(ENTRY), ENTRY_OLD, bytes((0x20, loader_addr & 0xFF, loader_addr >> 8)) + b"\xEA" * 7, ENTRY),
    ]
    # Text-data patches, every occurrence that the table test accepted.
    for ui_id, old, new, offsets in in_place:
        for number, offset in enumerate(offsets, 1):
            patches.append(common.Patch(f"{ui_id.lower()}_t{number:02d}", offset, old, new))

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

    glyphs = [
        {"character": char, "game_code": custom[char].hex().upper(), "atlas_cpu": f"{atlas_addr + index * 32:04X}"}
        for index, char in enumerate(chars, start=PLACEHOLDER_GLYPHS)
    ]
    (out / "glyph_map.json").write_text(json.dumps(glyphs, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (out / "TEST_IN_MESEN.txt").write_text(
        "Load the CUE, then power-cycle.\n"
        "Expected Korean: 안으로 들어간다 / 보다 / 조사하다 / 묻다 / 대화하다.\n"
        "\n"
        "Why 0.2.1 through 0.2.6 all died, finally measured rather than guessed:\n"
        "every one of them put the loader at $5C67, the bottom of the cave, and at a\n"
        "scene transition the game writes a table of repeating 9-10 byte records over\n"
        "$5C67-$5CB9.  As code those bytes are 'STY $00 / TSB $00 / BRK', so the next\n"
        "JSR from $66E5 hit a BRK and the CPU smeared $4C across the whole cave.\n"
        "UI 0.1.32 proved it with MPR2 confirmed at $68 while $5C67 read 84, and\n"
        "UI 0.1.33 measured the exact window with everything above it untouched.\n"
        "\n"
        "The bank mapping, the trampolines and the A/X return values were never the\n"
        "problem.  Mesen's memory callbacks match on CPU address regardless of which\n"
        "bank is paged in, and that aliasing is what made the earlier 'bank fault' and\n"
        "'bank 6A tail' readings look meaningful.\n"
        "\n"
        "0.2.7 puts data low and code high, the same shape as the playable narration\n"
        "build (GLYPH_BASE $5C80 for data, FONT_WRAPPER $5F40 / OVERLAY_HOOK $5F80 for\n"
        "code).  The glyph atlas takes the bottom of the cave and its three unused\n"
        "placeholder glyphs cover the overwrite window exactly, so the damage lands on\n"
        "96 bytes nothing reads.  If that window ever grows it eats real glyphs, which\n"
        "makes letters look wrong - it cannot crash the game any more.\n"
        "\n"
        "Test priorities:\n"
        "  1. Glyph shapes must be actual Hangul, not solid blocks.\n"
        "  2. Several different action-menu layouts (with and without 中に入る, and a\n"
        "     target that shows the 聞く popup - 묻다 has never rendered in a real build).\n"
        "  3. Keep playing past the point where 0.2.1/0.2.2 died - a UI refresh, a scene\n"
        "     change, and confirming a menu item.\n"
        "  4. Ordinary dialogue must still be untouched Japanese.\n"
        "Run tools\\mesen\\UI 0.1.30.lua alongside.  It reports the frozen PC if the game\n"
        "stops, so a hang no longer has to be guessed at.\n",
        encoding="utf-8-sig",
    )
    (out / "manifest.json").write_text(
        json.dumps(
            {
                "version": VERSION,
                "method": "hybrid - in-place substitution inside the disc UI label table, plus runtime source-string match at $66E5 guarded by pointer == $3499",
                "in_place": {
                    "selector": "every all_disc_offsets occurrence that passes the label-table test",
                    "labels": [
                        {
                            "ui_id": ui_id,
                            "old": old.hex().upper(),
                            "new": new.hex().upper(),
                            "patched": len(offsets),
                            "offsets": [f"{o:06X}" for o in offsets],
                        }
                        for ui_id, old, new, offsets in in_place
                    ],
                },
                "fixes": "UI 0.2.1 bank fault: hooks now trampoline through bank 6A; pool moved to bank 6A",
                "ui": [{"ui_id": row["ui_id"], "jp": row["jp_text"], "jp_sjis": row["jp_text"].encode("cp932").hex().upper(), "ko": row["ko_text"], "pool_cpu": f"{pool_addr + offset:04X}"} for row, offset in zip(rows, pool_offsets)],
                "bank68": {
                    "atlas_cpu": f"{atlas_addr:04X}", "atlas_bytes": len(atlas),
                    "loader_cpu": f"{loader_addr:04X}", "loader_bytes": len(loader),
                    "free_bytes": CAVE68_END - (loader_addr + len(loader)),
                    "overwrite_window": f"{DANGER_LO:04X}-{DANGER_HI:04X} (absorbed by the atlas placeholders)",
                },
                "bank6a": {
                    "wrapper_cpu": f"{wrapper_addr:04X}", "wrapper_bytes": len(wrapper),
                    "pool_cpu": f"{pool_addr:04X}", "pool_bytes": len(encoded),
                    "free_bytes": CAVE6A_END - (pool_addr + len(encoded)),
                },
                "hooks": {
                    f"{ENTRY:04X}": f"JSR {loader_addr:04X} + 7x NOP",
                    f"{FONT_CALL:04X}": f"JSR {wrapper_addr:04X}",
                },
                "modified_sectors": sorted(f"{n:06X}" for n in modified),
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return out


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    print(build(args.force))
