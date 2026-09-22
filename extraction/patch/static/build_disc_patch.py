"""Build a reproducible on-disc Korean proof patch for Snatcher PCE CD.

The proof builder reads one selected translation directly from the canonical
UTF-8 master instead of carrying a second hard-coded copy.  It replaces that
dialogue after the game's original decoder has produced Shift-JIS and installs
the proven Galmuri11 caller hook for the Hangul codes used by the translation.

The original dump is never modified.  A complete patched Track 02 and a CUE
that references the untouched original audio/data tracks are written below
``build/patch/<version>``.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(r"C:\snatcher")
ROM_DIR = ROOT / "rom(japan)" / "Snatcher CD-ROMantic (Japan)"
SOURCE_TRACK = ROM_DIR / "Snatcher CD-ROMantic (Japan) (Track 02).bin"
SOURCE_CUE = ROM_DIR / "Snatcher CD-ROMantic (Japan).cue"
FONT_BDF = ROOT / "extraction" / "font_research" / "Galmuri11.bdf"
TRANSLATION_MASTER = ROOT / "extraction" / "translation" / "ko_master.tsv"
TRANSLATION_VALIDATOR = ROOT / "extraction" / "translation" / "validate_ko_master.py"
OVERLAY_COMPILER = ROOT / "extraction" / "translation" / "compile_overlay_assets.py"
BUILD_ROOT = ROOT / "build" / "patch"

sys.path.insert(0, str(TRANSLATION_MASTER.parent))
from layout_markup import BREAK, fe_parameter, iter_layout_units, split_layout_lines  # noqa: E402
from source_text_markup import split_source_runtime_segments  # noqa: E402

EXPECTED_SOURCE_SHA256 = "A222652F408653B2F0962DAE8BF6B8242D83FBFBD0E059975DCA82D7D576A028"

RAW_SECTOR_SIZE = 2352
USER_DATA_OFFSET = 16
USER_DATA_SIZE = 2048

# Renderer module mappings proven against CPUMEMORY_TOTAL.dmp.
BANK68_ISO_BASE = 0x07B800  # CPU $4000-$5FFF
BANK6A_ISO_BASE = 0x07F800  # CPU $6000-$7FFF

CAVE_CPU_START = 0x5C67
CAVE_CPU_END = 0x6000
GLYPH_BASE = 0x5C80
SEGMENT_TEXT_CAPACITY = 0x20
SEGMENT_SIGNATURE_LENGTH = 0x10
OVERLAY_RECORD_SIZE = SEGMENT_SIGNATURE_LENGTH + 2
FONT_WRAPPER = 0x5F40
OVERLAY_HOOK = 0x5F80
RUNTIME_DATA_LIMIT = FONT_WRAPPER
KOREAN_TEXT_CAPACITY = 0x40

FONT_CALL_CPU = 0x648C
RENDERER_ENTRY_CPU = 0x66E5

ORIGINAL_FONT_CALL = bytes.fromhex("20 C2 69")
ORIGINAL_RENDERER_ENTRY = bytes.fromhex("AD 71 34 85 03 AD 72 34 85 04")

DEFAULT_TEXT_KEY = "111800:250A"
PATCHABLE_STATUS = {"draft", "review", "final"}
EMPTY_TOKEN = "{EMPTY}"


@dataclass(frozen=True)
class TranslationEntry:
    text_key: str
    jp_text: str
    ko_text: str
    status: str
    note: str


@dataclass
class RuntimeSegment:
    text_key: str
    line_no: int
    jp_text: str
    ko_text: str
    after_control: str
    encoded: bytes
    signature: bytes
    text_address: int = 0


def load_translation_entry(text_key: str, ko_override: str | None = None) -> TranslationEntry:
    with TRANSLATION_MASTER.open("r", encoding="utf-8-sig", newline="") as handle:
        matches = [
            row
            for row in csv.DictReader(handle, delimiter="\t")
            if row["text_key"].upper() == text_key.upper()
        ]
    if len(matches) != 1:
        raise RuntimeError(f"translation key must match exactly one row: {text_key} ({len(matches)} matches)")
    row = matches[0]
    if ko_override is None and row["status"] not in PATCHABLE_STATUS:
        raise RuntimeError(
            f"{text_key} status {row['status']!r} is not patchable; "
            f"use one of {sorted(PATCHABLE_STATUS)}"
        )
    ko_text = ko_override if ko_override is not None else row["ko_text"]
    if not ko_text:
        raise RuntimeError(f"{text_key} has no Korean translation")
    return TranslationEntry(
        text_key=row["text_key"],
        jp_text=row["jp_text"],
        ko_text=ko_text,
        status="proof_override" if ko_override is not None else row["status"],
        note=(
            f"0.0.8 runtime-table proof override; source note: {row['note']}"
            if ko_override is not None
            else row["note"]
        ),
    )


def ordered_hangul(text: str) -> tuple[str, ...]:
    return tuple(dict.fromkeys(char for char in text if 0xAC00 <= ord(char) <= 0xD7A3))


def sha256(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def align(value: int, boundary: int = 0x10) -> int:
    return (value + boundary - 1) & ~(boundary - 1)


def cpu_to_iso(cpu_address: int, bank_base: int, cpu_base: int) -> int:
    return bank_base + cpu_address - cpu_base


def bank68_iso(cpu_address: int) -> int:
    if not 0x4000 <= cpu_address < 0x6000:
        raise ValueError(f"not in CPU bank-68 window: ${cpu_address:04X}")
    return cpu_to_iso(cpu_address, BANK68_ISO_BASE, 0x4000)


def bank6a_iso(cpu_address: int) -> int:
    if not 0x6000 <= cpu_address < 0x8000:
        raise ValueError(f"not in CPU bank-6A window: ${cpu_address:04X}")
    return cpu_to_iso(cpu_address, BANK6A_ISO_BASE, 0x6000)


class Assembler:
    """Tiny label-aware assembler for the handful of HuC6280 opcodes used."""

    def __init__(self, origin: int):
        self.origin = origin
        self.data = bytearray()
        self.labels: dict[str, int] = {}
        self.fixups: list[tuple[str, int, str]] = []

    @property
    def pc(self) -> int:
        return self.origin + len(self.data)

    def label(self, name: str) -> None:
        if name in self.labels:
            raise ValueError(f"duplicate label: {name}")
        self.labels[name] = self.pc

    def emit(self, *values: int) -> None:
        self.data.extend(value & 0xFF for value in values)

    def word(self, value: int) -> None:
        self.emit(value, value >> 8)

    def abs(self, opcode: int, target: int | str) -> None:
        self.emit(opcode)
        if isinstance(target, str):
            pos = len(self.data)
            self.emit(0, 0)
            self.fixups.append(("abs", pos, target))
        else:
            self.word(target)

    def branch(self, opcode: int, target: str) -> None:
        self.emit(opcode)
        pos = len(self.data)
        self.emit(0)
        self.fixups.append(("rel", pos, target))

    def finish(self) -> bytes:
        for kind, pos, name in self.fixups:
            if name not in self.labels:
                raise ValueError(f"undefined label: {name}")
            target = self.labels[name]
            if kind == "abs":
                self.data[pos] = target & 0xFF
                self.data[pos + 1] = target >> 8
            else:
                next_pc = self.origin + pos + 1
                delta = target - next_pc
                if not -128 <= delta <= 127:
                    raise ValueError(f"branch out of range: {name} ({delta})")
                self.data[pos] = delta & 0xFF
        return bytes(self.data)


def build_font_wrapper(glyph_count: int) -> bytes:
    """F040.. -> selected glyphs at GLYPH_BASE; other codes -> original $69C2."""

    if not 1 <= glyph_count <= 0x3F:
        raise RuntimeError(f"proof font wrapper supports 1-63 Hangul glyphs, got {glyph_count}")

    a = Assembler(FONT_WRAPPER)
    a.emit(0xA5, 0xF9)  # LDA $F9 (lead byte)
    a.emit(0xC9, 0xF0)  # CMP #$F0
    a.branch(0xD0, "fallback")
    a.emit(0xA5, 0xF8)  # LDA $F8 (trail byte)
    a.emit(0xC9, 0x40)
    a.branch(0x90, "fallback")
    a.emit(0xC9, 0x40 + glyph_count)
    a.branch(0xB0, "fallback")
    a.emit(0x38, 0xE9, 0x40)  # SEC / SBC #$40 -> glyph index
    a.emit(0x48)  # PHA
    a.emit(0x18, 0x69, 0x04)  # CLC / ADC #4
    a.emit(0x4A, 0x4A, 0x4A)  # high increment = (index + 4) >> 3
    a.emit(0x18, 0x69, GLYPH_BASE >> 8)
    a.emit(0x85, 0x01)  # STA $01
    a.emit(0x68)  # PLA
    a.emit(0x0A, 0x0A, 0x0A, 0x0A, 0x0A)  # index * 32
    a.emit(0x18, 0x69, GLYPH_BASE & 0xFF)
    a.emit(0x85, 0x00)  # STA $00
    a.emit(0x82)  # CLX, matching the original cache path
    a.abs(0x20, 0x69FC)  # JSR $69FC
    a.emit(0x62, 0x60)  # CLA / RTS
    a.label("fallback")
    a.abs(0x20, 0x69C2)
    a.emit(0x60)
    return a.finish()


def build_overlay_hook(record_count: int, table_address: int) -> bytes:
    """Reproduce $66E5 and search the exact-source overlay table.

    The successful live POCs intercept the renderer only when its active
    pointer reaches the completed narrative buffer at $3619.  The former
    static proof patched $63AA and compared ($FE), but $FE can still point at
    the surrounding header/control stream there, so its signature never
    matched the visible sentence.
    """

    a = Assembler(OVERLAY_HOOK)
    # Recreate the ten bytes replaced at $66E5.
    a.abs(0xAD, 0x3471)
    a.emit(0x85, 0x03)
    a.abs(0xAD, 0x3472)
    a.emit(0x85, 0x04)

    # Only inspect a newly started narrative buffer.
    a.emit(0xC9, 0x36)  # A still contains $3472
    a.branch(0xD0, "done")
    a.emit(0xA5, 0x03)
    a.emit(0xC9, 0x19)
    a.branch(0xD0, "done")

    if not 1 <= record_count <= 0xFF:
        raise RuntimeError(f"overlay table supports 1-255 records, got {record_count}")

    # Save the scratch zero-page bytes and Y.  The original renderer entry
    # only owns $03/$04, so a table miss must leave all other state intact.
    a.emit(0x5A)  # PHY
    for address in (0x05, 0x06, 0x07):
        a.emit(0xA5, address, 0x48)  # LDA zp / PHA

    a.emit(0xA9, table_address & 0xFF, 0x85, 0x05)
    a.emit(0xA9, table_address >> 8, 0x85, 0x06)
    a.emit(0xA9, record_count, 0x85, 0x07)

    a.label("next_record")
    a.emit(0xA0, 0x00)  # LDY #0
    a.label("compare")
    a.emit(0xB1, 0x03)  # LDA ($03),Y
    a.emit(0xD1, 0x05)  # CMP ($05),Y
    a.branch(0xD0, "no_match")
    a.emit(0xC8)  # INY
    a.emit(0xC0, SEGMENT_SIGNATURE_LENGTH)
    a.branch(0xD0, "compare")

    # The two bytes after the signature are the little-endian replacement
    # pointer.  Redirect both the persistent renderer pointer and $03/$04,
    # which the original instruction immediately following this hook reads.
    a.emit(0xB1, 0x05)  # LDA ($05),Y -- target low
    a.emit(0x85, 0x03)
    a.abs(0x8D, 0x3471)
    a.emit(0xC8)
    a.emit(0xB1, 0x05)  # LDA ($05),Y -- target high
    a.emit(0x85, 0x04)
    a.abs(0x8D, 0x3472)
    a.abs(0x4C, "restore_scratch")

    a.label("no_match")
    # Advance the table pointer to the next fixed-size record.
    a.emit(0x18, 0xA5, 0x05, 0x69, OVERLAY_RECORD_SIZE, 0x85, 0x05)
    a.emit(0xA5, 0x06, 0x69, 0x00, 0x85, 0x06)
    a.emit(0xC6, 0x07)  # DEC $07
    a.branch(0xD0, "next_record")

    a.label("restore_scratch")
    for address in (0x07, 0x06, 0x05):
        a.emit(0x68, 0x85, address)  # PLA / STA zp
    a.emit(0x7A)  # PLY
    a.label("done")
    a.emit(0x60)
    return a.finish()


def parse_bdf(path: Path, wanted: set[int]) -> dict[int, tuple[tuple[int, int, int, int], list[str]]]:
    found: dict[int, tuple[tuple[int, int, int, int], list[str]]] = {}
    lines = path.read_text(encoding="utf-8").splitlines()
    index = 0
    while index < len(lines):
        if not lines[index].startswith("STARTCHAR"):
            index += 1
            continue
        encoding = None
        bbx = None
        bitmap: list[str] = []
        index += 1
        while index < len(lines) and lines[index] != "ENDCHAR":
            line = lines[index]
            if line.startswith("ENCODING "):
                encoding = int(line.split()[1])
            elif line.startswith("BBX "):
                _, width, height, xoff, yoff = line.split()
                bbx = (int(width), int(height), int(xoff), int(yoff))
            elif line == "BITMAP":
                index += 1
                while index < len(lines) and lines[index] != "ENDCHAR":
                    bitmap.append(lines[index])
                    index += 1
                continue
            index += 1
        if encoding in wanted and bbx is not None:
            found[encoding] = (bbx, bitmap)
        index += 1
    return found


def glyph_1bpp_left_shifted(bbx: tuple[int, int, int, int], bitmap: list[str]) -> bytes:
    width, height, xoff, yoff = bbx
    canvas = [[0] * 16 for _ in range(16)]
    # Galmuri's BBX y offset is relative to the baseline.  Centering every
    # bitmap independently made shorter glyphs such as U+BCF4 '보'
    # (10 pixels high, yoff=1) begin one row below ordinary 11-pixel Hangul.
    # A fixed baseline keeps those glyphs aligned without moving the already
    # approved yoff=0 glyphs such as '다', '묻', '안', '내', and '원'.
    y_start = 13 - height - yoff
    x_start = max(0, xoff)
    for row_index, row_hex in enumerate(bitmap):
        row_bits = []
        for value in bytes.fromhex(row_hex):
            row_bits.extend((value >> bit) & 1 for bit in range(7, -1, -1))
        for column, pixel in enumerate(row_bits[:width]):
            y = y_start + row_index
            x = x_start + column
            if 0 <= y < 16 and 0 <= x < 16:
                canvas[y][x] = pixel

    # Preserve every BDF scanline.  The former V17 proof cropped the final
    # scanline to investigate stray VRAM dots, but that row contains legitimate
    # bottom strokes in normal Hangul (e.g. 는/본/입/슨/신).  Cropping it made
    # persistent builds look one pixel short at the baseline.

    encoded = bytearray()
    for row in canvas:
        value = 0
        for pixel in row:
            value = (value << 1) | pixel
        # Reproduce V17's approved byte layout exactly.  In the game's
        # MSB-first row format this is the BDF scanline shifted right once.
        value >>= 1
        encoded.extend((value >> 8, value & 0xFF))
    return bytes(encoded)


def build_glyph_pack(hangul_glyphs: tuple[str, ...]) -> tuple[bytes, list[dict[str, str]]]:
    found = parse_bdf(FONT_BDF, {ord(char) for char in hangul_glyphs})
    missing = [char for char in hangul_glyphs if ord(char) not in found]
    if missing:
        raise RuntimeError(f"missing Galmuri11 glyphs: {missing}")
    pack = bytearray()
    mapping = []
    for index, char in enumerate(hangul_glyphs):
        glyph = glyph_1bpp_left_shifted(*found[ord(char)])
        if len(glyph) != 32:
            raise RuntimeError(f"bad glyph size for {char}: {len(glyph)}")
        pack.extend(glyph)
        mapping.append(
            {
                "index": str(index),
                "game_code": f"F0{0x40 + index:02X}",
                "unicode": f"U+{ord(char):04X}",
                "character": char,
                "cpu_address": f"{GLYPH_BASE + index * 32:04X}",
            }
        )
    return bytes(pack), mapping


def build_korean_game_string(text: str, hangul_glyphs: tuple[str, ...]) -> bytes:
    if text.strip() == EMPTY_TOKEN:
        return b"\xFF"
    if EMPTY_TOKEN in text:
        raise ValueError(f"{EMPTY_TOKEN} must occupy the entire Korean text segment")

    code = {char: bytes((0xF0, 0x40 + index)) for index, char in enumerate(hangul_glyphs)}
    output = bytearray()
    for char in iter_layout_units(text):
        if char is BREAK:
            output.append(0xFD)  # confirmed renderer line break
            continue
        parameter = fe_parameter(char)
        if parameter is not None:
            output.extend((0xFE, parameter))
            continue
        if char in code:
            output.extend(code[char])
        elif char == ".":
            output.extend(b"\x81\x42")  # existing full-width period
        elif char == "?":
            output.extend(b"\x81\x48")  # existing full-width question mark
        else:
            output.extend(char.encode("cp932"))
    output.append(0xFF)
    return bytes(output)


def make_edc_ecc_tables() -> tuple[list[int], list[int], list[int]]:
    edc_lut: list[int] = []
    ecc_f = [0] * 256
    ecc_b = [0] * 256
    for value in range(256):
        shifted = ((value << 1) ^ (0x11D if value & 0x80 else 0)) & 0xFF
        ecc_f[value] = shifted
        ecc_b[value ^ shifted] = value
    for value in range(256):
        current = value
        for _ in range(8):
            current = (current >> 1) ^ (0xD8018001 if current & 1 else 0)
        edc_lut.append(current & 0xFFFFFFFF)
    return edc_lut, ecc_f, ecc_b


EDC_LUT, ECC_F, ECC_B = make_edc_ecc_tables()


def compute_edc(data: bytes | bytearray) -> int:
    result = 0
    for value in data:
        result = (result >> 8) ^ EDC_LUT[(result ^ value) & 0xFF]
    return result


def compute_ecc(
    source: bytes | bytearray,
    major_count: int,
    minor_count: int,
    major_mult: int,
    minor_inc: int,
) -> bytes:
    size = major_count * minor_count
    output = bytearray(major_count * 2)
    for major in range(major_count):
        index = (major >> 1) * major_mult + (major & 1)
        ecc_a = 0
        ecc_b = 0
        for _ in range(minor_count):
            value = source[index]
            index += minor_inc
            if index >= size:
                index -= size
            ecc_a ^= value
            ecc_b ^= value
            ecc_a = ECC_F[ecc_a]
        ecc_a = ECC_B[ECC_F[ecc_a] ^ ecc_b]
        output[major] = ecc_a
        output[major + major_count] = ecc_a ^ ecc_b
    return bytes(output)


def rebuild_mode1_sector(sector: bytearray) -> None:
    if len(sector) != RAW_SECTOR_SIZE or sector[15] != 1:
        raise RuntimeError("patch target is not a standard Mode-1/2352 sector")
    sector[0x810:0x814] = compute_edc(sector[:0x810]).to_bytes(4, "little")
    sector[0x814:0x81C] = bytes(8)
    p_parity = compute_ecc(sector[0x0C:0x81C], 86, 24, 2, 86)
    sector[0x81C:0x8C8] = p_parity
    q_source = sector[0x0C:0x81C] + p_parity
    sector[0x8C8:0x930] = compute_ecc(q_source, 52, 43, 86, 88)


@dataclass(frozen=True)
class Patch:
    name: str
    iso_offset: int
    old: bytes
    new: bytes
    cpu_address: int | None = None


def raw_user_offset(iso_offset: int) -> int:
    sector, within = divmod(iso_offset, USER_DATA_SIZE)
    return sector * RAW_SECTOR_SIZE + USER_DATA_OFFSET + within


def make_cue(output_path: Path, patched_track: Path) -> list[dict[str, str | int]]:
    """Create a self-contained local test set.

    Mesen does not reliably open a multi-file CUE whose FILE entries point to
    absolute paths.  Place every untouched track beside the patched Track 02.
    Hard links avoid duplicating roughly 600 MiB; copying is a safe fallback
    when the source and build folder are on different volumes.
    """

    lines = SOURCE_CUE.read_text(encoding="ascii").splitlines()
    rendered: list[str] = []
    staged: list[dict[str, str | int]] = []
    pattern = re.compile(r'^FILE "([^"]+)" BINARY$')
    for line in lines:
        match = pattern.match(line)
        if not match:
            rendered.append(line)
            continue
        filename = match.group(1)
        source = ROM_DIR / filename
        if "Track 02" in filename:
            target = patched_track
            method = "patched"
        else:
            target = output_path.parent / filename
            try:
                os.link(source, target)
                method = "hardlink"
            except OSError:
                shutil.copy2(source, target)
                method = "copy"
        if not target.is_file() or target.stat().st_size != source.stat().st_size:
            raise RuntimeError(f"failed to stage CUE track: {filename}")
        rendered.append(f'FILE "{target.name}" BINARY')
        staged.append({"file": target.name, "bytes": target.stat().st_size, "method": method})
    output_path.write_text("\n".join(rendered) + "\n", encoding="ascii")
    return staged


def write_mapping(path: Path, mapping: list[dict[str, str]]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(mapping[0]), delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(mapping)


def build(
    version: str,
    force: bool,
    text_key: str,
    extra_text_key: str | None = None,
    extra_ko_text: str | None = None,
) -> Path:
    output_dir = BUILD_ROOT / version
    if output_dir.exists():
        if not force:
            raise SystemExit(f"build already exists: {output_dir} (use --force to rebuild this version)")
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)

    source_raw = SOURCE_TRACK.read_bytes()
    source_hash = sha256(source_raw)
    if source_hash != EXPECTED_SOURCE_SHA256:
        raise RuntimeError(f"unexpected Track 02 SHA-256: {source_hash}")
    if len(source_raw) % RAW_SECTOR_SIZE:
        raise RuntimeError("Track 02 size is not a multiple of 2352")

    user_data = bytearray()
    for sector_index in range(len(source_raw) // RAW_SECTOR_SIZE):
        start = sector_index * RAW_SECTOR_SIZE + USER_DATA_OFFSET
        user_data.extend(source_raw[start:start + USER_DATA_SIZE])

    cave_iso_start = bank68_iso(CAVE_CPU_START)
    cave_iso_end = bank68_iso(CAVE_CPU_END - 1) + 1
    if user_data[cave_iso_start:cave_iso_end] != bytes([0xFF]) * (cave_iso_end - cave_iso_start):
        raise RuntimeError("bank-68 injection cave is not completely FF")

    if (extra_text_key is None) != (extra_ko_text is None):
        raise RuntimeError("--extra-text-key and --extra-ko-text must be supplied together")

    entries = [load_translation_entry(text_key)]
    if extra_text_key is not None and extra_ko_text is not None:
        entries.append(load_translation_entry(extra_text_key, extra_ko_text))

    hangul_glyphs = ordered_hangul("".join(entry.ko_text for entry in entries))
    glyph_pack, mapping = build_glyph_pack(hangul_glyphs)

    runtime_segments: list[RuntimeSegment] = []
    for entry in entries:
        source_segments = split_source_runtime_segments(entry.jp_text)
        translated_segments = split_layout_lines(entry.ko_text)
        if len(source_segments) != len(translated_segments):
            raise RuntimeError(
                f"{entry.text_key} layout mismatch: "
                f"JP={len(source_segments)} segments, KO={len(translated_segments)} segments"
            )
        for index, (source_segment, ko_segment) in enumerate(
            zip(source_segments, translated_segments, strict=True),
            start=1,
        ):
            encoded = build_korean_game_string(ko_segment, hangul_glyphs)
            if len(encoded) > SEGMENT_TEXT_CAPACITY:
                raise RuntimeError(
                    f"{entry.text_key} Korean segment {index} is {len(encoded)} bytes, "
                    f"exceeding {SEGMENT_TEXT_CAPACITY} bytes"
                )
            signature = source_segment.source_bytes[:SEGMENT_SIGNATURE_LENGTH]
            if len(signature) < SEGMENT_SIGNATURE_LENGTH:
                raise RuntimeError(
                    f"{entry.text_key} source segment {index} is too short "
                    f"for a {SEGMENT_SIGNATURE_LENGTH}-byte signature"
                )
            runtime_segments.append(
                RuntimeSegment(
                    text_key=entry.text_key,
                    line_no=index,
                    jp_text=source_segment.text,
                    ko_text=ko_segment,
                    after_control=source_segment.after_control,
                    encoded=encoded,
                    signature=signature,
                )
            )

    seen_signatures: dict[bytes, RuntimeSegment] = {}
    for segment in runtime_segments:
        previous = seen_signatures.get(segment.signature)
        if previous is not None:
            raise RuntimeError(
                "duplicate 16-byte runtime signature: "
                f"{previous.text_key}:{previous.line_no} and "
                f"{segment.text_key}:{segment.line_no}"
            )
        seen_signatures[segment.signature] = segment

    data_cursor = align(GLYPH_BASE + len(glyph_pack))
    text_blobs: list[tuple[str, int, bytes]] = []
    for index, segment in enumerate(runtime_segments, start=1):
        segment.text_address = data_cursor
        text_blobs.append((f"korean_text_{index}", data_cursor, segment.encoded))
        data_cursor += len(segment.encoded)

    table_address = align(data_cursor)
    overlay_table = b"".join(
        segment.signature + segment.text_address.to_bytes(2, "little")
        for segment in runtime_segments
    )
    runtime_data_end = table_address + len(overlay_table)
    if runtime_data_end > RUNTIME_DATA_LIMIT:
        raise RuntimeError(
            f"runtime assets end at ${runtime_data_end:04X}, "
            f"overlapping font wrapper at ${RUNTIME_DATA_LIMIT:04X}"
        )

    font_wrapper = build_font_wrapper(len(hangul_glyphs))
    overlay_hook = build_overlay_hook(len(runtime_segments), table_address)

    blobs = [
        ("hangul_glyphs", GLYPH_BASE, glyph_pack),
        *text_blobs,
        ("overlay_table", table_address, overlay_table),
        ("font_wrapper", FONT_WRAPPER, font_wrapper),
        ("overlay_hook", OVERLAY_HOOK, overlay_hook),
    ]
    for name, cpu_address, data in blobs:
        if not CAVE_CPU_START <= cpu_address < CAVE_CPU_END:
            raise RuntimeError(f"{name} begins outside cave")
        if cpu_address + len(data) > CAVE_CPU_END:
            raise RuntimeError(f"{name} exceeds cave")
    ordered = sorted(blobs, key=lambda item: item[1])
    for left, right in zip(ordered, ordered[1:]):
        if left[1] + len(left[2]) > right[1]:
            raise RuntimeError(f"cave overlap: {left[0]} and {right[0]}")

    patches = [
        Patch(
            "font_call",
            bank6a_iso(FONT_CALL_CPU),
            ORIGINAL_FONT_CALL,
            bytes((0x20, FONT_WRAPPER & 0xFF, FONT_WRAPPER >> 8)),
            FONT_CALL_CPU,
        ),
        Patch(
            "renderer_entry",
            bank6a_iso(RENDERER_ENTRY_CPU),
            ORIGINAL_RENDERER_ENTRY,
            bytes((0x20, OVERLAY_HOOK & 0xFF, OVERLAY_HOOK >> 8)) + bytes([0xEA]) * 7,
            RENDERER_ENTRY_CPU,
        ),
    ]
    for name, cpu_address, data in blobs:
        patches.append(
            Patch(
                name,
                bank68_iso(cpu_address),
                bytes([0xFF]) * len(data),
                data,
                cpu_address,
            )
        )

    patched_user = bytearray(user_data)
    for patch in patches:
        actual = bytes(patched_user[patch.iso_offset:patch.iso_offset + len(patch.old)])
        if actual != patch.old:
            raise RuntimeError(
                f"{patch.name} signature mismatch at ISO ${patch.iso_offset:06X}: "
                f"expected {patch.old.hex(' ')}, got {actual.hex(' ')}"
            )
        patched_user[patch.iso_offset:patch.iso_offset + len(patch.new)] = patch.new

    modified_sectors: set[int] = set()
    for patch in patches:
        first = patch.iso_offset // USER_DATA_SIZE
        last = (patch.iso_offset + len(patch.new) - 1) // USER_DATA_SIZE
        modified_sectors.update(range(first, last + 1))

    patched_raw = bytearray(source_raw)
    for sector_index in sorted(modified_sectors):
        raw_start = sector_index * RAW_SECTOR_SIZE
        sector = bytearray(patched_raw[raw_start:raw_start + RAW_SECTOR_SIZE])
        user_start = sector_index * USER_DATA_SIZE
        sector[USER_DATA_OFFSET:USER_DATA_OFFSET + USER_DATA_SIZE] = patched_user[
            user_start:user_start + USER_DATA_SIZE
        ]
        rebuild_mode1_sector(sector)
        patched_raw[raw_start:raw_start + RAW_SECTOR_SIZE] = sector

    changed_sectors = {
        index
        for index in range(len(source_raw) // RAW_SECTOR_SIZE)
        if source_raw[index * RAW_SECTOR_SIZE:(index + 1) * RAW_SECTOR_SIZE]
        != patched_raw[index * RAW_SECTOR_SIZE:(index + 1) * RAW_SECTOR_SIZE]
    }
    if changed_sectors != modified_sectors:
        raise RuntimeError(
            f"unexpected changed sectors: expected {sorted(modified_sectors)}, got {sorted(changed_sectors)}"
        )

    for patch in patches:
        raw_offset = raw_user_offset(patch.iso_offset)
        actual = bytes(patched_raw[raw_offset:raw_offset + len(patch.new)])
        if actual != patch.new:
            raise RuntimeError(f"raw verification failed for {patch.name}")

    track_name = f"Snatcher CD-ROMantic (Japan) (Track 02) [KO {version}].bin"
    patched_track = output_dir / track_name
    patched_track.write_bytes(patched_raw)
    cue_path = output_dir / f"Snatcher CD-ROMantic (Japan) [KO {version}].cue"
    staged_tracks = make_cue(cue_path, patched_track)
    write_mapping(output_dir / "hangul_code_map.tsv", mapping)

    patch_rows = []
    for patch in patches:
        patch_rows.append(
            {
                "name": patch.name,
                "cpu_address": f"{patch.cpu_address:04X}" if patch.cpu_address is not None else "",
                "iso_offset": f"{patch.iso_offset:06X}",
                "raw_offset": f"{raw_user_offset(patch.iso_offset):08X}",
                "length": len(patch.new),
                "old_hex": patch.old.hex(" ").upper(),
                "new_hex": patch.new.hex(" ").upper(),
            }
        )
    with (output_dir / "patches.tsv").open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(patch_rows[0]), delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(patch_rows)

    manifest = {
        "version": version,
        "status": "proof-of-concept",
        "source_track": str(SOURCE_TRACK),
        "source_sha256": source_hash,
        "patched_track": patched_track.name,
        "patched_sha256": sha256(patched_raw),
        "cue": cue_path.name,
        "cue_tracks": staged_tracks,
        "modified_sectors": [f"{sector:06X}" for sector in sorted(modified_sectors)],
        "translation_master": str(TRANSLATION_MASTER),
        "translation_master_sha256": sha256(TRANSLATION_MASTER.read_bytes()),
        "source_keys": [entry.text_key for entry in entries],
        "entries": [
            {
                "text_key": entry.text_key,
                "translation_status": entry.status,
                "translation_note": entry.note,
                "jp_text": entry.jp_text,
                "ko_text": entry.ko_text,
                "source_bytes": len(entry.jp_text.encode("cp932")) + 1,
            }
            for entry in entries
        ],
        "source_bytes": sum(len(entry.jp_text.encode("cp932")) + 1 for entry in entries),
        "ko_bytes": sum(len(segment.encoded) for segment in runtime_segments),
        "segments": [
            {
                "text_key": segment.text_key,
                "line_no": segment.line_no,
                "jp_text": segment.jp_text,
                "ko_text": segment.ko_text,
                "after_control": segment.after_control,
                "ko_bytes": len(segment.encoded),
                "signature_hex": segment.signature.hex(" ").upper(),
                "text_cpu_address": f"{segment.text_address:04X}",
            }
            for segment in runtime_segments
        ],
        "overlay_table": {
            "cpu_address": f"{table_address:04X}",
            "record_size": OVERLAY_RECORD_SIZE,
            "record_count": len(runtime_segments),
            "signature_bytes": SEGMENT_SIGNATURE_LENGTH,
            "bytes": len(overlay_table),
        },
        "segment_max_bytes": SEGMENT_TEXT_CAPACITY,
        "proof_override": (
            {"text_key": extra_text_key, "ko_text": extra_ko_text}
            if extra_text_key is not None
            else None
        ),
        "hangul_codes": {row["character"]: row["game_code"] for row in mapping},
        "cave": {
            "cpu_range": f"{CAVE_CPU_START:04X}-{CAVE_CPU_END - 1:04X}",
            "iso_range": f"{cave_iso_start:06X}-{cave_iso_end - 1:06X}",
            "capacity": cave_iso_end - cave_iso_start,
            "used": sum(len(data) for _, _, data in blobs),
        },
        "patches": patch_rows,
    }
    (output_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    report = [
        f"Snatcher Korean patch build {version}",
        f"source SHA-256:  {source_hash}",
        f"patched SHA-256: {manifest['patched_sha256']}",
        f"source size:     {len(source_raw)} bytes",
        f"modified sectors:{','.join(manifest['modified_sectors'])}",
        f"cave used:       {manifest['cave']['used']} / {manifest['cave']['capacity']} bytes",
        f"dialogue keys:   {', '.join(manifest['source_keys'])}",
        f"table records:   {len(runtime_segments)}",
        f"Hangul glyphs:   {len(hangul_glyphs)}",
        f"Korean bytes:    {sum(len(segment.encoded) for segment in runtime_segments)}",
        "",
        "Runtime records:",
        *[
            (
                f"- {segment.text_key}:{segment.line_no} "
                f"${segment.text_address:04X} "
                f"{segment.jp_text} -> {segment.ko_text}"
            )
            for segment in runtime_segments
        ],
        "",
        "Verification passed:",
        "- original Track 02 SHA-256 matched",
        "- all patch-site byte signatures matched",
        "- bank-68 cave was entirely FF",
        "- only expected Mode-1 sectors changed",
        "- patched user bytes round-tripped into raw sectors",
        "- EDC and P/Q ECC were regenerated for every modified sector",
    ]
    (output_dir / "verification.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    test_notes = [
        f"Snatcher Korean patch {version} - Mesen test",
        "",
        f"Open this CUE directly:",
        str(cue_path),
        "",
        "Do not load a save state made with a Lua font/text POC still active.",
        "Power-cycle the game and test these dialogues:",
        *[
            f"  {entry.text_key}: {entry.jp_text} -> {entry.ko_text}"
            for entry in entries
        ],
        "",
        "Also confirm:",
        "- the yellow speaker name remains Japanese and intact",
        "- an untranslated dialogue remains Japanese",
        "- the following menu still renders normally",
        "- the dialogue can be advanced without a freeze",
        "",
        f"If it fails, keep the {version} folder unchanged for comparison.",
    ]
    (output_dir / "TEST_IN_MESEN.txt").write_text("\n".join(test_notes) + "\n", encoding="utf-8")
    return output_dir


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default="0.0.1")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--text-key", default=DEFAULT_TEXT_KEY)
    parser.add_argument("--extra-text-key")
    parser.add_argument("--extra-ko-text")
    args = parser.parse_args()
    output = build(
        args.version,
        args.force,
        args.text_key,
        args.extra_text_key,
        args.extra_ko_text,
    )
    subprocess.run(
        [
            sys.executable,
            str(TRANSLATION_VALIDATOR),
            str(TRANSLATION_MASTER),
            str(output),
            "--max-bytes",
            str(KOREAN_TEXT_CAPACITY),
        ],
        check=True,
    )
    subprocess.run(
        [
            sys.executable,
            str(OVERLAY_COMPILER),
            str(TRANSLATION_MASTER),
            str(output),
            "--include-status",
            "draft,review,final",
            "--max-bytes",
            str(KOREAN_TEXT_CAPACITY),
        ],
        check=True,
    )
    print(f"build complete: {output}")


if __name__ == "__main__":
    main()
