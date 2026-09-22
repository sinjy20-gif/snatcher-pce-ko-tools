#!/usr/bin/env python3
"""Build UI Session 0.1.4: one Track-24 read for four reception actions.

This proof deliberately starts from the verified KO 0.2.26 SRT4 table.  It
does not regenerate dialogue records and never edits the stable build.

The reception action sources are shortened in-place to ``F7 <item> FF``.  A
small dispatcher carried in every SRT4 cache payload recognises that marker.
On a cache miss it uses the normal SRT4 loader to read one synthetic session
sector.  On subsequent cursor movements it maps the item index directly to
one of four fixed cache strings, without calling the loader.

The dispatcher lives in Track-02 $5E00-$5E3A.  The lower 32 bytes are blank;
the upper 32 normally hold the optional half-space helper.  This POC restores
the stock spacing routine, making that helper unused, before placing the
dispatcher there.  It is deliberately *not* placed inside a Track-24 payload:
the renderer executes bank-68 code at this CPU address before a payload has
been mapped into cache.
"""

from __future__ import annotations

import csv
import hashlib
import json
import shutil
import sys
from pathlib import Path


ROOT = Path(r"C:\snatcher")
STATIC_DIR = ROOT / "extraction" / "patch" / "static"
sys.path[:0] = [str(STATIC_DIR)]

import build_direct_overlay_layout as layout  # noqa: E402
import build_direct_overlay_patch as direct  # noqa: E402
import build_disc_patch as common  # noqa: E402
import build_full_overlay_layout as srt3  # noqa: E402
import build_full_overlay_patch as srt3_patch  # noqa: E402
import build_speaker_ui_proof as proof  # noqa: E402
import build_track24_loader_proof as track24  # noqa: E402


VERSION = "UI Session 0.1.4"
BASE_VERSION = "0.2.26"
BASE_DIR = ROOT / "build" / "patch" / BASE_VERSION
OUT_DIR = ROOT / "build" / "patch" / VERSION
UI_TSV = ROOT / "snatcher_tool" / "translation" / "ui_text.tsv"

CACHE_BASE = direct.CACHE_BASE
STAGE = 0x5E00
PRELOADER = direct.RUNTIME_START
SESSION_MARKER = b"UI"
SESSION_TEXT_BLOB = 0x20
SESSION_OFFSET_TABLE = 0x50

# Display order in the verified reception action menu.  The first byte at
# $3499 is the engine's item number; $349A receives F7 and $349B the id.
TARGETS = (
    (0, "UI0006", "0DB870"),  # 中に入る -> 안으로 들어간다
    (1, "UI0001", "0DB807"),  # 見る     -> 보다
    (2, "UI0002", "0DB879"),  # 調べる   -> 조사하다
    (3, "UI0004", "0DB88B"),  # 話す     -> 대화하다
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def read_ui_rows() -> dict[str, dict[str, str]]:
    with UI_TSV.open("r", encoding="utf-8-sig", newline="") as handle:
        return {row["ui_id"]: row for row in csv.DictReader(handle, delimiter="\t")}


def encode_label(text: str, glyph_codes: dict[str, bytes]) -> bytes:
    encoded = srt3.encode_game_text(text, glyph_codes)
    if any(value == 0xFE for value in encoded):
        raise RuntimeError("UI session proof accepts plain Hangul labels only")
    return encoded


def build_stage_dispatcher() -> bytes:
    """Return the cache-resident UI dispatcher at $5E00.

    Non-target UI returns directly, cached SRT4 text returns directly, and
    normal narrative input delegates to the ordinary SRT4 preloader.  A UI
    cache is distinguished by the single U marker at cache+12; body assets
    begin with SDR4 and therefore cannot collide with it.
    """

    a = common.Assembler(STAGE)
    a.abs(0xAD, 0x3472)  # LDA pointer high
    a.emit(0xC9, 0x34)
    a.branch(0xD0, "not_source34")
    a.abs(0xAD, 0x349A)
    a.emit(0xC9, 0xF7)
    # $34xx is not UI-exclusive: ordinary text can transiently use this
    # scratch pointer before the normal preloader redirects it to $3619.
    # Only our F7 marker is special; every other $34xx input must retain the
    # stock SRT4 preloader path.
    a.branch(0xD0, "preload_generic")
    a.abs(0xAD, CACHE_BASE + 12)
    a.emit(0xC9, ord("U"))
    a.branch(0xD0, "load_session")

    # Cache hit: $3499 is 0..3.  A four-byte table at $5BD0 stores the
    # variable-length label starts; this keeps the 17-byte first label and
    # its native full-cell space inside the same 64-byte text region.
    a.abs(0xAE, 0x3499)  # LDX item
    a.abs(0xBD, CACHE_BASE + SESSION_OFFSET_TABLE)  # LDA table,X
    a.abs(0x8D, 0x3471)
    a.emit(0xA9, CACHE_BASE >> 8)
    a.abs(0x8D, 0x3472)
    a.branch(0x80, "return_original")

    # Force the root-state synthetic source to match in one SRT4 probe.
    a.label("load_session")
    a.abs(0x9C, direct.STATE_LO)
    a.abs(0x9C, direct.STATE_HI)
    a.abs(0x4C, PRELOADER)

    a.label("not_source34")
    a.emit(0xC9, 0x5B)
    a.branch(0xF0, "return_original")

    a.label("preload_generic")
    a.abs(0x4C, PRELOADER)

    a.label("return_original")
    a.abs(0xAD, 0x3471)
    a.emit(0x60)
    code = a.finish()
    if len(code) > PRELOADER - STAGE:
        raise RuntimeError(f"UI stage is {len(code)} bytes; cache gap is only {PRELOADER - STAGE}")
    return code


def build_session_payload(
    item: int,
    labels: list[tuple[str, bytes]],
    offsets: list[int],
    font: bytes,
) -> bytes:
    source = bytes((0xF7, 0x40 + item))
    length, xor_value, cumulative = layout.cumulative_signature(source)
    payload = bytearray(track24.USER_DATA_SIZE)
    payload[0:4] = layout.MAGIC
    payload[4] = len(labels[item][1])
    payload[5] = length
    payload[6] = xor_value
    payload[7] = cumulative
    payload[8:10] = (0).to_bytes(2, "little")
    payload[10:12] = (0).to_bytes(2, "little")
    payload[12:16] = SESSION_MARKER + bytes((len(labels), item))
    payload[layout.TEXT_OFFSET:layout.TEXT_OFFSET + len(labels[item][1])] = labels[item][1]
    for index, (_, encoded) in enumerate(labels):
        offset = offsets[index]
        payload[offset:offset + len(encoded)] = encoded
        payload[SESSION_OFFSET_TABLE + index] = (CACHE_BASE + offset) & 0xFF
    payload[layout.FONT_OFFSET:layout.FONT_OFFSET + len(font)] = font
    return bytes(payload)


def unpack_stable_table() -> list[bytearray]:
    raw = (BASE_DIR / "track24_appended_raw.bin").read_bytes()
    expected = layout.SLOT_COUNT * track24.RAW_SECTOR_SIZE
    if len(raw) != expected:
        raise RuntimeError(f"stable SRT4 append is {len(raw)} bytes, expected {expected}")
    sectors: list[bytearray] = []
    for offset in range(0, len(raw), track24.RAW_SECTOR_SIZE):
        user = raw[
            offset + track24.USER_DATA_OFFSET : offset + track24.USER_DATA_OFFSET + track24.USER_DATA_SIZE
        ]
        sectors.append(bytearray(user))
    return sectors


def stable_track02() -> Path:
    """Return the already-patched 0.2.26 program track.

    The session POC is a delta *on top of* the stable Korean build.  Starting
    from the original Track 02 would retain the appended SRT4 table but lose
    the Track-02 renderer hooks and every body-text replacement.
    """

    candidates = sorted(BASE_DIR.glob("*Track 02*0.2.26*.bin"))
    if len(candidates) != 1:
        raise RuntimeError(f"expected one stable Track 02 in {BASE_DIR}, found {candidates}")
    return candidates[0]


def insert_record(table: list[bytearray], payload: bytes) -> tuple[int, int]:
    source = bytes(payload[0:0])  # placate type checker; source comes from header caller
    del source
    state = int.from_bytes(payload[8:10], "little")
    # The synthetic source is encoded in the signature fields.  There are four
    # unambiguous possibilities, so recover it without introducing metadata in
    # the cache format.
    item = payload[15]
    key = bytes((0xF7, 0x40 + item))
    slot = layout.direct_hash(state, key)
    probes = 1
    while bytes(table[slot][0:4]) != bytes(track24.USER_DATA_SIZE)[0:4]:
        if bytes(table[slot][0:4]) == layout.MAGIC:
            if table[slot][5] == len(key) and table[slot][6] == payload[6] and table[slot][7] == payload[7]:
                raise RuntimeError("synthetic UI source unexpectedly duplicates a table record")
        slot = (slot + 1) & layout.SLOT_MASK
        probes += 1
        if probes > layout.SLOT_COUNT:
            raise RuntimeError("SRT4 table has no free slot for UI session")
    table[slot][:] = payload
    return slot, probes


def make_patches(rows: dict[str, dict[str, str]], preloader: bytes, base02: Path) -> list[common.Patch]:
    # The stable build already owns the font wrapper, sector loader and private
    # state.  This POC changes only the renderer call, its preloader guard,
    # and the four native UI source strings.
    patches = [
        common.Patch(
            "renderer_ui_session_dispatch", common.bank6a_iso(direct.RENDERER_ENTRY), bytes((0x20, PRELOADER & 0xFF, PRELOADER >> 8)),
            bytes((0x20, STAGE & 0xFF, STAGE >> 8)), direct.RENDERER_ENTRY,
        ),
        common.Patch(
            "ui_session_dispatcher_code", common.bank68_iso(STAGE),
            proof.read_user_bytes(base02, common.bank68_iso(STAGE), len(build_stage_dispatcher())),
            build_stage_dispatcher(), STAGE,
        ),
        common.Patch(
            "temporary_restore_native_space_shift", common.bank6a_iso(direct.GLYPH_SHIFT),
            direct.build_fractional_glyph_shift(direct.GLYPH_SHIFT),
            direct.ORIGINAL_GLYPH_SHIFT, direct.GLYPH_SHIFT,
        ),
        common.Patch(
            "renderer_preloader_direct_ui_session", common.bank68_iso(PRELOADER),
            proof.read_user_bytes(base02, common.bank68_iso(PRELOADER), len(preloader)), preloader, PRELOADER,
        ),
    ]
    for item, key, raw_offset in TARGETS:
        row = rows[key]
        source = row["jp_text"].encode("cp932") + b"\xFF"
        replacement = bytes((0xF7, 0x40 + item, 0xFF)) + bytes(max(0, len(source) - 3))
        patches.append(
            common.Patch(
                f"ui_session_source_{item}_{key}", int(raw_offset, 16), source, replacement, None,
            )
        )
    return patches


def build(force: bool = False) -> Path:
    if OUT_DIR.exists():
        if not force:
            raise SystemExit(f"build already exists: {OUT_DIR} (use --force)")
        shutil.rmtree(OUT_DIR)
    OUT_DIR.mkdir(parents=True)

    if direct.sha256_file(direct.SOURCE_TRACK24) != direct.EXPECTED_TRACK24_SHA256:
        raise RuntimeError("unexpected Track 24 SHA-256")
    base02 = stable_track02()

    rows = read_ui_rows()
    wanted = [rows[key] for _, key, _ in TARGETS]
    if any(not row["ko_text"].strip() for row in wanted):
        raise RuntimeError("a target UI label has no Korean text")
    labels_text = [row["ko_text"].strip() for row in wanted]
    glyphs = srt3.ordered_hangul(labels_text)
    if len(glyphs) > srt3.FONT_GLYPH_CAPACITY:
        raise RuntimeError(f"UI session needs {len(glyphs)} glyphs, cache supports {srt3.FONT_GLYPH_CAPACITY}")
    found = srt3.parse_bdf(srt3.FONT_BDF, {ord(char) for char in glyphs})
    missing = [char for char in glyphs if ord(char) not in found]
    if missing:
        raise RuntimeError(f"missing UI glyphs: {missing}")
    codes = {char: bytes(srt3.HANGUL_CODES[index]) for index, char in enumerate(glyphs)}
    labels = [(text, encode_label(text, codes)) for text in labels_text]
    offsets: list[int] = []
    cursor = SESSION_TEXT_BLOB
    for _, encoded in labels:
        offsets.append(cursor)
        cursor += len(encoded)
    if cursor > SESSION_OFFSET_TABLE:
        raise RuntimeError("UI session label blob overlaps its offset table")
    font = bytearray()
    for char in glyphs:
        font.extend(srt3.glyph_1bpp_left_shifted(*found[ord(char)]))
    font.extend(bytes(srt3.FONT_BYTES - len(font)))

    table = unpack_stable_table()
    stage = build_stage_dispatcher()
    synthetic_rows: list[dict[str, str]] = []
    maximum = 3
    for item, key, _ in TARGETS:
        payload = build_session_payload(item, labels, offsets, bytes(font))
        slot, probes = insert_record(table, payload)
        maximum = max(maximum, probes)
        synthetic_rows.append({
            "item": str(item), "ui_key": key, "jp_text": rows[key]["jp_text"], "ko_text": rows[key]["ko_text"],
            "source_hex": f"F7 {0x40 + item:02X}", "slot": f"{slot:04X}", "probes": str(probes),
            "cache_text_offset": f"{offsets[item]:02X}",
        })

    starts, source_disc_sectors = track24.disc_track_starts()
    track24_sectors = direct.SOURCE_TRACK24.stat().st_size // track24.RAW_SECTOR_SIZE
    first_lba = starts[24] + track24_sectors
    if first_lba != source_disc_sectors:
        raise RuntimeError("Track 24 is not the source disc's last track")
    track02_index1 = starts[2] + 225
    track24_index1 = starts[24] + 225
    direct_relative = first_lba - track24_index1
    preloader = direct.build_renderer_preloader_direct(
        PRELOADER, direct.SECTOR_LOADER, direct_relative, maximum, allow_ui_session=True,
    )
    if PRELOADER + len(preloader) > direct.RUNTIME_END:
        raise RuntimeError("UI-session preloader exceeds $5FFF")

    patches = make_patches(rows, preloader, base02)
    for patch in patches:
        actual = proof.read_user_bytes(base02, patch.iso_offset, len(patch.old))
        if actual != patch.old:
            raise RuntimeError(f"preflight mismatch for {patch.name}: {actual.hex(' ')}")

    patched02 = OUT_DIR / f"Snatcher CD-ROMantic (Japan) (Track 02) [KO {VERSION}].bin"
    proof.apply_patches_streaming(base02, patched02, patches)
    patched24 = OUT_DIR / f"Snatcher CD-ROMantic (Japan) (Track 24) [KO {VERSION}].bin"
    shutil.copyfile(direct.SOURCE_TRACK24, patched24)
    appended = bytearray()
    for index, user_data in enumerate(table):
        lba = first_lba + index
        appended.extend(track24.make_mode1_sector(lba, bytes(user_data)))
    with patched24.open("ab") as handle:
        handle.write(appended)
    cue = OUT_DIR / f"Snatcher CD-ROMantic (Japan) [KO {VERSION}].cue"
    staged = track24.stage_cue(cue, patched02, patched24)

    with (OUT_DIR / "session_records.tsv").open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(synthetic_rows[0]), delimiter="\t", lineterminator="\n")
        writer.writeheader(); writer.writerows(synthetic_rows)
    with (OUT_DIR / "track02_patches.tsv").open("w", encoding="utf-8-sig", newline="") as handle:
        fields = ("name", "cpu_address", "iso_offset", "length", "old_hex", "new_hex")
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for patch in patches:
            writer.writerow({
                "name": patch.name,
                "cpu_address": f"{patch.cpu_address:04X}" if patch.cpu_address is not None else "",
                "iso_offset": f"{patch.iso_offset:06X}", "length": len(patch.new),
                "old_hex": patch.old.hex(" ").upper(), "new_hex": patch.new.hex(" ").upper(),
            })
    (OUT_DIR / "track24_appended_raw.bin").write_bytes(appended)
    (OUT_DIR / "TEST_IN_MESEN.txt").write_text(
        "UI Session 0.1.4 POC\n\n"
        "1. Power-cycle. Advance one translated narrative line first: it installs the cache dispatcher.\n"
        "2. Open the reception action menu. First entry may read Track 24 once.\n"
        "3. Move among 안으로 들어간다 / 보다 / 조사하다 / 대화하다 at least ten times.\n"
        "4. Reopen the same menu. Expected: no additional Track-24 reads while the UI session cache remains.\n\n"
        "POC LIMIT: uses stock full-cell spaces temporarily to free $5E20-$5E3F for the dispatcher.\n"
        "Validate the four-label session cache only; do not use for normal story play.\n",
        encoding="utf-8",
    )
    manifest = {
        "version": VERSION,
        "base": BASE_VERSION,
        "purpose": "four-label reception UI session cache proof",
        "first_menu_entry": "one normal SRT4 read; direct source F7+item",
        "cursor_moves": "cache-only fixed text cells; zero Track-24 reads",
        "target_ui_keys": [key for _, key, _ in TARGETS],
        "union_hangul_glyphs": len(glyphs),
        "stage_cpu": f"{STAGE:04X}",
        "stage_bytes": len(stage),
        "preloader_bytes": len(preloader),
        "maximum_ui_probes": maximum,
        "known_limit": "reception-menu session-cache POC only; stock full-cell spaces restored temporarily",
        "patched_track02_sha256": sha256_file(patched02),
        "patched_track24_sha256": sha256_file(patched24),
        "cue_tracks": staged,
    }
    (OUT_DIR / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    return OUT_DIR


if __name__ == "__main__":
    print(build(force="--force" in sys.argv))
