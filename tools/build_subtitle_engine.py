#!/usr/bin/env python3
"""자막 엔진을 만든다 -- `$5B80` 에 음성 중에만 올라가는 704 B.

자리 나눔
---------
    $7FA0  상주부 32 B    디스크에 구워져 있다.  매 프레임 돌며 매직만 본다
    $5B80  엔진           음성 중에만 올라온다.  실제 일은 전부 여기서
    $1C0000 AC            글꼴·자막 데이터

상주부가 `$5B80` 의 매직 `SUB` 를 보고 `JSR $5B83` 한다.  그러므로 엔진은
**첫 3 바이트가 매직**이고 진입점이 `$5B83` 이다.

엔진이 하는 일
--------------
    1  아직이면 글리프 패턴을 AC -> 창 -> VRAM $7900 에 올리고 팔레트를 세운다
    2  레코드를 zp 에 걸고 게임의 푸시 루프 `$6463` 을 부른다

2 번이 핵심이다.  **VDC 를 우리가 직접 안 건드린다.**  게임이 SATB 를 조립하기
직전에 우리 것을 먼저 밀어 넣으므로 슬롯 0 부터 차지하고, 따라서 그림·초상화보다
앞에 그려진다.  MAWR 은 `$6008` 에서 이미 슬롯 0 에 서 있고 우리 푸시가 `$17` 을
깎으므로 `$60A6` 의 0 채우기도 저절로 맞는다.

레코드 (글자당 5 B · `$6463` 이 먹는 형태)
    00 00 <x오프셋> <패턴워드 lo> <0x80 | (패턴워드 hi << 4)>

이 판이 그리는 것
-----------------
한 줄을 고정으로 그린다.  팩에서 골라 오는 것은 다음 판이다 -- 먼저 디스크에
구운 훅으로 글자가 뜨는지부터 본다.

    python tools/build_subtitle_engine.py --text "금일부로 JUNKER로 임명된"
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "build" / "cutscene_subs"
FONT_BIN = OUT_DIR / "subfont_Galmuri9.bin"
FONT_TSV = OUT_DIR / "subfont_Galmuri9.tsv"

ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E3F        # 스크립트 VM 데이터 스택.  음성 중에만
ENGINE_BYTES = ENGINE_HI - ENGINE_LO + 1     # 704
MAGIC = b"SUB"
ENTRY = ENGINE_LO + len(MAGIC)               # $5B83

sys.path.insert(0, str(Path(__file__).resolve().parent))
import subtitle_layout as L     # noqa: E402

# ★ 팩 자리($1C0000)가 아니라 **스테이징 자리**에서 읽는다.
# 예전에는 둘 다 $1C0000 이라, 팩을 AC 에 올리는 순간 첫 글자가 팩 머리를 덮었다.
AC_BASE = L.AC_GLYPH_STAGE
AC_PORT = 0x1A00
VDC_MAWR, VDC_VWR = 0x00, 0x02
VCE_ADDR_LO, VCE_ADDR_HI = 0x0402, 0x0403
VCE_DATA_LO, VCE_DATA_HI = 0x0404, 0x0405
PAT_VRAM = 0x7900                             # 워드.  ★ 상수로 박으면 안 된다 --
                                              # 원본에서 나온 값이고 KO 빌드는 다르다
                                              # (STATE 2026-08-23: "컷신마다 다름")
SPRITE_WORDS = 64                             # 16x16 4 플레인 한 개
GLYPH_BYTES = 64                              # 우리 글리프는 2 플레인만 싣는다
PUSH_LOOP = 0x6463                            # 게임의 SATB 푸시 루프


class Asm:
    """두 번 훑는 어셈블러.  전방 참조는 항상 2 B 라 크기가 안 변한다."""

    def __init__(self, origin: int, labels: dict[str, int] | None = None) -> None:
        self.origin = origin
        self.code = bytearray()
        self.labels: dict[str, int] = {}
        self.known = labels or {}
        self.fixups: list[tuple[int, str]] = []

    @property
    def pc(self) -> int:
        return self.origin + len(self.code)

    def label(self, name: str) -> None:
        self.labels[name] = self.pc

    def emit(self, *values: int) -> None:
        self.code += bytes(values)

    def word(self, value: int | str) -> None:
        if isinstance(value, str):
            value = self.known.get(value, 0)
        self.emit(value & 0xFF, (value >> 8) & 0xFF)

    def abs_(self, opcode: int, target: int | str) -> None:
        self.emit(opcode)
        self.word(target)

    def branch(self, opcode: int, name: str) -> None:
        self.emit(opcode, 0)
        self.fixups.append((len(self.code) - 1, name))

    def finish(self) -> bytes:
        for at, name in self.fixups:
            delta = self.labels[name] - (self.origin + at + 1)
            if not -128 <= delta <= 127:
                raise SystemExit(f"분기가 너무 멀다: {name} ({delta})")
            self.code[at] = delta & 0xFF
        return bytes(self.code)


def load_line(text: str) -> tuple[list[tuple[int, int]], int]:
    """문장 -> [(글꼴 오프셋, 펜 위치)] · 줄 폭."""
    table: dict[str, tuple[int, int]] = {}
    with FONT_TSV.open(encoding="utf-8-sig") as fh:
        for row in csv.DictReader(fh, delimiter="\t", quoting=csv.QUOTE_NONE):
            if len(row["char"]) == 1:
                table[row["char"]] = (int(row["offset"], 16), int(row["advance"]))
    out, pen = [], 0
    for char in text:
        got = table.get(char)
        if got is None:
            continue
        out.append((got[0], pen))
        pen += got[1]
    return out, pen


def set_ac(a: Asm, address: int) -> None:
    """AC 포트 0 을 address 에 세우고 자동 증가를 켠다."""
    for value, port in ((address & 0xFF, 0x1A02),
                        ((address >> 8) & 0xFF, 0x1A03),
                        ((address >> 16) & 0xFF, 0x1A04)):
        a.emit(0xA9, value)
        a.abs_(0x8D, port)
    a.emit(0xA9, 0x01); a.abs_(0x8D, 0x1A07)      # 자동 증가
    a.abs_(0x9C, 0x1A08)                           # STZ
    a.emit(0xA9, 0x11); a.abs_(0x8D, 0x1A09)


def set_vram_write(a: Asm, word_addr: int) -> None:
    a.emit(0x03, VDC_MAWR)                         # ST0
    a.emit(0x13, word_addr & 0xFF)                 # ST1
    a.emit(0x23, word_addr >> 8)                   # ST2
    a.emit(0x03, VDC_VWR)                          # ST0


def build(count: int, records: bytes, text_y: int, center_x: int, palette: int,
          pat_vram: int, reserve: int = 0,
          labels: dict[str, int] | None = None) -> tuple[bytes, dict[str, int]]:
    a = Asm(ENGINE_LO, labels)
    a.emit(*MAGIC)                                 # $5B80  매직 -- 상주부가 이걸 본다
    a.label("entry")                               # $5B83

    # ---- 아직이면 패턴과 팔레트를 올린다 (한 번만) ----
    a.abs_(0xAD, "ready"); a.branch(0xD0, "push")

    set_ac(a, AC_BASE)
    set_vram_write(a, pat_vram)
    a.label("count_x"); a.emit(0xA2, count)        # LDX #count  (스테이징 횟수)
    a.label("pat_loop")
    a.emit(0xF3); a.word(AC_PORT); a.word("stage"); a.word(GLYPH_BYTES)
    a.emit(0xE3); a.word("stage"); a.word(VDC_VWR); a.word(SPRITE_WORDS * 2)
    a.emit(0xCA); a.branch(0xD0, "pat_loop")       # DEX / BNE

    # 스프라이트 팔레트의 색 1(흰) · 2(검) -- 글자와 외곽선
    #
    # 팔레트 0 을 쓰면 **메뉴 선택 하이라이트가 깨진다** (실측).  게임이 그것을
    # 쓰고 있다.  VCE 에서 스프라이트 팔레트 N 의 색 C 는 $100 + N*16 + C 다.
    # 색 1 을 쓰고 나면 주소가 저절로 올라가므로 색 2 는 이어서 쓰면 된다.
    vce = 0x100 + palette * 16 + 1
    a.emit(0xA9, vce & 0xFF); a.abs_(0x8D, VCE_ADDR_LO)
    a.emit(0xA9, vce >> 8); a.abs_(0x8D, VCE_ADDR_HI)
    a.emit(0xA9, 0xFF); a.abs_(0x8D, VCE_DATA_LO)
    a.emit(0xA9, 0x01); a.abs_(0x8D, VCE_DATA_HI)
    a.emit(0xA9, 0x00); a.abs_(0x8D, VCE_DATA_LO)
    a.emit(0xA9, 0x00); a.abs_(0x8D, VCE_DATA_HI)
    a.emit(0xA9, 0x01); a.abs_(0x8D, "ready")

    # ---- 레코드를 걸고 게임 푸시 루프를 부른다 ----
    a.label("push")
    y, x = text_y + 64, center_x + 32              # SATB 는 y+64 · x+32 기준
    # org+1 = y 하위 · org+5 = y 상위 · org+9 = x 하위 · org+13 = x 상위
    # 자막마다 자리가 다르므로 (위/중간/아래) 런타임이 여기를 바꿔 쓴다
    a.label("org")
    a.emit(0xA9, y & 0xFF, 0x85, 0x08)
    a.emit(0xA9, y >> 8, 0x85, 0x09)
    a.emit(0xA9, x & 0xFF, 0x85, 0x0A)
    a.emit(0xA9, x >> 8, 0x85, 0x0B)
    a.emit(0x64, 0x0C, 0x64, 0x0D, 0x64, 0x0E, 0x64, 0x0F)     # STZ $0C-$0F
    a.emit(0xA9, (a.known.get("list", 0)) & 0xFF, 0x85, 0x10)
    a.emit(0xA9, (a.known.get("list", 0) >> 8) & 0xFF, 0x85, 0x11)
    a.label("count_a"); a.emit(0xA9, count, 0x85, 0x16)
    a.abs_(0x20, PUSH_LOOP)
    a.emit(0x60)                                   # RTS

    a.label("ready"); a.emit(0)
    a.label("list"); a.emit(*records)
    if reserve > len(records):                     # 더 긴 대사가 들어올 자리
        a.emit(*([0] * (reserve - len(records))))
    a.label("stage")
    for _ in range(SPRITE_WORDS * 2):              # 128 B · 위 64 B 는 0 (플레인 2·3)
        a.emit(0)
    return a.finish(), a.labels


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--text", default="금일부로 JUNKER로 임명된")
    parser.add_argument("--text-y", type=int, default=122)
    parser.add_argument("--center-x", type=int, default=128)
    parser.add_argument("--palette", type=int, default=15,
                        help="스프라이트 팔레트 번호 0-15 (기본 15).  0 은 메뉴가 쓴다")
    parser.add_argument("--max-glyphs", type=int, default=9,
                        help="레코드 자리를 이만큼 잡아 둔다.  ★ VRAM 도 이만큼 쓴다.  "
                             "글은 이 값보다 한 자 적게 써야 안 잘린다 -- "
                             "9 까지만 검증됐다 ($7900-$7B3F)")
    parser.add_argument("--pat-vram", type=lambda s: int(s, 16), default=PAT_VRAM,
                        help="글리프를 올릴 VRAM 워드 주소 (16 진).  기본 7900 -- "
                             "KO 빌드에서 메뉴 하이라이트와 겹친다는 의심이 있다")
    args = parser.parse_args()

    if not FONT_BIN.exists():
        raise SystemExit(f"글꼴이 없다: {FONT_BIN}")
    font = FONT_BIN.read_bytes()
    glyphs, width = load_line(args.text)
    if not glyphs:
        raise SystemExit("글꼴에 있는 글자가 하나도 없다")
    count = len(glyphs)

    half = width // 2
    records = bytearray()
    for i, (_, pen) in enumerate(glyphs):
        word = ((args.pat_vram >> 6) << 1) + 2 * i
        offset = max(-128, min(127, pen - half))
        # 5 번째 바이트: 비트 7 = 앞쪽 우선 · 비트 4-6 = 패턴 상위 · 비트 0-3 = 팔레트
        # ($6463 이 AND #$70 으로 패턴을, AND #$8F 로 속성을 뽑는다)
        records += bytes((0x00, 0x00, offset & 0xFF, word & 0xFF,
                          0x80 | ((word >> 8) << 4) | (args.palette & 0x0F)))

    reserve = args.max_glyphs * 5
    first, labels = build(count, bytes(records), args.text_y, args.center_x,
                          args.palette, args.pat_vram, reserve)
    engine, labels = build(count, bytes(records), args.text_y, args.center_x,
                           args.palette, args.pat_vram, reserve, labels)
    if len(engine) != len(first):
        raise SystemExit("두 조립의 크기가 다르다 -- 전방 참조 처리가 틀렸다")
    if len(engine) > ENGINE_BYTES:
        raise SystemExit(f"★ {len(engine)} B > {ENGINE_BYTES} B")

    patterns = bytearray()
    for offset, _ in glyphs:
        patterns += font[offset:offset + GLYPH_BYTES]

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    (OUT_DIR / "engine.bin").write_bytes(engine)
    (OUT_DIR / "engine_patterns.bin").write_bytes(bytes(patterns))
    info = {
        "text": args.text, "glyphs": count, "line_width_px": width,
        "screen_x": [args.center_x - half, args.center_x - half + width - 1],
        "screen_y": [args.text_y, args.text_y + 15],
        "engine_base": f"{ENGINE_LO:04X}", "entry": f"{ENTRY:04X}",
        "magic": MAGIC.decode(), "engine_bytes": len(engine),
        "budget": ENGINE_BYTES, "free": ENGINE_BYTES - len(engine),
        "labels": {k: f"{v:04X}" for k, v in sorted(labels.items())},
        # Lua 가 대사마다 바꿔 쓰는 자리 (엔진 파일 안 오프셋)
        "offsets": {k: labels[k] - ENGINE_LO for k in
                    ("ready", "list", "count_x", "count_a", "org") if k in labels},
        "max_glyphs": args.max_glyphs, "record_bytes": 5,
        "palette": args.palette, "pat_vram": f"{args.pat_vram:04X}",
        "ac_base": f"{AC_BASE:06X}", "ac_pattern_bytes": len(patterns),
        "resident_stub": "7FA0", "hook": "601E",
    }
    (OUT_DIR / "engine.json").write_text(json.dumps(info, ensure_ascii=False, indent=2),
                                         encoding="utf-8")

    print(f'"{args.text}"  {count} 글자 · {width} px · '
          f'화면 x {info["screen_x"][0]}..{info["screen_x"][1]} · y {args.text_y}')
    print(f"엔진 {len(engine)} B / {ENGINE_BYTES} B   여유 {ENGINE_BYTES - len(engine)} B")
    for name in ("entry", "pat_loop", "push", "ready", "list", "stage"):
        if name in labels:
            print(f"    {name:8s} ${labels[name]:04X}")
    print(f"스프라이트 팔레트 {args.palette}  (VCE ${0x100 + args.palette * 16 + 1:03X})")
    print(f"VRAM 워드 ${args.pat_vram:04X}-${args.pat_vram + count * 0x40 - 1:04X}  "
          f"({count} x $40)")
    print(f"AC 글리프 스테이징 ${AC_BASE:06X}  패턴 {len(patterns)} B")
    print(f"  {OUT_DIR / 'engine.bin'}")
    print(f"  {OUT_DIR / 'engine_patterns.bin'}")


if __name__ == "__main__":
    main()
