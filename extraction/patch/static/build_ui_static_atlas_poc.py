#!/usr/bin/env python3
"""Build a no-runtime-CD UI atlas proof.

This proof deliberately starts from the pristine Japanese Track 02.  It does
not include the main dialogue overlay or the old speaker/UI pack loader.

It changes every fixed ``見る`` menu record to ``보다`` (five bytes in both
encodings) and draws the two Korean glyphs from a permanent Track 02 cave in
Card RAM bank $70.  The font wrapper maps MPR4 only while it copies a glyph,
then restores it before returning to the native renderer.  Therefore opening
or moving a menu performs *no* CD read and does not use the volatile $5BE0
main-dialogue cache.
"""

from __future__ import annotations

import csv
import hashlib
import json
import shutil
import sys
from pathlib import Path


ROOT = Path(r"C:\snatcher")
ROM_DIR = ROOT / "rom(japan)" / "Snatcher CD-ROMantic (Japan)"
SOURCE_TRACK = ROM_DIR / "Snatcher CD-ROMantic (Japan) (Track 02).bin"
BUILD_ROOT = ROOT / "build" / "patch"
UI_TSV = ROOT / "translation" / "ui_text.tsv"
STATIC_DIR = ROOT / "extraction" / "patch" / "static"
sys.path.insert(0, str(STATIC_DIR))

import build_disc_patch as common  # noqa: E402
import build_speaker_ui_proof as stream  # noqa: E402


VERSION_DEFAULT = "ui-static-atlas-poc-v7"
# 見る is not present in the first reception action menu.  Use the visible
# 調べる record so this POC definitely exercises the F040/F041 UI path.
UI_ID = "UI0002"  # 調べる -> temporary 보다

# The first attempt placed the atlas in an inferred bank-$70 disc region.
# That bank is Card-RAM at runtime but is not a direct static Track-02 image
# mapping, so it displayed unrelated RAM.  For this small proof, keep both
# code and glyphs in the *proven* bank-$6A static cave.  MPR3 is $6A while the
# renderer executes, so no MPR switch or CD access is necessary.
FONT_WRAPPER_CPU = 0x7F50
ATLAS_CPU = 0x7F90
FONT_WRAPPER_ISO = common.bank6a_iso(FONT_WRAPPER_CPU)
ATLAS_ISO = common.bank6a_iso(ATLAS_CPU)

# The renderer has already placed the active two-byte code in $F9/$F8 when it
# reaches this native font-cache call.  This is the same proven caller used by
# the stable narrative Hangul renderer.  Hooking the earlier $6747 path was
# wrong for UI: it had not populated $00/$01 as the V4 wrapper assumed.
FONT_DISPATCH_CPU = 0x648C
ORIGINAL_FONT_DISPATCH = bytes((0x20, 0xC2, 0x69))  # JSR $69C2


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest().upper()


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-16", newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def build_wrapper() -> bytes:
    """F040/F041 -> $7F90/$7FB0 in proven bank-$6A; else native.

    F6xx is an active native Japanese glyph range, so it must not be
    intercepted.  F040/F041 are the private range already proven by the main
    Korean renderer.
    """

    a = common.Assembler(FONT_WRAPPER_CPU)
    # UI and body text reach this caller through different preambles.  The
    # body path has the code in $F9/$F8, but UI leaves those bytes untouched.
    # UI has, however, already consumed the lead byte at $6474: $3471/$3472
    # point at the trail.  Rewind that live pointer by one and read F0xx
    # directly from the source string.  This also makes the test independent
    # of the volatile font-cache zero-page state.
    a.emit(0xAD, 0x71, 0x34, 0x85, 0x00)  # LDA $3471 / STA $00
    a.emit(0xAD, 0x72, 0x34, 0x85, 0x01)  # LDA $3472 / STA $01
    a.emit(0xC6, 0x00)                    # DEC $00
    a.branch(0xD0, "have_source")         # BNE
    a.emit(0xC6, 0x01)                    # wrapped from $xx00
    a.label("have_source")
    a.emit(0xA0, 0x00, 0xB1, 0x00)        # LDY #0 / LDA ($00),Y: lead
    a.emit(0xC9, 0xF0)  # CMP #$F0
    a.branch(0xD0, "fallback")
    a.emit(0xC8, 0xB1, 0x00)  # INY / LDA ($00),Y: trail byte
    # Convert $40/$41 to an index first, then reject every value >= 2.  This
    # is four bytes shorter than the old pair of lower/upper-bound compares,
    # leaving room for the atlas's $90 low-byte base below.
    a.emit(0x38, 0xE9, 0x40, 0xC9, 0x02)  # SEC/SBC #$40/CMP #2
    a.branch(0xB0, "fallback")
    a.emit(0x0A, 0x0A, 0x0A, 0x0A, 0x0A)  # index * 32
    # The atlas begins at $7F90, not at the start of the $7Fxx page.
    # Keep the 32-byte glyph stride, then add the atlas's low-byte base.
    a.emit(0x18, 0x69, ATLAS_CPU & 0xFF)  # CLC / ADC #$90
    a.emit(0x85, 0x00)  # source low: $00/$01 are native glyph-copy scratch
    a.emit(0xA9, ATLAS_CPU >> 8, 0x85, 0x01)  # source high = $7F
    a.emit(0x82)  # CLX: matches native font path entry
    a.abs(0x20, 0x69FC)  # JSR native 16x16 glyph copier
    a.emit(0x62, 0x60)  # CLA / RTS
    a.label("fallback")
    a.abs(0x20, 0x69C2)  # JSR original native cache lookup
    a.emit(0x60)  # RTS to original caller
    return a.finish()


def build_atlas() -> tuple[bytes, list[dict[str, str]]]:
    chars = ("보", "다")
    parsed = common.parse_bdf(common.FONT_BDF, {ord(char) for char in chars})
    missing = [char for char in chars if ord(char) not in parsed]
    if missing:
        raise RuntimeError(f"Galmuri11 glyphs missing: {missing}")
    atlas = bytearray()
    rows: list[dict[str, str]] = []
    for index, char in enumerate(chars):
        glyph = common.glyph_1bpp_left_shifted(*parsed[ord(char)])
        atlas.extend(glyph)
        rows.append({
            "game_code": f"F0{0x40 + index:02X}",
            "character": char,
            "atlas_cpu": f"{ATLAS_CPU + index * 32:04X}",
            "atlas_iso": f"{ATLAS_ISO + index * 32:06X}",
        })
    return bytes(atlas), rows


def write_tsv(path: Path, rows: list[dict[str, str]]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]), delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def build(version: str, force: bool) -> Path:
    output_dir = BUILD_ROOT / version
    if output_dir.exists():
        if not force:
            raise RuntimeError(f"already exists: {output_dir} (use --force)")
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)

    source_hash = sha256_file(SOURCE_TRACK)
    if source_hash != common.EXPECTED_SOURCE_SHA256:
        raise RuntimeError(f"unexpected Track 02 hash: {source_hash}")

    rows = read_tsv(UI_TSV)
    row = next((item for item in rows if item["ui_id"] == UI_ID), None)
    if row is None:
        raise RuntimeError(f"missing {UI_ID} in {UI_TSV}")
    if row["jp_text"] != "調べる":
        raise RuntimeError(f"{UI_ID} must remain 調べる for this proof")

    original = row["jp_text"].encode("cp932") + b"\xFF"
    replacement = bytes((0xF0, 0x40, 0xF0, 0x41, 0xFF))
    if len(replacement) > len(original):
        raise RuntimeError("UI proof replacement must fit inside its fixed record")
    replacement = replacement.ljust(len(original), b"\xFF")

    atlas, glyph_rows = build_atlas()
    wrapper = build_wrapper()
    if len(wrapper) > ATLAS_CPU - FONT_WRAPPER_CPU:
        raise RuntimeError(f"font wrapper needs {len(wrapper)} bytes; cave has 176")

    offsets = [int(value, 16) for value in row["all_disc_offsets"].split(",")]
    patches: list[common.Patch] = [
        common.Patch(
            "ui_static_atlas",
            ATLAS_ISO,
            bytes((0xFF,)) * len(atlas),
            atlas,
            ATLAS_CPU,
        ),
        common.Patch(
            "ui_static_font_wrapper",
            FONT_WRAPPER_ISO,
            bytes((0xFF,)) * len(wrapper),
            wrapper,
            FONT_WRAPPER_CPU,
        ),
        common.Patch(
            "ui_static_font_dispatch",
            common.bank6a_iso(FONT_DISPATCH_CPU),
            ORIGINAL_FONT_DISPATCH,
            bytes((0x20, FONT_WRAPPER_CPU & 0xFF, FONT_WRAPPER_CPU >> 8)),
            FONT_DISPATCH_CPU,
        ),
    ]
    for number, offset in enumerate(offsets, start=1):
        patches.append(common.Patch(f"{UI_ID.lower()}_{number:02d}", offset, original, replacement))

    for patch in patches:
        actual = stream.read_user_bytes(SOURCE_TRACK, patch.iso_offset, len(patch.old))
        if actual != patch.old:
            raise RuntimeError(
                f"preflight mismatch {patch.name} at ${patch.iso_offset:06X}: "
                f"expected {patch.old.hex(' ')}, got {actual.hex(' ')}"
            )

    patched_track = output_dir / f"Snatcher CD-ROMantic (Japan) (Track 02) [{version}].bin"
    modified = stream.apply_patches_streaming(SOURCE_TRACK, patched_track, patches)
    cue_path = output_dir / f"Snatcher CD-ROMantic (Japan) [{version}].cue"
    staged = common.make_cue(cue_path, patched_track)
    write_tsv(output_dir / "glyph_map.tsv", glyph_rows)

    patch_rows = [{
        "name": patch.name,
        "cpu_address": f"{patch.cpu_address:04X}" if patch.cpu_address is not None else "",
        "iso_offset": f"{patch.iso_offset:06X}",
        "length": str(len(patch.new)),
        "new_hex": patch.new.hex(" ").upper(),
    } for patch in patches]
    write_tsv(output_dir / "patches.tsv", patch_rows)
    (output_dir / "manifest.json").write_text(json.dumps({
        "kind": "ui-static-atlas-poc",
        "version": version,
        "source_sha256": source_hash,
        "patched_sha256": sha256_file(patched_track),
        "ui": "調べる -> temporary 보다",
        "ui_occurrences": len(offsets),
        "atlas": {"bank": "6A", "cpu": f"{ATLAS_CPU:04X}", "bytes": len(atlas)},
        "wrapper": {"bank": "6A", "cpu": f"{FONT_WRAPPER_CPU:04X}", "bytes": len(wrapper)},
        "modified_sectors": [f"{value:06X}" for value in sorted(modified)],
        "cue_tracks": staged,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (output_dir / "TEST_IN_MESEN.txt").write_text(
        "\n".join((
            "UI static-atlas POC",
            "",
            f"Open: {cue_path.name}",
            "Open the reception action menu containing 調べる.",
            "Expected: the item temporarily reads 보다, appears at native speed, and other menu text is intact.",
            "This POC intentionally has Japanese main dialogue; it isolates the UI atlas only.",
        )) + "\n", encoding="utf-8")
    return output_dir


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default=VERSION_DEFAULT)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    print(build(args.version, args.force))
