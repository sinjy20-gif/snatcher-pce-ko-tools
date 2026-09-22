#!/usr/bin/env python3
"""Build an isolated 0.7.11 Gaudi precomposed-Hangul keypad experiment.

The experiment deliberately keeps the original 45 kana byte codes as opaque
tokens.  Their BIOS glyphs are replaced with 45 Korean syllables, while the
name/password tables receive the same token sequences.  This proves the UI and
matching path without changing the keyboard input routine.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "extraction" / "patch" / "static")]

import build_bios_font_patch as font
import build_bios_hangul_map as fmap
import build_disc_subtitle_hook as rawdisc

SOURCE = ROOT / "build" / "patch" / "0.7.11"
VERSION = "0.7.11-keypad-test2"
OUT = ROOT / "build" / "patch" / VERSION
TRACK02_NAME = "Snatcher CD-ROMantic (Japan) (Track 02) [KO].bin"
SOURCE_BIOS_NAME = "Syscard3_galmuri_0.7.11.pce"
BIOS_NAME = f"Syscard3_galmuri_{VERSION}.pce"

RAW = 2352
USER = 16
USER_SIZE = 2048
GLYPH_BASE = 0x30000
GLYPH_STRIDE = 18

# Screen order: four rows on line 1, four rows on line 2, one row on line 3.
TOKEN_CODES = [
    0x8341, 0x8343, 0x8345, 0x8347, 0x8349,  # ア イ ウ エ オ
    0x834A, 0x834C, 0x834E, 0x8350, 0x8352,  # カ キ ク ケ コ
    0x8354, 0x8356, 0x8358, 0x835A, 0x835C,  # サ シ ス セ ソ
    0x835E, 0x8360, 0x8363, 0x8365, 0x8367,  # タ チ ツ テ ト
    0x8369, 0x836A, 0x836B, 0x836C, 0x836D,  # ナ ニ ヌ ネ ノ
    0x836E, 0x8371, 0x8374, 0x8377, 0x837A,  # ハ ヒ フ ヘ ホ
    0x837D, 0x837E, 0x8380, 0x8381, 0x8382,  # マ ミ ム メ モ
    0x8384, 0x8386, 0x8388, 0x838F, 0x8393,  # ヤ ユ ヨ ワ ン
    0x8389, 0x838A, 0x838B, 0x838C, 0x838D,  # ラ リ ル レ ロ
]

# 0.7.15 screen/token order, retained so the packed search table and native BG
# can be reproduced exactly when building the next revision from it.
LEGACY_SYLLABLES = tuple(
    "기 길 깁 나 느 닝 덤 디 라 랜 레 리 린 마 메 미 반 벤 벨 사 슈 슨 야 "
    "어 언 옹 이 제 존 지 천 첸 카 커 코 퀸 탈 트 틀 폴 프 하 해 햄 호".split()
)

# ★ 2026-09-15 -- 48 키를 **44 키로 줄였다.**
#
#   48 키(0.7.16~0.7.18)는 자판 그림 블록에 안 들어간다.  그 블록은 가우디 자판
#   혼자 쓰는 것이 아니라 **화상전화 숫자판**과 공유하고, 숫자 `1 2 3 / 4 5 6 /
#   7 8 9 / * 0 #` 이 타일 $243-$24E 에 산다.  48 키는 분할 슬롯 6 개를 요구하는데
#   안전한 자리는 4 개뿐이고, 숫자판을 지키면 압축이 93 B 넘쳤다.
#
#   `코지마`·`하야사카` 는 개발자 이스터에그라 검색 항목에서 빼기로 했다(소유자 결정).
#   그러면 `마 야 지 코` 네 칸이 풀려 44 키가 되고, 분할 3 개 · 압축 여유 +10 B 로
#   들어간다.  44 개가 전부 원래 카나 코드에 앉으므로 수식키($81xx)를 빌릴 일도 없다.
#
#   ⚠ `메탈기어` 를 빼면 4 칸이 풀려 같은 결과가 나오지만, 그건 게임 등장인물이다.
#   글자는 44 개지만 자판 격자는 20+20+5 = **45 칸**이라 한 칸이 빈다.  빈 칸을
#   그대로 두면 아랫줄 오른쪽 끝이 뚫려 보여서, 마지막 칸에 가운뎃점을 넣어 격자를
#   채운다.  잉크가 적어 압축이 +6 B 로 들어간다 (`?`·`의` 같은 글자는 12~15 B 초과).
DROPPED_SYLLABLES = ("마", "야", "지", "코")   # 코지마·하야사카를 빼면 풀리는 칸
FILLER = "·"                                  # 45 번째 칸 -- 검색어에는 안 쓰인다
ALL_SYLLABLES = tuple(sorted(
    set(LEGACY_SYLLABLES) - set(DROPPED_SYLLABLES) | {"끝", "났", "다"})) + (FILLER,)
SYLLABLES = ALL_SYLLABLES

# Screen order of the last three letter cells.  These do not replace any of the
# 45 kana tokens: they reuse the three modifier-key codes after the delete-key
# entry is moved to the end of the group.
#
#   column 10: key code $1B -> SJIS $815B (ー) -> 해
#   column 11: key code $0A -> SJIS $814A (゛) -> 햄
#   column 12: key code $0B -> SJIS $814B (゜) -> 호
#   column 13: key code $09 -> delete
# 44 키는 전부 원래 카나 코드에 앉는다.  수식키($815B ー / $814A ゛ / $814B ゜)를
# 빌리던 0.7.16~0.7.18 의 배치는 폐기했다 -- 그 세 칸이 없어도 44 개가 다 들어간다.
SPECIAL_TOKENS: tuple[tuple[str, int], ...] = ()

SEARCH_TERMS = {
    "ギリアンシード": "길리언",
    "ジエミーシード": "제이미",
    "ミカスレイトン": "미카",
    "ハリーベンソン": "해리",
    "カトリーヌギブスン": "카트린느",
    "ジヤンジヤツクギブスン": "깁슨",
    "ランダムハジル": "랜덤",
    "リサニールセン": "리사",
    "イザベラベルベツト": "이사벨라",
    "ナポレオン": "나폴레옹",
    "イワンロドリゲス": "이반",
    "メタルギア": "메탈기어",
    "リトルジヨン": "리틀존",
    "ハヤサカタエコ": "하야사카",
    "コジマヒデオ": "코지마",
    "ベンソンカニンガム": "커닝햄",
    "フレデイニールセン": "프레디",
    "チンシユウホウ": "첸슈호",
}

QUIZ_TERMS = {
    "テンカ": "천하",
    "ベンソン": "벤슨",
    "クイーン": "퀸",
}

# The live search index has a second copy of the names.  Test1 only patched the
# first table, so ギブスン correctly returned "no such person".
SEARCH_INDEX_TERMS = {
    "ジヤンジヤツクギブスン": "깁슨",
    "ジヤンジヤツクギブソン": "깁슨",
}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def legacy_token_maps() -> tuple[dict[str, bytes], dict[int, str]]:
    """The exact 45-token layout burned into 0.7.12 through 0.7.15."""
    pairs = list(zip(LEGACY_SYLLABLES, TOKEN_CODES))
    return ({ch: code.to_bytes(2, "big") for ch, code in pairs},
            {code: ch for ch, code in pairs})


def token_maps() -> tuple[dict[str, bytes], dict[int, str]]:
    if len(SYLLABLES) != 45:
        raise RuntimeError(f"keypad must contain exactly 45 cells, got {len(SYLLABLES)}")
    if len(TOKEN_CODES) < len(SYLLABLES):
        raise RuntimeError("not enough kana token codes for the syllable list")
    pairs = list(zip(SYLLABLES, TOKEN_CODES)) + list(SPECIAL_TOKENS)
    if len({ch for ch, _ in pairs}) != len(pairs):
        raise RuntimeError("duplicate Korean syllable in keypad token map")
    if len({code for _, code in pairs}) != len(pairs):
        raise RuntimeError("duplicate SJIS code in keypad token map")
    enc = {ch: code.to_bytes(2, "big") for ch, code in pairs}
    labels = {code: ch for ch, code in pairs}
    return enc, labels


def encode_token_text(text: str, enc: dict[str, bytes]) -> bytes:
    try:
        return b"".join(enc[ch] for ch in text)
    except KeyError as exc:
        raise RuntimeError(f"keypad syllable is missing: {exc.args[0]!r} in {text!r}") from None


def patch_bios(source: Path, target: Path) -> dict:
    enc, labels = token_maps()
    data = bytearray(source.read_bytes())
    table = [data[0x127E + i * 2] | (data[0x127E + i * 2 + 1] << 8)
             for i in range(fmap.ROW_LAST - fmap.ROW_FIRST + 1)]
    glyphs = font.parse_bdf(font.BDF, {ord(ch) for ch in enc})
    missing = [ch for ch in enc if ord(ch) not in glyphs]
    if missing:
        raise RuntimeError("Galmuri keypad glyph missing: " + "".join(missing))

    records = []
    for code, ch in labels.items():
        sjis_char = code.to_bytes(2, "big").decode("cp932")
        row_cell = fmap.jis_of(sjis_char)
        if row_cell is None:
            raise RuntimeError(f"cannot convert token {code:04X} to JIS")
        index = fmap.glyph_index(*row_cell, table)
        if index is None:
            raise RuntimeError(f"token {code:04X} has no BIOS glyph index")
        bbx, bitmap = glyphs[ord(ch)]
        packed = font.pack(font.render(bbx, bitmap), GLYPH_STRIDE)
        at = GLYPH_BASE + index * GLYPH_STRIDE
        before = bytes(data[at:at + GLYPH_STRIDE])
        data[at:at + GLYPH_STRIDE] = packed
        records.append({
            "syllable": ch,
            "token": f"{code:04X}",
            "jis_row": f"{row_cell[0]:02X}",
            "jis_cell": f"{row_cell[1]:02X}",
            "glyph_index": index,
            "rom_offset": f"{at:06X}",
            "changed_bytes": sum(a != b for a, b in zip(before, packed)),
        })
    target.write_bytes(data)
    return {"sha256": sha(data), "glyphs": records, "token_encoder_size": len(enc)}


def patch_prefix(data: bytearray, start: int, end: int, original: str,
                 replacement: str, enc: dict[str, bytes], touched: set[int]) -> list[int]:
    needle = original.encode("cp932")
    repl = encode_token_text(replacement, enc)
    if len(repl) > len(needle):
        raise RuntimeError(f"replacement is longer than source: {original} -> {replacement}")
    found = []
    pos = start
    while True:
        pos = data.find(needle, pos, end)
        if pos < 0:
            break
        # Strings must be wholly inside a Mode-1 user-data area.
        inside = pos % RAW
        if inside < USER or inside + len(needle) > USER + USER_SIZE:
            raise RuntimeError(f"string crosses/non-user sector area at {pos:X}: {original}")
        data[pos:pos + len(repl)] = repl
        touched.add(pos // RAW)
        found.append(pos)
        pos += len(needle)
    if not found:
        raise RuntimeError(f"source string not found in {start:X}-{end:X}: {original}")
    return found


def rebuild_touched(data: bytearray, sectors: set[int]) -> None:
    for sector in sorted(sectors):
        at = sector * RAW
        block = bytearray(data[at:at + RAW])
        if len(block) != RAW:
            raise RuntimeError(f"short raw sector {sector}")
        rawdisc.rebuild_mode1_sector(block)
        data[at:at + RAW] = block


def patch_track02(source: Path, target: Path) -> dict:
    enc, _ = token_maps()
    data = bytearray(source.read_bytes())
    touched: set[int] = set()
    rows = []

    # Main person/developer key table.  Prefix replacement preserves every
    # record's byte length and index; the unmodified suffix is harmless because
    # this screen already accepts prefix searches.
    for original, replacement in SEARCH_TERMS.items():
        hits = patch_prefix(data, 0x111300, 0x111900, original, replacement, enc, touched)
        rows.append({"kind": "person", "original": original, "input": replacement,
                     "offsets": [f"{p:X}" for p in hits]})

    for original, replacement in SEARCH_INDEX_TERMS.items():
        hits = patch_prefix(data, 0x113B00, 0x114300, original, replacement, enc, touched)
        rows.append({"kind": "person_index", "original": original, "input": replacement,
                     "offsets": [f"{p:X}" for p in hits]})

    # Password/keyword tables are intentionally patched as prefixes too.  This
    # test determines whether they share the person's prefix matcher.
    quiz_ranges = {
        "テンカ": (0x0D6600, 0x0D6900),
        "ベンソン": (0x111300, 0x114200),
        "クイーン": (0x1C9F00, 0x1CA100),
    }
    for original, replacement in QUIZ_TERMS.items():
        hits = patch_prefix(data, *quiz_ranges[original], original, replacement, enc, touched)
        rows.append({"kind": "quiz", "original": original, "input": replacement,
                     "offsets": [f"{p:X}" for p in hits]})

    rebuild_touched(data, touched)
    target.write_bytes(data)
    return {"sha256": sha(data), "sectors": sorted(touched), "rows": rows}


def stage_tree() -> tuple[Path, Path]:
    if not SOURCE.is_dir():
        raise SystemExit(f"source build is missing: {SOURCE}")
    if OUT.exists():
        raise SystemExit(f"output already exists (refusing overwrite): {OUT}")
    OUT.mkdir(parents=True)
    source_track = SOURCE / TRACK02_NAME
    source_bios = SOURCE / SOURCE_BIOS_NAME
    if not source_track.exists() or not source_bios.exists():
        raise SystemExit("0.7.11 source Track 02 or BIOS is missing")

    for entry in SOURCE.iterdir():
        if entry.name in {TRACK02_NAME, SOURCE_BIOS_NAME, "manifest.json"}:
            continue
        dest = OUT / entry.name
        if entry.is_dir():
            shutil.copytree(entry, dest, copy_function=os.link)
        else:
            os.link(entry, dest)
    return source_track, source_bios


def write_notes(layout: list[list[str]]) -> None:
    lines = [
        f"{VERSION} - Gaudi precomposed-Hangul keypad experiment",
        "",
        "Use this folder's CUE and BIOS together, then Power Cycle.",
        f"BIOS: {BIOS_NAME}",
        "",
        "Key layout:",
    ]
    for row in layout:
        lines.append("  " + " ".join(row))
    lines += [
        "",
        "Quick checks:",
        "  first:  깁슨 (visible Japanese keys: ウ then ニ)",
        "  people: 랜덤 / 나폴레옹 / 메탈기어",
        "  quiz:   천하 / 벤슨 / 퀸",
        "",
        "Expected limitation: this first proof replaces BIOS kana glyph slots.",
        "If another untranslated screen uses these kana, it will show keypad syllables.",
    ]
    (OUT / "TEST_IN_MESEN_KEYPAD.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    source_track, source_bios = stage_tree()
    bios_info = patch_bios(source_bios, OUT / BIOS_NAME)
    track_info = patch_track02(source_track, OUT / TRACK02_NAME)

    source_manifest = json.loads((SOURCE / "manifest.json").read_text(encoding="utf-8"))
    manifest = dict(source_manifest)
    route_c = dict(manifest.get("route_c", {}))
    route_c["sectors_touched"] = sorted(set(route_c.get("sectors_touched", [])) |
                                         set(track_info["sectors"]))
    manifest["route_c"] = route_c
    manifest.update({
        "version": VERSION,
        "bios": BIOS_NAME,
        "base": str(SOURCE),
        "experiment": "Gaudi 45-key precomposed-Hangul token keyboard",
        "gaudi_keypad_test": {
            "method": "reuse 45 kana codes as opaque tokens; replace their BIOS glyphs",
            "syllables": list(SYLLABLES),
            "spare_keys": ["ー", "ﾞ", "ﾟ"],
            "bios": bios_info,
            "track02": track_info,
            "search_terms": SEARCH_TERMS,
            "search_index_terms": SEARCH_INDEX_TERMS,
            "quiz_terms": QUIZ_TERMS,
            "known_risk": "name table sort assumption and quiz exact-vs-prefix matching require play test",
        },
        "track02_sha256": track_info["sha256"],
        "bios_sha256": bios_info["sha256"],
    })
    (OUT / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    layout = [list(SYLLABLES[i:i + 5]) for i in range(0, 45, 5)]
    write_notes(layout)
    print(f"built {OUT}")
    print(f"BIOS    {bios_info['sha256']}")
    print(f"Track02 {track_info['sha256']}")
    print("sectors " + ",".join(str(n) for n in track_info["sectors"]))


if __name__ == "__main__":
    main()
