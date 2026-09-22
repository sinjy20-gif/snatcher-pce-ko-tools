#!/usr/bin/env python3
"""가우디 인명 검색표를 **저바이트만** 싣는 형식으로 줄인다 (0.7.14 -> 0.7.15).

0.7.14 의 표는 한 글자를 2 바이트로 통째로 싣는다.  실측해 보면 그 상위바이트가
한쪽은 전부 `$83` 이고, 다른 쪽도 `$83` 하나뿐이다 -- 예외는 장음 `ー`(`$81 5B`) 세 번.

```
한글 저바이트 45종  $41..$93
가나 저바이트 41종  $41..$93     (SJIS 가타카나는 $8340-$8396)
```

저바이트가 `$94` 를 넘지 않으므로

  * `$FF` 를 **구분자**로 쓸 수 있다 -> 길이바이트가 필요 없다 (레코드당 -1 B)
  * `$FE` 를 **`ー` 한 글자 전체**를 뜻하는 코드로 쓸 수 있다 -> 장음도 1 B 다
  * `$FD`+저바이트로 한글쪽 `$81xx` 토큰을 나타낸다.  가나다 재배열에서
    `해/햄/호` 세 글자만 이 형식을 써서 표가 3 B 늘어난다.

⚠ 최상위 비트는 표식으로 못 쓴다.  저바이트가 `$80..$93` 까지 실제로 올라와서
(`ギリアン` 의 `リ`=`$8A`) bit7 이 이미 자료다.  처음에 그렇게 짰다가 `pack_right`
의 검사에 걸렸다 -- 인계서가 예상한 "탈출바이트 3 B" 는 `$FE` 방식으로 0 B 가 된다.

형식:

```
레코드  [한글저바이트...] $FF [가나저바이트 · $FE=ー ...] $FF
표 끝   $00                     (한글 저바이트는 $41.. 이라 $00 과 안 겹친다)
```

```
                0.7.14      0.7.15
  코드          114 B       139 B    (+25)
  표            295 B       166 B    (-129)
  합            409 B       305 B
  동굴 여유      17 B       121 B
```

0.7.15 는 **0.7.14 에서** 굽는다.  0.7.12 는 환경 A에 없고, 어차피 동굴
(`$BE56-$C000`) 전체를 갈아끼우므로 출발점이 0.7.12 일 필요가 없다.
대신 전제조건을 "동굴이 정확히 0.7.14 블롭이다" 로 두어 더 강하게 잠근다.
"""
from __future__ import annotations

import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "extraction" / "patch" / "static")]

import build_disc_subtitle_hook as rawdisc  # noqa: E402
import build_gaudi_gibson_hook_test as gibson  # noqa: E402
import build_gaudi_keypad_test as keypad  # noqa: E402
import build_gaudi_search_table_hook as v0714  # noqa: E402

HOOK_CPU = gibson.HOOK_CPU
CAVE_CPU = gibson.CAVE_CPU
HOOK_RAW = gibson.HOOK_RAW
CAVE_RAW = gibson.CAVE_RAW
HOOK_INSTALLED = bytes((0x20, CAVE_CPU & 0xFF, CAVE_CPU >> 8, 0xEA, 0xEA))
CAVE_CAPACITY = 0xC000 - CAVE_CPU

INPUT = 0x363E          # 검색 입력 버퍼
INPUT_CHARS = 0x36B2    # 타이핑한 글자 수 (검색 루틴이 여기에 맞춰 입력을 자른다)

KANA_HI = 0x83          # 기본 상위바이트
LONG_VOWEL = b"\x81\x5b"   # 장음 ー -- 유일한 비-$83 글자
TERM = 0xFF             # 구분자/종결자
ESC_LONG = 0xFE         # 가나쪽에서 ー 한 글자를 뜻한다
ESC_SYMBOL = 0xFD       # 한글쪽에서 다음 저바이트의 상위바이트가 $81 임을 뜻한다
END = 0x00              # 표 끝
RESERVED = (END, ESC_SYMBOL, ESC_LONG, TERM)   # 저바이트가 이 값이면 형식이 깨진다

# ★ 2026-09-15 -- 검색에서 뺀 둘.
#
#   자판 그림 블록은 **화상전화 숫자판**($243-$24E = `1 2 3 / 4 5 6 / 7 8 9 / * 0 #`)과
#   같은 블록이다.  48 키는 거기에 안 들어가서 숫자판을 덮어썼다.
#   `코지마`(<원문 6자>)·`하야사카`(<원문 7자>)는 개발자 이스터에그라 이 둘을
#   빼기로 했다 -- `마 야 지 코` 네 칸이 풀려 자판이 들어간다 (소유자 결정).
#
#   ⚠ `메탈기어`를 빼도 네 칸이 풀리지만 그건 게임 등장인물이라 안 뺀다.
DROPPED_NAMES = ("코지마", "하야사카")
NAME_MAPPINGS = {k: v for k, v in v0714.NAME_MAPPINGS.items() if k not in DROPPED_NAMES}

Asm = v0714.Asm


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


# --------------------------------------------------------------------- 표

def pack_left(korean: str, enc: dict[str, bytes] | None = None) -> bytes:
    """한글 토큰 -> 저바이트열. $81 토큰은 $FD+저바이트로 싣는다."""
    if enc is None:
        enc, _ = keypad.token_maps()
    raw = keypad.encode_token_text(korean, enc)
    if len(raw) % 2:
        raise RuntimeError(f"한글 토큰 길이가 홀수다: {korean}")
    out = bytearray()
    for i in range(0, len(raw), 2):
        hi, lo = raw[i], raw[i + 1]
        if lo in RESERVED:
            raise RuntimeError(f"한글 저바이트 ${lo:02X} 가 예약값과 충돌한다: {korean}")
        if hi == KANA_HI:
            out.append(lo)
        elif hi == 0x81:
            out += bytes((ESC_SYMBOL, lo))
        else:
            raise RuntimeError(f"지원하지 않는 한글 토큰 상위바이트 ${hi:02X}: {korean}")
    if not out:
        raise RuntimeError(f"빈 한글 키: {korean}")
    return bytes(out)


def pack_right(original: str) -> bytes:
    """원본 SJIS 키 -> 저바이트열. `ー` 만 $FE 한 바이트로 바뀐다."""
    raw = original.encode("cp932")
    if len(raw) % 2:
        raise RuntimeError(f"원본 키 길이가 홀수다: {original}")
    out = bytearray()
    for i in range(0, len(raw), 2):
        pair = raw[i:i + 2]
        if pair == LONG_VOWEL:
            out.append(ESC_LONG)
            continue
        hi, lo = pair[0], pair[1]
        if hi != KANA_HI:
            raise RuntimeError(
                f"원본 상위바이트가 ${hi:02X} 다. ${KANA_HI:02X} 와 ー(${LONG_VOWEL.hex()}) 만 실을 수 있다. "
                f"새 글자를 넣으려면 탈출코드를 하나 더 정할 것: {original}")
        if lo in RESERVED:
            raise RuntimeError(f"원본 저바이트 ${lo:02X} 가 예약값과 충돌한다: {original}")
        out.append(lo)
    if not out:
        raise RuntimeError(f"빈 원본 키: {original}")
    return bytes(out)


def make_table(mappings: dict[str, str] | None = None,
               enc: dict[str, bytes] | None = None) -> bytes:
    m = NAME_MAPPINGS if mappings is None else mappings
    table = bytearray()
    for korean, original in m.items():
        table += pack_left(korean, enc) + bytes((TERM,)) + pack_right(original) + bytes((TERM,))
    table.append(END)
    result = bytes(table)
    verify_table(result, m, enc)
    return result


def verify_table(table: bytes, mappings: dict[str, str] | None = None,
                 enc: dict[str, bytes] | None = None) -> None:
    """표를 다시 풀어 원래 문자열이 나오는지 확인한다 (형식 왕복 검사)."""
    m = NAME_MAPPINGS if mappings is None else mappings
    if enc is None:
        enc, _ = keypad.token_maps()
    pos = 0
    for korean, original in m.items():
        end = table.index(TERM, pos)
        left = table[pos:end]
        pos = end + 1
        end = table.index(TERM, pos)
        right = table[pos:end]
        pos = end + 1

        got_left = bytearray()
        i = 0
        while i < len(left):
            if left[i] == ESC_SYMBOL:
                if i + 1 >= len(left):
                    raise RuntimeError(f"잘린 $81 탈출코드: {korean}")
                got_left += bytes((0x81, left[i + 1]))
                i += 2
            else:
                got_left += bytes((KANA_HI, left[i]))
                i += 1
        if bytes(got_left) != keypad.encode_token_text(korean, enc):
            raise RuntimeError(f"한글 왕복 실패: {korean}")

        got_right = bytearray()
        for b in right:
            got_right += LONG_VOWEL if b == ESC_LONG else bytes((KANA_HI, b))
        if bytes(got_right).decode("cp932") != original:
            raise RuntimeError(f"원본 왕복 실패: {korean} -> {original}")
    if table[pos:] != bytes((END,)):
        raise RuntimeError("표 끝 표식이 없거나 레코드가 남았다")


# -------------------------------------------------------------------- 코드

def make_blob(mappings: dict[str, str] | None = None,
              enc: dict[str, bytes] | None = None) -> tuple[bytes, int, int]:
    if enc is None:
        enc, _ = keypad.token_maps()
    supports_symbol = any(code[0] == 0x81 for code in enc.values())
    a = Asm(CAVE_CPU)

    a.emit(0xDA)                                    # PHX
    a.imm_label("table", high=False)
    a.addr(0x8D, "read_ptr")                        # STA read_ptr
    a.imm_label("table", high=True)
    a.addr(0x8D, "read_ptr", 1)                     # STA read_ptr+1

    # --- 레코드 머리: $00 이면 표 끝
    a.label("next")
    a.emit(0xA0, 0x00)                              # LDY #0      표 색인
    a.addr(0x20, "read_byte")
    if supports_symbol:
        a.branch(0xD0, "record")                    # BNE record
        a.addr(0x4C, "done")                        # JMP done (BEQ 범위 밖)
        a.label("record")
    else:
        a.branch(0xF0, "done")                      # historical 0.7.15 layout
    a.emit(0xA2, 0x00)                              # LDX #0      입력 바이트 색인

    # --- 한글쪽 대조: 보통은 저바이트 1 B. $FD+저바이트는 $81 토큰.
    a.label("compare")
    a.addr(0x20, "read_byte")
    a.emit(0xC9, TERM)                              # CMP #$FF    한글 끝?
    a.branch(0xF0, "left_end")
    if supports_symbol:
        a.emit(0xC9, ESC_SYMBOL)                    # CMP #$FD    $81 토큰?
        a.branch(0xF0, "compare_symbol")
    a.emit(0xDD, (INPUT + 1) & 0xFF, (INPUT + 1) >> 8)   # CMP $363F,X  저바이트
    a.branch(0xD0, "skip")
    a.emit(0xBD, INPUT & 0xFF, INPUT >> 8)          # LDA $363E,X  상위바이트
    a.emit(0xC9, KANA_HI)                           # CMP #$83
    a.branch(0xD0, "skip")
    a.emit(0xE8, 0xE8, 0xC8)                        # INX / INX / INY
    a.branch(0x80, "compare")                       # BRA compare

    if supports_symbol:
        a.label("compare_symbol")
        a.emit(0xC8)                                # INY -> 탈출 뒤 저바이트
        a.addr(0x20, "read_byte")
        a.emit(0xDD, (INPUT + 1) & 0xFF, (INPUT + 1) >> 8)
        a.branch(0xD0, "skip")
        a.emit(0xBD, INPUT & 0xFF, INPUT >> 8)      # LDA $363E,X 상위바이트
        a.emit(0xC9, 0x81)                          # CMP #$81
        a.branch(0xD0, "skip")
        a.emit(0xE8, 0xE8, 0xC8)                    # INX / INX / INY
        a.branch(0x80, "compare")

    # --- 표의 한글이 끝났다. 입력도 바로 여기서 끝나야 일치다.
    a.label("left_end")
    a.emit(0xBD, INPUT & 0xFF, INPUT >> 8)          # LDA $363E,X
    a.emit(0xC9, TERM)                              # CMP #$FF
    a.branch(0xD0, "skip")
    a.emit(0xC8)                                    # INY  -> 가나쪽 첫 바이트
    a.branch(0x80, "matched")

    # --- 다음 레코드로: $FF 를 두 번 지날 때까지 전진
    a.label("skip")
    a.emit(0xA0, 0x00)                              # LDY #0
    a.emit(0xA2, 0x02)                              # LDX #2   남은 구분자 수
    a.label("skipscan")
    a.addr(0x20, "read_byte")
    a.emit(0xC8)                                    # INY
    a.emit(0xC9, TERM)                              # CMP #$FF
    a.branch(0xD0, "skipscan")
    a.emit(0xCA)                                    # DEX
    a.branch(0xD0, "skipscan")
    # Y = 이 레코드의 바이트 수 -> read_ptr 에 더한다
    a.emit(0x98, 0x18)                              # TYA / CLC
    a.addr(0x6D, "read_ptr")                        # ADC read_ptr
    a.addr(0x8D, "read_ptr")                        # STA read_ptr
    a.branch(0x90, "next")                          # BCC next
    a.addr(0xEE, "read_ptr", 1)                     # INC read_ptr+1
    a.branch(0x80, "next")

    # --- 일치: 가나 저바이트를 풀어서 입력 버퍼에 쓴다
    a.label("matched")
    a.emit(0xA2, 0x00)                              # LDX #0
    # 저바이트를 **먼저** 쓰면 스택이 필요 없다.  `CMP #$FE` 가 세운 캐리가
    # 두 바이트 모두의 분기를 몰고 간다 -- LDA/STA/INX 는 캐리를 건드리지 않는다.
    a.label("copy")
    a.addr(0x20, "read_byte")
    a.emit(0xC9, TERM)                              # CMP #$FF   가나 끝?
    a.branch(0xF0, "copied")
    a.emit(0xC9, ESC_LONG)                          # CMP #$FE   C=1 이면 ー
    a.branch(0x90, "store_lo")                      # BCC store_lo
    a.emit(0xA9, LONG_VOWEL[1])                     # LDA #$5B
    a.label("store_lo")
    a.emit(0x9D, (INPUT + 1) & 0xFF, (INPUT + 1) >> 8)   # STA $363F,X
    a.emit(0xA9, KANA_HI)                           # LDA #$83
    a.branch(0x90, "store_hi")                      # BCC store_hi
    a.emit(0x3A, 0x3A)                              # DEC A / DEC A  -> $81
    a.label("store_hi")
    a.emit(0x9D, INPUT & 0xFF, INPUT >> 8)          # STA $363E,X
    a.emit(0xE8, 0xE8, 0xC8)                        # INX / INX / INY
    a.branch(0x80, "copy")

    # --- 종결자를 쓰고 글자 수도 갱신한다 (0.7.14 의 자르기 고침을 그대로 승계)
    #
    # 검색 루틴은 진입할 때마다 `$B9A6 LDY $36B2 / ASL A / STA $363E,Y` 로 입력을
    # 타이핑한 글자 수에 맞춰 다시 자른다.  우리 키가 더 길면 뒤가 날아간다.
    # X 는 지금 쓴 바이트 수이고 두 바이트가 한 글자이므로 LSR 로 글자 수를 만든다.
    a.label("copied")
    a.emit(0x9D, INPUT & 0xFF, INPUT >> 8)          # STA $363E,X   (A 는 아직 $FF)
    a.emit(0x8A, 0x4A)                              # TXA / LSR A
    a.emit(0x8D, INPUT_CHARS & 0xFF, INPUT_CHARS >> 8)   # STA $36B2
    a.emit(0xE8)                                    # INX
    a.emit(0xA9, 0x40)                              # LDA #$40
    a.emit(0x9D, INPUT & 0xFF, INPUT >> 8)          # STA $363E,X

    a.label("done")
    a.emit(0xFA, 0xA0, 0xFF, 0xAD, 0xBA, 0x34, 0x60)   # PLX + 덮어쓴 원래 코드 + RTS

    a.label("read_byte")
    a.emit(0xB9)                                    # LDA abs,Y
    a.label("read_ptr")
    a.word("table")
    a.emit(0x60)                                    # RTS

    a.label("table")
    code_size = len(a.code)
    table = make_table(mappings, enc)
    a.code += table
    blob = a.finish()
    if len(blob) > CAVE_CAPACITY:
        raise RuntimeError(f"블롭 {len(blob)} B 가 동굴 {CAVE_CAPACITY} B 를 넘는다")
    return blob, code_size, len(table)


# ------------------------------------------------------------------ 디스크

def _replace_blob(source: Path, target: Path, expected: bytes,
                  enc: dict[str, bytes],
                  mappings: dict[str, str] | None = None) -> dict:
    data = bytearray(source.read_bytes())
    if data[HOOK_RAW:HOOK_RAW + 5] != HOOK_INSTALLED:
        raise RuntimeError(f"검증된 훅이 {HOOK_RAW:X} 에 없다")

    current = data[CAVE_RAW:CAVE_RAW + CAVE_CAPACITY]
    if current[:len(expected)] != expected or any(current[len(expected):]):
        raise RuntimeError("출발 판의 검색 동굴이 기대한 블롭과 다르다")

    blob, code_size, table_size = make_blob(mappings=mappings, enc=enc)
    data[CAVE_RAW:CAVE_RAW + CAVE_CAPACITY] = blob.ljust(CAVE_CAPACITY, b"\x00")
    sector = CAVE_RAW // 2352
    base = sector * 2352
    block = bytearray(data[base:base + 2352])
    rawdisc.rebuild_mode1_sector(block)
    data[base:base + 2352] = block
    target.write_bytes(data)
    return {
        "sha256": sha(data),
        "sector": sector,
        "hook_cpu": f"{HOOK_CPU:04X}",
        "cave_cpu": f"{CAVE_CPU:04X}",
        "capacity": CAVE_CAPACITY,
        "blob_size": len(blob),
        "code_size": code_size,
        "table_size": table_size,
        "free_bytes": CAVE_CAPACITY - len(blob),
        "table_format": "low-byte packed; $FD+$xx = $81xx Korean token; $FE = long vowel; $FF separator",
        "mappings": dict(mappings) if mappings else NAME_MAPPINGS,
    }


def patch_track(source: Path, target: Path) -> dict:
    """Build the historical 0.7.15 blob from a verified 0.7.14 track."""
    expected, _, _ = v0714.make_blob()
    legacy_enc, _ = keypad.legacy_token_maps()
    return _replace_blob(source, target, expected, legacy_enc)


def _blob_0715() -> bytes:
    """0.7.15 디스크에 실제로 구워져 있는 블롭.

    ⚠ 기준값은 **그때의 이름 18 개 · 그때의 토큰 코드**로 만들어야 한다.
    `NAME_MAPPINGS` 는 지금 16 개라(코지마·하야사카 제외) 기본값을 쓰면 안 맞는다.
    """
    legacy_enc, _ = keypad.legacy_token_maps()
    blob, _, _ = make_blob(mappings=v0714.NAME_MAPPINGS, enc=legacy_enc)
    return blob


def repatch_for_sorted_keypad(source: Path, target: Path) -> dict:
    """Replace the 0.7.15 search blob with the 가나다-layout token table."""
    current_enc, _ = keypad.token_maps()
    return _replace_blob(source, target, _blob_0715(), current_enc)


def repatch_from_gibson(source: Path, target: Path) -> dict:
    """갓 구운 판에 얹는다.

    `apply_gaudi_to_build.py` 가 심는 **깁슨 동굴**을 곧장 현행 표(이름 16 + 퀴즈 4)로
    갈아끼운다.  0.7.14 -> 0.7.15 를 거치지 않아도 되므로 마스터를 새로 반영한
    판에 한 번에 올릴 수 있다.
    """
    current_enc, _ = keypad.token_maps()
    return _replace_blob(source, target, gibson.make_cave(), current_enc,
                         mappings=ALL_MAPPINGS)


def repatch_from_0715_with_quiz(source: Path, target: Path) -> dict:
    """0.7.15 -> 45 칸 자판 토큰 + 이름 16 + 퀴즈 4 를 한 번에 얹는다."""
    current_enc, _ = keypad.token_maps()
    return _replace_blob(source, target, _blob_0715(), current_enc,
                         mappings=ALL_MAPPINGS)


# --------------------------------------------------------------- 퀴즈 (step 2)
#
# 퀴즈 답 넷은 인명이 아니다.  `テンカ` 와 `オワツタ` 는 **화제(話題) 목록**에
# 나란히 있고(논리 $0D66D7 · $0D6747, 사본 4 벌), `クイーン` `ベンソン` 은 또
# 다른 목록이다.  자판으로는 넷 다 칠 수 있다 -- 48 키 가나다 배열에 끝·났·다가
# 들어가면서 마지막 하나가 풀렸다.
#
# ⚠ `オワツタ` 는 **큰 ツ** 다.  `オワッタ`(작은 ッ)로는 디스크에 없다.
#
# 이 표는 인명표와 **같은 동굴·같은 비교기**에 얹는다.  퀴즈 화면이 그 비교기를
# 지나가면 그대로 통하고, 다른 오버레이의 비교기를 쓰면 안 통한다 -- 디스크에
# 가우디 검색 구현이 두 벌 있고(논리 $00A13F2 · $00AD1A6) 우리 훅은 뒤엣것에만
# 있다.  어느 쪽인지는 실기 한 번이면 갈린다.
QUIZ_MAPPINGS = {
    "천하": "テンカ",
    "끝났다": "オワツタ",
    "퀸": "クイーン",
    "벤슨": "ベンソン",
}

ALL_MAPPINGS = {**NAME_MAPPINGS, **QUIZ_MAPPINGS}


def repatch_with_quiz(source: Path, target: Path) -> dict:
    """0.7.17 의 동굴을 인명 18 + 퀴즈 4 표로 갈아끼운다."""
    enc, _ = keypad.token_maps()
    expected, _, _ = make_blob(enc=enc)          # 0.7.16/0.7.17 이 실은 블롭
    return _replace_blob(source, target, expected, enc, mappings=ALL_MAPPINGS)


if __name__ == "__main__":
    blob, code_size, table_size = make_blob()
    old, old_code, old_table = v0714.make_blob()
    print("0.7.14  code=%d table=%d blob=%d free=%d" % (old_code, old_table, len(old), CAVE_CAPACITY - len(old)))
    print("0.7.15  code=%d table=%d blob=%d free=%d" % (code_size, table_size, len(blob), CAVE_CAPACITY - len(blob)))
    print("차이    code%+d  table%+d  blob%+d  free%+d"
          % (code_size - old_code, table_size - old_table, len(blob) - len(old),
             (CAVE_CAPACITY - len(blob)) - (CAVE_CAPACITY - len(old))))
