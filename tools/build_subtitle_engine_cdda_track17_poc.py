#!/usr/bin/env python3
"""Track 17의 첫 CD-DA 자막 두 줄을 Lua 없이 돌리는 고정 네이티브 POC.

일반 레코드 renderer(lookup 없음 + VDC 재무장)를 그대로 쓰되, 원래 entry의
14바이트와 엔진 꼬리 여유 69바이트에 16-bit 프레임 타이머를 넣는다.

    36.46 s  첫 줄 record
    40.59 s  둘째 줄 record
    44.72 s  표시 종료

Track 17의 안전 위치가 verified($7900, y=192)일 때만 빌드된다. 다른 트랙을
찾거나 임의 위치로 fallback하는 코드는 이 POC에 없다.
"""
from __future__ import annotations

import hashlib
import json
import struct
from pathlib import Path

import build_subtitle_engine as base
import build_subtitle_engine_ac_record_poc as record_engine
import subtitle_layout as layout


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "cutscene_subs"
PACK = BUILD / "subtitle_pack.bin"
SAFE_POS = BUILD / "cdda_safe_positions.tsv"
OUT = BUILD / "engine_cdda_track17_poc.bin"
INFO = BUILD / "engine_cdda_track17_poc.json"
HELPER_IN = BUILD / "subtitle_vram_helper.bin"
HELPER_OUT = BUILD / "subtitle_vram_helper_cdda_track17.bin"

TRACK = 17
PAT_VRAM = 0x7900
TEXT_Y = 192
SEGMENTS = BUILD / "cdda_segments.tsv"

# 아래 여섯은 **팩과 구간표에서 읽어 채운다** (`records()` 가 채운다).
#
# 예전에는 손으로 박혀 있었다.  그래서 소유자가 스튜디오에서 자막을 나누거나
# 시작 시각을 0.03 초 미는 순간 빌드가 통째로 섰다 (2026-09-01: 「체르노톤
# 연구소, 의문의 대폭발」을 두 조각으로 나누자 LBA 세 개가 전부 어긋났다).
#
# 엔진은 여전히 **두 줄짜리**다.  달라진 것은 "어느 두 줄인가" 를 표가 정한다는
# 것뿐이다.  세 줄 이상은 이 엔진으로 못 그린다 -- 그건 일반화 작업이다.
LBA_FIRST = LBA_SECOND = LBA_END = 0
START_FIRST = START_SECOND = END_SECOND = 0
SAFE_BYTES = 0x5E20 - base.ENGINE_LO
SLOT_BYTES = 671


def u24(blob: bytes, at: int) -> int:
    return int.from_bytes(blob[at:at + 3], "little")


def verified_position() -> None:
    rows = SAFE_POS.read_text(encoding="utf-8-sig").splitlines()
    header = rows[0].split("\t")
    found = []
    for line in rows[1:]:
        values = line.split("\t")
        row = dict(zip(header, values))
        if row.get("track") == str(TRACK):
            found.append(row)
    if len(found) != 1:
        raise SystemExit(f"Track {TRACK} 안전 위치가 정확히 1개가 아니다: {len(found)}")
    row = found[0]
    if (row.get("status") != "verified"
            or int(row.get("vram_base", "0"), 16) != PAT_VRAM
            or int(row.get("text_y", "-1")) != TEXT_Y):
        raise SystemExit(f"Track {TRACK} 안전 위치가 POC 계약과 다르다: {row}")


def opening_window() -> tuple[int, int, float]:
    """트랙 17 오프닝 구간의 절대 LBA 창과 그 시작 시각.

    구간표가 원본이다 -- 팩 색인의 LBA 도 여기서 나온다
    (`build_subtitle_pack`: ``track_base = lba_from - start_sec * 75``).
    """
    lines = SEGMENTS.read_text(encoding="utf-8-sig").splitlines()
    header = lines[0].split("\t")
    best: tuple[int, int, float] | None = None
    for line in lines[1:]:
        row = dict(zip(header, line.split("\t")))
        if row.get("track") != str(TRACK):
            continue
        lba = int(row["lba_from"])
        if best is None or lba < best[0]:
            best = (lba, int(row["lba_to"]), float(row["start_sec"]))
    if best is None:
        raise SystemExit(f"구간표에 트랙 {TRACK} 이 없다: {SEGMENTS}")
    return best


def records(blob: bytes) -> tuple[int, int, int]:
    """오프닝 구간의 **앞 두 줄**을 팩에서 찾아 온다.

    무엇이 고정이고 무엇이 아닌가
    -----------------------------
    고정   두 줄이라는 것.  이 엔진은 기록 포인터를 두 개만 들고, 둘째로 넘어갈
           때 low 바이트 하나만 바꾼다 (`build_tail`).
    아님   어느 두 줄인가.  그것은 표가 정한다.
    """
    global LBA_FIRST, LBA_SECOND, LBA_END, START_FIRST, START_SECOND, END_SECOND

    count, index_off = struct.unpack_from("<HI", blob, 20)
    record_off, = struct.unpack_from("<I", blob, 26)
    win_from, win_to, win_start = opening_window()

    found: list[tuple[int, int, int]] = []
    for i in range(count):
        at = index_off + i * 10
        lo, hi, rec = u24(blob, at), u24(blob, at + 3), u24(blob, at + 6)
        if win_from <= lo < win_to:
            found.append((lo, hi, rec))
    found.sort()
    if len(found) < 2:
        raise SystemExit(
            f"Track {TRACK} 오프닝 구간(LBA {win_from}~{win_to})에 자막이 "
            f"{len(found)} 줄뿐이다.  이 엔진은 두 줄이 있어야 선다")

    (lba_first, hi_first, first), (lba_second, hi_second, second) = found[0], found[1]
    if hi_first != lba_second:
        raise SystemExit(
            f"Track {TRACK} 앞 두 줄이 이어지지 않는다: "
            f"{lba_first}~{hi_first} 다음이 {lba_second}")

    def frames_at(lba: int) -> int:
        return round((win_start + (lba - win_from) / 75.0) * 60)

    LBA_FIRST, LBA_SECOND, LBA_END = lba_first, lba_second, hi_second
    START_FIRST = frames_at(lba_first)
    START_SECOND = frames_at(lba_second)
    END_SECOND = frames_at(hi_second)

    # 타이머는 elapsed 의 **상위 바이트**를 0/1/2 색인으로 쓴다 (`build_tail`:
    # SBC #hi / CMP #$03 / TAX).  세 문턱이 연속한 세 구간에 놓이지 않으면 그
    # 색인이 성립하지 않는다 -- 두 줄의 길이가 그만큼 제약을 받는다.
    pages = (START_FIRST >> 8, START_SECOND >> 8, END_SECOND >> 8)
    if pages[1] != pages[0] + 1 or pages[2] != pages[0] + 2:
        raise SystemExit(
            f"Track {TRACK} 타이머 문턱이 연속한 세 구간에 안 들어간다: "
            f"{START_FIRST}/{START_SECOND}/{END_SECOND} (상위 {pages})\n"
            "  두 줄의 길이를 조절하거나, CD-DA 엔진을 N 줄로 일반화해야 한다")

    for rec in (first, second):
        cells, width, _flags, y, frames = struct.unpack_from(
            "<BBBBH", blob, record_off + rec)
        if y != TEXT_Y or not 1 <= cells <= 19 or not 1 <= width <= 192 or frames <= 0:
            raise SystemExit(
                f"Track {TRACK} 기록이 이상하다 at +{rec}: "
                f"{cells}칸/{width}px/y{y}/{frames}f")
    return record_off, first, second


def build_tail(origin: int, known: dict[str, int], ptr_second_lo: int,
               labels: dict[str, int] | None = None) -> tuple[bytes, dict[str, int]]:
    merged = dict(known)
    if labels:
        merged.update(labels)
    a = base.Asm(origin, merged)
    a.label("timer")
    # entry가 A=elapsed.hi로 들어온다. hi-$08은 0/1/2 세 구간의 index다.
    a.emit(0x38, 0xE9, START_FIRST >> 8)          # SEC / SBC #$08
    a.branch(0x90, "timer_ret")                  # < 36 s
    a.emit(0xC9, 0x03)
    a.branch(0xB0, "timer_ret")                  # >= 45 s
    a.emit(0xAA)                                  # TAX: 0=첫 줄,1=둘째,2=끝
    a.abs_(0xAD, "elapsed")
    a.emit(0xDD); a.word("threshold_low")         # CMP low_table,X
    a.branch(0x90, "desired")
    a.emit(0xE8)                                  # 해당 초의 문턱을 넘었으면 다음 상태

    a.label("desired")
    a.emit(0xE0, 0x00); a.branch(0xF0, "timer_ret")
    a.emit(0xE0, 0x03); a.branch(0xF0, "timer_ret")
    a.emit(0xE0, 0x01); a.branch(0xF0, "first_line")

    # 둘째 줄. record_ptr의 low byte 자체를 phase 표식으로 쓴다.
    a.abs_(0xAD, known["record_ptr"])
    a.emit(0xC9, ptr_second_lo); a.branch(0xF0, "timer_push")
    a.emit(0xA9, ptr_second_lo); a.abs_(0x8D, known["record_ptr"])
    a.emit(0x4C); a.word(known["rebuild"])

    a.label("first_line")
    a.abs_(0xAD, known["ready"]); a.branch(0xD0, "timer_push")
    # stage 앞 31 B는 최초 한 번만 실행하는 팔레트 초기화 루틴이다.
    a.abs_(0x20, known["stage"])
    a.emit(0x4C); a.word(known["rebuild"])

    a.label("timer_push")
    a.emit(0x4C); a.word(known["push"])
    a.label("timer_ret")
    a.emit(0x60)
    a.label("threshold_low")
    a.emit(START_FIRST & 0xFF, START_SECOND & 0xFF, END_SECOND & 0xFF)
    a.label("elapsed")
    a.emit(0x00, 0x00)
    return a.finish(), a.labels


def build_entry(origin: int, known: dict[str, int]) -> bytes:
    a = base.Asm(origin, known)
    a.abs_(0xEE, known["elapsed"])
    a.branch(0xD0, "tick")
    a.abs_(0xEE, known["elapsed"] + 1)
    a.label("tick")
    a.abs_(0xAD, known["elapsed"] + 1)
    a.emit(0x4C); a.word(known["timer"])
    code = a.finish()
    if len(code) != 14:
        raise SystemExit(f"CDDA entry must replace exact 14 B, got {len(code)}")
    return code


def make_helper() -> bytes:
    helper = bytearray(HELPER_IN.read_bytes())
    if len(helper) != layout.HELPER_SLOT_BYTES or helper[:3] != b"SUB":
        raise SystemExit("dynamic helper input mismatch")
    ctl = layout.HELPER_CTL
    expected = bytes((layout.PAT_VRAM & 0xFF, layout.PAT_VRAM >> 8,
                      (layout.PAT_VRAM >> 13) & 7,
                      (layout.PAT_VRAM >> 5) & 0xFF))
    if bytes(helper[ctl + 4:ctl + 8]) != expected:
        raise SystemExit("dynamic helper default control block drifted")
    helper[ctl + 4:ctl + 8] = bytes((PAT_VRAM & 0xFF, PAT_VRAM >> 8,
                                    (PAT_VRAM >> 13) & 7,
                                    (PAT_VRAM >> 5) & 0xFF))
    HELPER_OUT.write_bytes(helper)
    return bytes(helper)


def main() -> None:
    verified_position()
    blob = PACK.read_bytes()
    if blob[:4] != b"SNSB" or struct.unpack_from("<H", blob, 4)[0] != 6:
        raise SystemExit("subtitle pack must be SNSB v6")
    record_off, first_rec, second_rec = records(blob)
    glyph_off, = struct.unpack_from("<I", blob, 10)
    ptr_first = layout.AC_PACK + record_off + first_rec
    ptr_second = layout.AC_PACK + record_off + second_rec
    if (ptr_first >> 8) != (ptr_second >> 8):
        raise SystemExit("POC compact pointer switch requires same middle/high bytes")

    old_vram = layout.PAT_VRAM
    try:
        layout.PAT_VRAM = PAT_VRAM
        args = dict(glyph_base=layout.AC_PACK + glyph_off, lookup=False,
                    timed=False, overlay_palette=True, vdc_rearm=True)
        first, labels = record_engine.build(None, **args)
        engine, labels = record_engine.build(labels, **args)
    finally:
        layout.PAT_VRAM = old_vram
    if len(first) != len(engine) or len(engine) != 602:
        raise SystemExit(f"generic CDDA base renderer drifted: {len(engine)} != 602")

    # no-lookup renderer의 정적 record_ptr를 첫 줄에 맞춘다.
    image = bytearray(engine)
    rp = labels["record_ptr"] - base.ENGINE_LO
    image[rp:rp + 3] = ptr_first.to_bytes(3, "little")

    tail_origin = base.ENGINE_LO + len(image)
    tail1, tail_labels = build_tail(tail_origin, labels, ptr_second & 0xFF)
    merged = dict(labels); merged.update(tail_labels)
    tail, tail_labels = build_tail(tail_origin, labels, ptr_second & 0xFF, tail_labels)
    if len(tail) != len(tail1):
        raise SystemExit("CDDA tail two-pass size mismatch")
    merged.update(tail_labels)
    if len(tail) > SLOT_BYTES - len(image):
        raise SystemExit(f"CDDA timer tail overflow: {len(tail)} > {SLOT_BYTES-len(image)}")

    entry = build_entry(labels["entry"], merged)
    entry_at = labels["entry"] - base.ENGINE_LO
    rebuild_at = labels["rebuild"] - base.ENGINE_LO
    if rebuild_at - entry_at != len(entry):
        raise SystemExit("generic entry replacement no longer ends at rebuild")
    image[entry_at:rebuild_at] = entry
    image += tail
    image += bytes(SLOT_BYTES - len(image))
    if len(image) != SLOT_BYTES or len(image) > SAFE_BYTES:
        raise SystemExit(f"CDDA renderer size invalid: {len(image)} / {SAFE_BYTES}")

    OUT.write_bytes(image)
    helper = make_helper()
    info = {
        "purpose": "Track 17 c17_001 two-line native CD-DA POC",
        "engine_bytes": len(image), "safe_limit": SAFE_BYTES,
        "generic_bytes": len(engine), "timer_tail_bytes": len(tail),
        "pat_vram": f"{PAT_VRAM:04X}", "text_y": TEXT_Y,
        "track_raw": "10", "track_play": 17,
        "threshold_frames": [START_FIRST, START_SECOND, END_SECOND],
        "threshold_seconds_60hz": [v / 60 for v in
                                    (START_FIRST, START_SECOND, END_SECOND)],
        "record_offsets": [first_rec, second_rec],
        "record_addresses": [f"{ptr_first:06X}", f"{ptr_second:06X}"],
        "pack_sha256": hashlib.sha256(blob).hexdigest().upper(),
        "engine_sha256": hashlib.sha256(image).hexdigest().upper(),
        "helper_sha256": hashlib.sha256(helper).hexdigest().upper(),
        "labels": {k: v - base.ENGINE_LO for k, v in sorted(merged.items())},
    }
    INFO.write_text(json.dumps(info, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"CDDA Track17 renderer {len(image)}/{SAFE_BYTES} B "
          f"(generic {len(engine)} + timer {len(tail)} + pad)")
    print(f"  frames {START_FIRST} -> {START_SECOND} -> {END_SECOND}")
    print(f"  records AC ${ptr_first:06X} -> ${ptr_second:06X} · VRAM ${PAT_VRAM:04X}")
    print(f"  helper default ${PAT_VRAM:04X}: {HELPER_OUT}")
    print(OUT)


if __name__ == "__main__":
    main()
