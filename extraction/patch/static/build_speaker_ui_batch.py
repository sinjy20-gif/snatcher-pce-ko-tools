#!/usr/bin/env python3
"""Build the Track-24-backed speaker/UI batch patch.

The 0.1.8 proof established two independent bitmap baselines: speaker names
use the normal Galmuri11 placement and menu/UI glyphs are shifted one pixel
up.  The complete reviewed short-string set is too large for the Track 02
code cave, so this builder groups every in-place-safe string into one of 13
small font packs.  The active pack is loaded on demand from appended Track 24
sectors into the proven bank-68 cave.  Pack identity is encoded by pairing
each parser-safe F0-F6 lead with one of two valid Shift-JIS trail ranges; the
script engine reserves F8-FE as control bytes, so those values must never be
used as custom lead bytes.

Only records whose encoded Korean fits inside the original FF-terminated
record are patched.  Longer speaker/UI records remain Japanese for the later
relocation stage.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(r"C:\snatcher")
ROM_DIR = ROOT / "rom(japan)" / "Snatcher CD-ROMantic (Japan)"
SOURCE_TRACK02 = ROM_DIR / "Snatcher CD-ROMantic (Japan) (Track 02).bin"
SOURCE_TRACK24 = ROM_DIR / "Snatcher CD-ROMantic (Japan) (Track 24).bin"
BUILD_ROOT = ROOT / "build" / "patch"
SPEAKER_TSV = ROOT / "translation" / "speaker_name_standard.tsv"
UI_TSV = ROOT / "translation" / "ui_text.tsv"

STATIC_DIR = ROOT / "extraction" / "patch" / "static"
TRANSLATION_DIR = ROOT / "extraction" / "translation"
sys.path.insert(0, str(STATIC_DIR))
sys.path.insert(0, str(TRANSLATION_DIR))

import build_disc_patch as common  # noqa: E402
import build_speaker_ui_proof as proof  # noqa: E402
import build_track24_loader_proof as track24  # noqa: E402
from game_text_codec import encode_game_text, ordered_hangul  # noqa: E402


EXPECTED_TRACK02_SHA256 = common.EXPECTED_SOURCE_SHA256
EXPECTED_TRACK24_SHA256 = track24.EXPECTED_TRACK24_SHA256
ALLOWED_STATUS = {"review", "final"}

PACK_CAPACITY = 19
PACK_COUNT = 11
PACK_BYTES = PACK_CAPACITY * 32
APPENDED_SECTORS = track24.SECONDARY_CD_BASE - track24.PRIMARY_CD_BASE + 1

# Bank-68 FF cave proven by the pristine Track 02 image.
CURRENT_PACK = 0x5BB3
REQUEST_PACK = 0x5BB4
READ_STATUS = 0x5BB5
PERIOD_GLYPH = 0x5BC0
BLANK_GLYPH = 0x5B80
GLYPH_CACHE = 0x5BE0
FONT_LOADER = 0x5E40
FONT_PRELOADER = 0x5F00

# Bank-6A has one final 176-byte FF run.
FONT_WRAPPER = 0x7F50
RENDERER_ENTRY = 0x66E5
ORIGINAL_RENDERER_ENTRY = bytes.fromhex("AD 71 34")

BIOS_CD_BASE = 0xE006
BIOS_CD_READ = 0xE009


@dataclass(frozen=True)
class Item:
    kind: str
    row_id: str
    jp_text: str
    ko_text: str
    row: dict[str, str]
    glyphs: frozenset[str]

    @property
    def key(self) -> str:
        return f"{self.kind}:{self.row_id}"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest().upper()


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-16", newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def write_tsv(path: Path, rows: list[dict[str, str]]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=list(rows[0]),
            delimiter="\t",
            lineterminator="\n",
        )
        writer.writeheader()
        writer.writerows(rows)


def encoded_length(text: str) -> int:
    dummy = {char: bytes((0xF0, 0x41)) for char in ordered_hangul([text])}
    return len(encode_game_text(text, dummy))


def original_length(text: str) -> int:
    return len(text.encode("cp932")) + 1


def ui_disc_offsets(row: dict[str, str]) -> list[int]:
    """Parse UI offsets and repair Excel's six-digit thousands grouping.

    Old Excel may rewrite ``117390,119434`` as
    ``117,390,119,434`` inside the quoted TSV cell.  The occurrence count
    makes that transformation unambiguous, so accept it without ever
    treating the three-digit fragments as real disc offsets.
    """

    expected = int(row["occurrences"])
    parts = row["all_disc_offsets"].split(",")
    if len(parts) == expected and all(len(part) == 6 for part in parts):
        return [int(part, 16) for part in parts]
    if len(parts) == expected * 2 and all(len(part) == 3 for part in parts):
        merged = [parts[index] + parts[index + 1] for index in range(0, len(parts), 2)]
        return [int(part, 16) for part in merged]
    raise RuntimeError(
        f"{row['ui_id']}: malformed all_disc_offsets {row['all_disc_offsets']!r}"
    )


def load_items() -> tuple[list[Item], list[dict[str, str]]]:
    items: list[Item] = []
    deferred: list[dict[str, str]] = []

    for row in read_tsv(SPEAKER_TSV):
        if row["status"] not in ALLOWED_STATUS:
            continue
        need = encoded_length(row["ko_name"])
        have = original_length(row["jp_name"])
        if need <= have:
            items.append(
                Item(
                    "speaker",
                    row["speaker_id"],
                    row["jp_name"],
                    row["ko_name"],
                    row,
                    frozenset(ordered_hangul([row["ko_name"]])),
                )
            )
        else:
            deferred.append(
                {
                    "kind": "speaker",
                    "id": row["speaker_id"],
                    "jp_text": row["jp_name"],
                    "ko_text": row["ko_name"],
                    "original_bytes": str(have),
                    "korean_bytes": str(need),
                    "over_by": str(need - have),
                    "reason": "requires relocation",
                }
            )

    for row in read_tsv(UI_TSV):
        if row["status"] not in ALLOWED_STATUS:
            continue
        need = encoded_length(row["ko_text"])
        have = original_length(row["jp_text"])
        if need <= have:
            items.append(
                Item(
                    "ui",
                    row["ui_id"],
                    row["jp_text"],
                    row["ko_text"],
                    row,
                    frozenset(ordered_hangul([row["ko_text"]])),
                )
            )
        else:
            deferred.append(
                {
                    "kind": "ui",
                    "id": row["ui_id"],
                    "jp_text": row["jp_text"],
                    "ko_text": row["ko_text"],
                    "original_bytes": str(have),
                    "korean_bytes": str(need),
                    "over_by": str(need - have),
                    "reason": "requires relocation",
                }
            )

    return items, deferred


def pack_context(items: list[Item]) -> list[tuple[set[str], list[Item]]]:
    """Deterministic best-fit grouping with one font pack per source item."""

    bins: list[tuple[set[str], list[Item]]] = []
    for item in sorted(items, key=lambda value: (-len(value.glyphs), value.key)):
        choices: list[tuple[int, int, int]] = []
        for index, (glyphs, _) in enumerate(bins):
            union = glyphs | item.glyphs
            if len(union) <= PACK_CAPACITY:
                choices.append((len(union) - len(glyphs), len(union), index))
        if choices:
            _, _, index = min(choices)
            bins[index][0].update(item.glyphs)
            bins[index][1].append(item)
        else:
            bins.append((set(item.glyphs), [item]))
    return bins


def assign_packs(items: list[Item]) -> tuple[list[dict[str, object]], dict[str, int]]:
    speakers = [item for item in items if item.kind == "speaker"]
    ui = [item for item in items if item.kind == "ui"]
    grouped = pack_context(speakers) + pack_context(ui)
    if len(grouped) != PACK_COUNT:
        raise RuntimeError(f"expected {PACK_COUNT} font packs, got {len(grouped)}")

    packs: list[dict[str, object]] = []
    item_to_pack: dict[str, int] = {}
    for index, (glyphs, members) in enumerate(grouped):
        ordered = tuple(sorted(glyphs, key=ord))
        if len(ordered) > PACK_CAPACITY:
            raise RuntimeError(f"pack {index} exceeds {PACK_CAPACITY} glyphs")
        context = members[0].kind
        if any(member.kind != context for member in members):
            raise RuntimeError("speaker and UI glyph contexts were mixed")
        packs.append(
            {
                "index": index,
                "context": context,
                "glyphs": ordered,
                "members": tuple(sorted(members, key=lambda value: value.key)),
            }
        )
        for member in members:
            item_to_pack[member.key] = index
    return packs, item_to_pack


def custom_code(pack_index: int, glyph_index: int) -> bytes:
    if not 0 <= pack_index < PACK_COUNT:
        raise ValueError(pack_index)
    if not 0 <= glyph_index < PACK_CAPACITY:
        raise ValueError(glyph_index)
    lead = 0xF0 + pack_index // 2
    if pack_index % 2:
        trail = 0x80 + glyph_index
    elif pack_index == 0:
        # F040 remains the compact period.
        trail = 0x41 + glyph_index
    else:
        trail = 0x40 + glyph_index
    return bytes((lead, trail))


def build_font_packs(
    packs: list[dict[str, object]],
) -> tuple[list[bytes], dict[str, dict[str, bytes]], list[dict[str, str]]]:
    all_chars = {
        char
        for pack in packs
        for char in pack["glyphs"]  # type: ignore[union-attr]
    }
    found = common.parse_bdf(common.FONT_BDF, {ord(char) for char in all_chars})
    missing = sorted(char for char in all_chars if ord(char) not in found)
    if missing:
        raise RuntimeError(f"missing Galmuri11 glyphs: {missing}")

    payloads: list[bytes] = []
    custom_by_item: dict[str, dict[str, bytes]] = {}
    map_rows: list[dict[str, str]] = [
        {
            "pack": "static",
            "context": "all",
            "index": "0",
            "game_code": "F040",
            "character": ".",
            "unicode": "U+002E",
            "y_shift": "0",
        },
        {
            "pack": "static",
            "context": "all",
            "index": "1",
            "game_code": "F041",
            "character": "<SPACE>",
            "unicode": "U+0020",
            "y_shift": "0",
        },
    ]

    for pack in packs:
        pack_index = int(pack["index"])
        context = str(pack["context"])
        glyphs = tuple(pack["glyphs"])  # type: ignore[arg-type]
        members = tuple(pack["members"])  # type: ignore[arg-type]
        encoded = bytearray()
        pack_map: dict[str, bytes] = {}
        for glyph_index, char in enumerate(glyphs):
            bitmap = common.glyph_1bpp_left_shifted(*found[ord(char)])
            if context == "ui":
                bitmap = proof.shift_glyph_up(bitmap)
            encoded.extend(bitmap)
            code = custom_code(pack_index, glyph_index)
            pack_map[char] = code
            map_rows.append(
                {
                    "pack": str(pack_index),
                    "context": context,
                    "index": str(glyph_index),
                    "game_code": code.hex().upper(),
                    "character": char,
                    "unicode": f"U+{ord(char):04X}",
                    "y_shift": "-1" if context == "ui" else "0",
                }
            )
        encoded.extend(bytes(PACK_BYTES - len(encoded)))
        payloads.append(bytes(encoded))
        for member in members:
            custom_by_item[member.key] = pack_map
    return payloads, custom_by_item, map_rows


def emit_cd_base(a: common.Assembler, base_sector: int) -> None:
    for zp, value in (
        (0xF8, (base_sector >> 16) & 0xFF),
        (0xF9, (base_sector >> 8) & 0xFF),
        (0xFA, base_sector & 0xFF),
        (0xFB, 0x00),
        (0xFC, 0x01),
    ):
        a.emit(0xA9, value, 0x85, zp)
    a.abs(0x20, BIOS_CD_BASE)


def build_font_loader(
    relative_sector: int,
    track24_index1_lba: int,
    track02_index1_lba: int,
) -> bytes:
    if (relative_sector & 0xFF) + PACK_COUNT - 1 > 0xFF:
        raise RuntimeError("font-pack sectors cross a low-byte boundary")

    a = common.Assembler(FONT_LOADER)
    a.abs(0x8D, REQUEST_PACK)  # requested pack in A
    a.emit(0xDA, 0x5A)  # PHX / PHY
    for zp in range(0xF8, 0x100):
        a.emit(0xA5, zp, 0x48)

    emit_cd_base(a, track24_index1_lba)

    for zp, value in (
        (0xF8, PACK_BYTES & 0xFF),
        (0xF9, PACK_BYTES >> 8),
        (0xFA, GLYPH_CACHE & 0xFF),
        (0xFB, GLYPH_CACHE >> 8),
        (0xFC, (relative_sector >> 16) & 0xFF),
        (0xFD, (relative_sector >> 8) & 0xFF),
    ):
        a.emit(0xA9, value, 0x85, zp)
    # REQUEST_PACK is an absolute bank-68 variable at $5BB4, not zero page
    # $B4.  Using opcode A5 here made every request read pack sector zero
    # while CURRENT_PACK was still updated to the requested number.
    a.abs(0xAD, REQUEST_PACK)
    a.emit(0x18, 0x69, relative_sector & 0xFF, 0x85, 0xFE)
    a.emit(0xA9, 0x00, 0x85, 0xFF)
    a.abs(0x20, BIOS_CD_READ)
    a.abs(0x8D, READ_STATUS)
    a.emit(0xC9, 0x00)
    a.branch(0xD0, "read_failed")
    a.abs(0xAD, REQUEST_PACK)
    a.abs(0x8D, CURRENT_PACK)
    a.branch(0x80, "restore_base")
    a.label("read_failed")
    a.emit(0xA9, 0xFF)
    a.abs(0x8D, CURRENT_PACK)

    a.label("restore_base")
    emit_cd_base(a, track02_index1_lba)
    for zp in reversed(range(0xF8, 0x100)):
        a.emit(0x68, 0x85, zp)
    # BIOS routines may clobber ordinary zero page.  The renderer keeps its
    # live string pointer in $03/$04; rebuild it exactly as the proven 0.1.5
    # Track-24 loader did, or the remainder of the first freshly loaded menu
    # is parsed from a stray address.  Cache-warm redraws hid this omission.
    a.abs(0xAD, 0x3471)
    a.emit(0x85, 0x03)
    a.abs(0xAD, 0x3472)
    a.emit(0x85, 0x04)
    a.emit(0x7A, 0xFA, 0x60)  # PLY / PLX / RTS
    return a.finish()


def pack_cache_checksums(pack_payloads: list[bytes]) -> list[tuple[int, int]]:
    """Return cheap independent integrity tags for each runtime font pack."""

    if len(pack_payloads) != PACK_COUNT:
        raise RuntimeError(f"expected {PACK_COUNT} pack payloads, got {len(pack_payloads)}")
    checksums: list[tuple[int, int]] = []
    for index, payload in enumerate(pack_payloads):
        if len(payload) != PACK_BYTES:
            raise RuntimeError(f"pack {index} has {len(payload)} bytes, expected {PACK_BYTES}")
        xor_value = 0
        sum_value = 0
        for value in payload:
            xor_value ^= value
            sum_value = (sum_value + value) & 0xFF
        checksums.append((xor_value, sum_value))
    return checksums


def build_font_preloader(pack_payloads: list[bytes]) -> bytes:
    """Load a string's one assigned font pack before drawing begins.

    Calling CD_READ from the glyph callback lets several IRQ frames elapse in
    the middle of the renderer.  The first draw is then corrupt even though a
    warm-cache redraw is correct.  Every patched speaker/UI record is assigned
    to exactly one pack, so scan the source string at the renderer entry and
    fill that pack before any glyph/VDC work starts.

    The hook replaces only ``LDA $3471`` at $66E5.  Return with that original
    result in A so execution can resume at the untouched ``STA $03``.
    """

    checksums = pack_cache_checksums(pack_payloads)
    a = common.Assembler(FONT_PRELOADER)
    a.emit(0xDA, 0x5A)  # PHX / PHY
    # $05/$06 hold the cache XOR and byte-sum while checking a warm pack.
    # They belong to the surrounding renderer, so preserve them across both
    # the integrity scan and a possible BIOS call.
    a.emit(0xA5, 0x05, 0x48, 0xA5, 0x06, 0x48)
    a.abs(0xAD, 0x3471)
    a.emit(0x85, 0x03)
    a.abs(0xAD, 0x3472)
    a.emit(0x85, 0x04)
    a.emit(0xA0, 0x00)  # LDY #0

    a.label("scan")
    a.emit(0xB1, 0x03)  # LDA ($03),Y
    a.emit(0xC9, 0xFF)
    a.branch(0xD0, "not_terminator")
    a.abs(0x4C, "done")
    a.label("not_terminator")
    a.emit(0xC9, 0xF0)
    a.branch(0x90, "next")
    a.emit(0xC9, 0xF7)
    a.branch(0xB0, "next")

    # Decode the custom lead into its even pack; a valid $80-$92 trail
    # selects the adjacent odd pack.  Requiring a valid trail prevents a
    # normal Shift-JIS trail byte in the F0-F6 range from being mistaken for
    # one of our custom characters.
    a.emit(0x38, 0xE9, 0xF0, 0x0A, 0xAA)  # SEC/SBC/ASL/TAX
    a.emit(0xC8)  # INY: inspect trail
    a.emit(0xB1, 0x03)
    a.emit(0xC9, 0x40)
    a.branch(0x90, "scan_limit")
    a.emit(0xC9, 0x40 + PACK_CAPACITY)
    a.branch(0x90, "pack_found")
    a.emit(0xC9, 0x80)
    a.branch(0x90, "scan_limit")
    a.emit(0xC9, 0x80 + PACK_CAPACITY)
    a.branch(0xB0, "scan_limit")
    a.emit(0xE8)  # INX: odd pack

    a.label("pack_found")
    a.emit(0x8A)  # TXA
    a.abs(0x8D, REQUEST_PACK)
    a.abs(0xCD, CURRENT_PACK)
    a.branch(0xD0, "load_pack")

    # CURRENT_PACK is only a tag.  The game reuses $5BE0-$5E3F as work RAM,
    # so the cache can be overwritten while that tag remains unchanged.
    # Verify all 608 bytes with independent XOR and byte-sum tags before
    # accepting a warm-cache hit.
    a.emit(0x64, 0x05, 0x64, 0x06)  # STZ $05 / STZ $06
    a.emit(0xA9, GLYPH_CACHE & 0xFF, 0x85, 0x03)
    a.emit(0xA9, GLYPH_CACHE >> 8, 0x85, 0x04)
    a.emit(0xA2, PACK_BYTES // 0x100, 0xA0, 0x00)  # LDX #2 / LDY #0

    a.label("checksum_page")
    a.emit(0xB1, 0x03, 0x45, 0x05, 0x85, 0x05)  # XOR byte
    a.emit(0xB1, 0x03, 0x18, 0x65, 0x06, 0x85, 0x06)  # SUM byte
    a.emit(0xC8)
    a.branch(0xD0, "checksum_page")
    a.emit(0xE6, 0x04, 0xCA)
    a.branch(0xD0, "checksum_page")

    a.emit(0xA0, 0x00)
    a.label("checksum_tail")
    a.emit(0xB1, 0x03, 0x45, 0x05, 0x85, 0x05)
    a.emit(0xB1, 0x03, 0x18, 0x65, 0x06, 0x85, 0x06)
    a.emit(0xC8, 0xC0, PACK_BYTES & 0xFF)
    a.branch(0x90, "checksum_tail")

    a.abs(0xAE, REQUEST_PACK)  # LDX $5BB4
    a.abs(0xBD, "xor_table")
    a.emit(0xC5, 0x05)
    a.branch(0xD0, "load_pack")
    a.abs(0xBD, "sum_table")
    a.emit(0xC5, 0x06)
    a.branch(0xF0, "done")

    a.label("load_pack")
    a.abs(0xAD, REQUEST_PACK)
    a.abs(0x20, FONT_LOADER)
    a.branch(0x80, "done")

    a.label("next")
    a.emit(0xC8)  # INY
    a.label("scan_limit")
    a.emit(0xC0, 0x40)  # never scan beyond 64 source bytes
    a.branch(0xB0, "done")
    a.abs(0x4C, "scan")

    a.label("done")
    a.emit(0x68, 0x85, 0x06, 0x68, 0x85, 0x05)  # restore $06/$05
    a.emit(0x7A, 0xFA)  # PLY / PLX
    a.abs(0xAD, 0x3471)  # recreate overwritten renderer instruction
    a.emit(0x60)

    a.label("xor_table")
    a.emit(*(xor_value for xor_value, _ in checksums))
    a.label("sum_table")
    a.emit(*(sum_value for _, sum_value in checksums))
    return a.finish()


def build_font_wrapper() -> bytes:
    a = common.Assembler(FONT_WRAPPER)
    a.emit(0xA5, 0xF9, 0xC9, 0xF0)
    a.branch(0xB0, "lead_min_ok")
    # Tail-call the original routine so its RTS returns directly to $648F.
    a.abs(0x4C, 0x69C2)
    a.label("lead_min_ok")
    a.emit(0xC9, 0xF7)
    a.branch(0x90, "lead_max_ok")
    # This check is too far from the shared fallback after adding F041.
    # Tail-call the original routine directly for leads >= F7.
    a.abs(0x4C, 0x69C2)
    a.label("lead_max_ok")

    # F040 is the approved static compact period and F041 is a dedicated
    # blank spacing glyph. Neither requires a CD font-pack read.
    a.emit(0xC9, 0xF0)
    a.branch(0xD0, "normal_code")
    a.emit(0xA5, 0xF8, 0xC9, 0x40)
    a.branch(0xF0, "period")
    a.emit(0xC9, 0x41)
    a.branch(0xF0, "blank")

    a.label("normal_code")
    # Two packs share each safe lead byte.  X receives the even pack number;
    # trail $80-$92 selects the adjacent odd pack.
    a.emit(0xA5, 0xF9, 0x38, 0xE9, 0xF0, 0x0A, 0xAA)
    a.emit(0xA5, 0xF8, 0xC9, 0x80)
    a.branch(0xB0, "odd_pack")

    a.emit(0xC9, 0x40)
    a.branch(0x90, "fallback")
    a.emit(0xE0, 0x00)
    a.branch(0xD0, "even_pack")
    a.emit(0xC9, 0x41)
    a.branch(0x90, "fallback")
    a.emit(0xC9, 0x41 + PACK_CAPACITY)
    a.branch(0xB0, "fallback")
    a.emit(0x38, 0xE9, 0x41)
    a.branch(0x80, "have_index")

    a.label("even_pack")
    a.emit(0xC9, 0x40 + PACK_CAPACITY)
    a.branch(0xB0, "fallback")
    a.emit(0x38, 0xE9, 0x40)
    a.branch(0x80, "have_index")

    a.label("odd_pack")
    a.emit(0xC9, 0x80 + PACK_CAPACITY)
    a.branch(0xB0, "fallback")
    a.emit(0x38, 0xE9, 0x80, 0xE8)

    a.label("have_index")
    a.emit(0x48)  # glyph index
    a.emit(0x8A)  # TXA: decoded pack index
    a.abs(0xCD, CURRENT_PACK)
    a.branch(0xF0, "cache_ready")
    a.emit(0x8A)
    a.abs(0x20, FONT_LOADER)
    a.emit(0x8A)
    a.abs(0xCD, CURRENT_PACK)
    a.branch(0xD0, "load_failed")

    a.label("cache_ready")
    a.emit(0x68, 0x48)  # retrieve index, keep a second copy
    a.emit(0x18, 0x69, 0x07)
    a.emit(0x4A, 0x4A, 0x4A)
    a.emit(0x18, 0x69, GLYPH_CACHE >> 8, 0x85, 0x01)
    a.emit(0x68)
    a.emit(0x0A, 0x0A, 0x0A, 0x0A, 0x0A)
    a.emit(0x18, 0x69, GLYPH_CACHE & 0xFF, 0x85, 0x00)
    a.emit(0x82)
    a.abs(0x20, 0x69FC)
    a.emit(0x62, 0x60)

    a.label("load_failed")
    a.emit(0x68)  # discard glyph index
    a.branch(0x80, "fallback")

    a.label("period")
    a.emit(0xA9, PERIOD_GLYPH & 0xFF, 0x85, 0x00)
    a.emit(0xA9, PERIOD_GLYPH >> 8, 0x85, 0x01, 0x82)
    a.abs(0x20, 0x69FC)
    a.emit(0x62, 0x60)

    a.label("blank")
    a.emit(0xA9, BLANK_GLYPH & 0xFF, 0x85, 0x00)
    a.emit(0xA9, BLANK_GLYPH >> 8, 0x85, 0x01, 0x82)
    a.abs(0x20, 0x69FC)
    a.emit(0x62, 0x60)

    a.label("fallback")
    a.abs(0x20, 0x69C2)
    a.emit(0x60)
    return a.finish()


def fit_record(encoded: bytes, original: bytes, label: str) -> bytes:
    if len(encoded) > len(original):
        raise RuntimeError(f"{label}: {len(encoded)} bytes exceeds {len(original)}")
    return encoded + bytes((0xFF,)) * (len(original) - len(encoded))


def build(version: str, force: bool) -> Path:
    output_dir = BUILD_ROOT / version
    if output_dir.exists():
        if not force:
            raise SystemExit(f"build already exists: {output_dir} (use --force)")
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)

    if sha256_file(SOURCE_TRACK02) != EXPECTED_TRACK02_SHA256:
        raise RuntimeError("unexpected Track 02 SHA-256")
    if sha256_file(SOURCE_TRACK24) != EXPECTED_TRACK24_SHA256:
        raise RuntimeError("unexpected Track 24 SHA-256")

    items, deferred = load_items()
    if sum(item.kind == "speaker" for item in items) != 40:
        raise RuntimeError("expected 40 in-place speaker rows")
    if sum(item.kind == "ui" for item in items) != 40:
        raise RuntimeError("expected 40 in-place UI rows")
    packs, item_to_pack = assign_packs(items)
    pack_payloads, custom_by_item, font_rows = build_font_packs(packs)
    cache_checksums = pack_cache_checksums(pack_payloads)

    starts, original_disc_sectors = track24.disc_track_starts()
    track24_start = starts[24]
    track24_sectors = SOURCE_TRACK24.stat().st_size // common.RAW_SECTOR_SIZE
    first_appended_lba = track24_start + track24_sectors
    if first_appended_lba != original_disc_sectors:
        raise RuntimeError("Track 24 is not the final source track")
    track02_index1_lba = starts[2] + 225
    track24_index1_lba = starts[24] + 225
    relative_sector = first_appended_lba - track24_index1_lba

    loader_code = build_font_loader(
        relative_sector,
        track24_index1_lba,
        track02_index1_lba,
    )
    preloader_code = build_font_preloader(pack_payloads)
    wrapper_code = build_font_wrapper()
    if FONT_LOADER + len(loader_code) > FONT_PRELOADER:
        raise RuntimeError("font loader exceeds bank-68 cave")
    if FONT_PRELOADER + len(preloader_code) > 0x6000:
        raise RuntimeError("font preloader exceeds bank-68 cave")
    if FONT_WRAPPER + len(wrapper_code) > 0x8000:
        raise RuntimeError("font wrapper exceeds bank-6A cave")
    if GLYPH_CACHE + PACK_BYTES > FONT_LOADER:
        raise RuntimeError("font cache overlaps font loader")

    period = bytes(24) + bytes((0x0C, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00))
    blank = bytes(32)
    patches: list[common.Patch] = [
        common.Patch(
            "font_call",
            common.bank6a_iso(common.FONT_CALL_CPU),
            common.ORIGINAL_FONT_CALL,
            bytes((0x20, FONT_WRAPPER & 0xFF, FONT_WRAPPER >> 8)),
            common.FONT_CALL_CPU,
        ),
        common.Patch(
            "font_preload_call",
            common.bank6a_iso(RENDERER_ENTRY),
            ORIGINAL_RENDERER_ENTRY,
            bytes((0x20, FONT_PRELOADER & 0xFF, FONT_PRELOADER >> 8)),
            RENDERER_ENTRY,
        ),
        common.Patch(
            "blank_space",
            common.bank68_iso(BLANK_GLYPH),
            bytes((0x00,)) * len(blank),
            blank,
            BLANK_GLYPH,
        ),
        common.Patch(
            "compact_period",
            common.bank68_iso(PERIOD_GLYPH),
            bytes((0xFF,)) * len(period),
            period,
            PERIOD_GLYPH,
        ),
        common.Patch(
            "track24_font_loader",
            common.bank68_iso(FONT_LOADER),
            bytes((0xFF,)) * len(loader_code),
            loader_code,
            FONT_LOADER,
        ),
        common.Patch(
            "font_pack_preloader",
            common.bank68_iso(FONT_PRELOADER),
            bytes((0xFF,)) * len(preloader_code),
            preloader_code,
            FONT_PRELOADER,
        ),
        common.Patch(
            "font_pack_wrapper",
            common.bank6a_iso(FONT_WRAPPER),
            bytes((0xFF,)) * len(wrapper_code),
            wrapper_code,
            FONT_WRAPPER,
        ),
    ]

    applied_rows: list[dict[str, str]] = []
    for item in sorted(items, key=lambda value: value.key):
        encoded = encode_game_text(item.ko_text, custom_by_item[item.key])
        old = item.jp_text.encode("cp932") + b"\xFF"
        replacement = fit_record(encoded, old, item.key)
        if item.kind == "speaker":
            offsets = [int(item.row["disc_offset"], 16) + 1]
        else:
            offsets = ui_disc_offsets(item.row)
        for occurrence, offset in enumerate(offsets, start=1):
            patches.append(
                common.Patch(
                    f"{item.kind}_{item.row_id}_{occurrence:03d}",
                    offset,
                    old,
                    replacement,
                )
            )
        applied_rows.append(
            {
                "kind": item.kind,
                "id": item.row_id,
                "pack": str(item_to_pack[item.key]),
                "occurrences": str(len(offsets)),
                "jp_text": item.jp_text,
                "ko_text": item.ko_text,
                "original_bytes": str(len(old)),
                "korean_bytes": str(len(encoded)),
                "encoded_hex": encoded.hex(" ").upper(),
            }
        )

    # Refuse overlapping static records; each exact source byte may be patched once.
    occupied: dict[int, str] = {}
    for patch in patches:
        for offset in range(patch.iso_offset, patch.iso_offset + len(patch.old)):
            previous = occupied.get(offset)
            if previous is not None:
                raise RuntimeError(f"patch overlap at ${offset:06X}: {previous}, {patch.name}")
            occupied[offset] = patch.name
        actual = proof.read_user_bytes(SOURCE_TRACK02, patch.iso_offset, len(patch.old))
        if actual != patch.old:
            raise RuntimeError(f"preflight mismatch for {patch.name} at ${patch.iso_offset:06X}")

    patched02_path = output_dir / f"Snatcher CD-ROMantic (Japan) (Track 02) [KO {version}].bin"
    modified02 = proof.apply_patches_streaming(SOURCE_TRACK02, patched02_path, patches)

    patched24_path = output_dir / f"Snatcher CD-ROMantic (Japan) (Track 24) [KO {version}].bin"
    shutil.copyfile(SOURCE_TRACK24, patched24_path)
    appended = bytearray()
    for index in range(APPENDED_SECTORS):
        lba = first_appended_lba + index
        payload = pack_payloads[index] if index < len(pack_payloads) else bytes()
        sector = track24.make_mode1_sector(lba, payload)
        track24.verify_mode1_sector(sector, lba)
        appended.extend(sector)
    with patched24_path.open("ab") as handle:
        handle.write(appended)
    if patched24_path.stat().st_size != SOURCE_TRACK24.stat().st_size + len(appended):
        raise RuntimeError("extended Track 24 size mismatch")

    cue_path = output_dir / f"Snatcher CD-ROMantic (Japan) [KO {version}].cue"
    staged = track24.stage_cue(cue_path, patched02_path, patched24_path)

    write_tsv(output_dir / "speaker_ui_applied.tsv", applied_rows)
    write_tsv(output_dir / "speaker_ui_deferred.tsv", deferred)
    write_tsv(output_dir / "hangul_code_map.tsv", font_rows)
    pack_rows: list[dict[str, str]] = []
    for pack in packs:
        members = tuple(pack["members"])  # type: ignore[arg-type]
        glyphs = tuple(pack["glyphs"])  # type: ignore[arg-type]
        pack_rows.append(
            {
                "pack": str(pack["index"]),
                "lead_byte": f"{0xF0 + int(pack['index']) // 2:02X}",
                "trail_range": (
                    f"{0x80:02X}-{0x80 + len(glyphs) - 1:02X}"
                    if int(pack["index"]) % 2
                    else f"{(0x41 if int(pack['index']) == 0 else 0x40):02X}-"
                    f"{(0x41 if int(pack['index']) == 0 else 0x40) + len(glyphs) - 1:02X}"
                ),
                "context": str(pack["context"]),
                "glyph_count": str(len(glyphs)),
                "glyphs": "".join(glyphs),
                "member_count": str(len(members)),
                "members": ",".join(member.key for member in members),
                "track24_lba": str(first_appended_lba + int(pack["index"])),
                "relative_sector": f"{relative_sector + int(pack['index']):06X}",
                "cache_xor": f"{cache_checksums[int(pack['index'])][0]:02X}",
                "cache_sum": f"{cache_checksums[int(pack['index'])][1]:02X}",
            }
        )
    write_tsv(output_dir / "font_packs.tsv", pack_rows)

    patch_rows = [
        {
            "name": patch.name,
            "cpu_address": f"{patch.cpu_address:04X}" if patch.cpu_address is not None else "",
            "iso_offset": f"{patch.iso_offset:06X}",
            "raw_offset": f"{common.raw_user_offset(patch.iso_offset):08X}",
            "length": str(len(patch.new)),
            "old_hex": patch.old.hex(" ").upper(),
            "new_hex": patch.new.hex(" ").upper(),
        }
        for patch in patches
    ]
    write_tsv(output_dir / "track02_patches.tsv", patch_rows)
    (output_dir / "track24_font_packs.bin").write_bytes(b"".join(pack_payloads))
    (output_dir / "track24_appended_raw.bin").write_bytes(appended)
    shutil.copyfile(
        STATIC_DIR / "DIAGNOSE_CACHE_REPAIR.lua",
        output_dir / "DIAGNOSE_CACHE_REPAIR.lua",
    )

    manifest = {
        "version": version,
        "status": "speaker-ui-batch-track24-font-packs",
        "source_track02_sha256": EXPECTED_TRACK02_SHA256,
        "source_track24_sha256": EXPECTED_TRACK24_SHA256,
        "patched_track02_sha256": sha256_file(patched02_path),
        "patched_track24_sha256": sha256_file(patched24_path),
        "cue": cue_path.name,
        "cue_tracks": staged,
        "speaker_rows_applied": sum(item.kind == "speaker" for item in items),
        "ui_rows_applied": sum(item.kind == "ui" for item in items),
        "speaker_rows_deferred": sum(row["kind"] == "speaker" for row in deferred),
        "ui_rows_deferred": sum(row["kind"] == "ui" for row in deferred),
        "static_string_occurrences": sum(int(row["occurrences"]) for row in applied_rows),
        "font_pack_count": len(pack_payloads),
        "font_pack_capacity": PACK_CAPACITY,
        "font_pack_bytes": PACK_BYTES,
        "font_cache_integrity": {
            "algorithm": "xor8+sum8 over all 608 cache bytes",
            "checksums": [
                {"pack": index, "xor": f"{xor_value:02X}", "sum": f"{sum_value:02X}"}
                for index, (xor_value, sum_value) in enumerate(cache_checksums)
            ],
        },
        "menu_glyph_y_shift": -1,
        "first_appended_lba": first_appended_lba,
        "relative_sector": relative_sector,
        "track02_index1_lba": track02_index1_lba,
        "track24_index1_lba": track24_index1_lba,
        "font_loader_bytes": len(loader_code),
        "font_preloader_bytes": len(preloader_code),
        "font_wrapper_bytes": len(wrapper_code),
        "modified_track02_sectors": [f"{value:06X}" for value in sorted(modified02)],
    }
    (output_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    (output_dir / "verification.txt").write_text(
        "\n".join(
            [
                f"Snatcher Korean patch {version} - speaker/UI batch",
                "",
                f"Applied speaker rows: {manifest['speaker_rows_applied']}",
                f"Applied UI rows: {manifest['ui_rows_applied']}",
                f"Patched string occurrences: {manifest['static_string_occurrences']}",
                f"Deferred speaker rows: {manifest['speaker_rows_deferred']}",
                f"Deferred UI rows: {manifest['ui_rows_deferred']}",
                f"Font packs: {len(pack_payloads)} x {PACK_BYTES} bytes",
                f"Loader bytes: {len(loader_code)}",
                f"Preloader bytes: {len(preloader_code)}",
                f"Wrapper bytes: {len(wrapper_code)}",
                "",
                "Static verification passed:",
                "- both pristine track hashes matched",
                "- all original speaker/UI signatures matched",
                "- every applied Korean record fits its original allocation",
                "- no Track 02 patches overlap",
                "- every appended Track 24 sector has regenerated EDC/ECC",
                "- all 24 CUE tracks were staged",
                "",
            ]
        ),
        encoding="utf-8",
    )
    (output_dir / "TEST_IN_MESEN.txt").write_text(
        "\n".join(
            [
                f"Snatcher Korean patch {version} - speaker/UI batch runtime test",
                "",
                f"Open: {cue_path}",
                "Stop every Lua script, power-cycle, and do not reuse an old save state.",
                "",
                "Expected:",
                "1. Reception speaker name remains the approved Korean placement.",
                "2. Reception action menu shows Korean entries with the approved -1px UI baseline.",
                "3. Visit several other menus/speakers; short reviewed records appear in Korean.",
                "4. Longer deferred records remain Japanese in this build.",
                "5. Dialogue/menu progression, colors, cursor, and audio remain normal.",
                "6. Open another action, return, and redraw the same menu repeatedly; glyphs stay intact.",
                "7. Applied Korean strings containing spaces show visible full-cell word gaps.",
                "",
                "The first custom glyph of a different pack may cause a short CD access.",
                "Report the exact menu/speaker if text is blank, garbled, or the game pauses.",
                "",
            ]
        ),
        encoding="utf-8",
    )
    return output_dir


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default="0.1.15")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    print(f"built: {build(args.version, args.force)}")


if __name__ == "__main__":
    main()
