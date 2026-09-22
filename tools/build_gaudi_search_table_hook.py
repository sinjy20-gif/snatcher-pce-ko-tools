#!/usr/bin/env python3
"""Expand the proven Gaudi search hook from Gibson to all Korean name keys.

The visible Korean syllables remain the original two-byte kana token codes.
At the proven comparator entry the routine matches the complete Korean token
sequence and replaces it with the exact original key that was play-tested.
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

HOOK_CPU = gibson.HOOK_CPU
CAVE_CPU = gibson.CAVE_CPU
HOOK_RAW = gibson.HOOK_RAW
CAVE_RAW = gibson.CAVE_RAW
HOOK_INSTALLED = bytes((0x20, CAVE_CPU & 0xFF, CAVE_CPU >> 8, 0xEA, 0xEA))
CAVE_CAPACITY = 0xC000 - CAVE_CPU

# Left: what the player types on the Korean keypad.
# Right: the shortest original key confirmed to open the intended person file.
NAME_MAPPINGS = {
    "길리언": "ギリアン",
    "제이미": "ジエミー",
    "미카": "ミカ",
    "해리": "ハリー",
    "카트린느": "カトリーヌ",
    "깁슨": "ギブスン",
    "랜덤": "ランダム",
    "리사": "リサ",
    "이사벨라": "イザベラ",
    "나폴레옹": "ナポレオン",
    "이반": "イワン",
    "메탈기어": "メタルギア",
    "리틀존": "リトル",
    "하야사카": "ハヤサカタエコ",
    "코지마": "コジマヒデオ",
    "커닝햄": "ベンソンカニンガム",
    "프레디": "フレデイ",
    "첸슈호": "チン",
}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


class Asm:
    def __init__(self, origin: int):
        self.origin = origin
        self.code = bytearray()
        self.labels: dict[str, int] = {}
        self.branches: list[tuple[int, str]] = []
        self.words: list[tuple[int, str, int]] = []
        self.bytes: list[tuple[int, str, int, bool]] = []

    @property
    def pc(self) -> int:
        return self.origin + len(self.code)

    def emit(self, *values: int) -> None:
        self.code.extend(value & 0xFF for value in values)

    def label(self, name: str) -> None:
        if name in self.labels:
            raise RuntimeError(f"duplicate label: {name}")
        self.labels[name] = self.pc

    def branch(self, opcode: int, target: str) -> None:
        self.emit(opcode, 0)
        self.branches.append((len(self.code) - 1, target))

    def addr(self, opcode: int, target: str, add: int = 0) -> None:
        self.emit(opcode, 0, 0)
        self.words.append((len(self.code) - 2, target, add))

    def word(self, target: str, add: int = 0) -> None:
        self.emit(0, 0)
        self.words.append((len(self.code) - 2, target, add))

    def imm_label(self, target: str, *, high: bool) -> None:
        self.emit(0xA9, 0)
        self.bytes.append((len(self.code) - 1, target, 0, high))

    def finish(self) -> bytes:
        for pos, target, add in self.words:
            value = self.labels[target] + add
            self.code[pos:pos + 2] = value.to_bytes(2, "little")
        for pos, target, add, high in self.bytes:
            value = self.labels[target] + add
            self.code[pos] = (value >> 8 if high else value) & 0xFF
        for operand, target in self.branches:
            dest = self.labels[target]
            next_pc = self.origin + operand + 1
            delta = dest - next_pc
            if not -128 <= delta <= 127:
                raise RuntimeError(f"branch out of range: {target} ({delta})")
            self.code[operand] = delta & 0xFF
        return bytes(self.code)


def make_table() -> bytes:
    enc, _ = keypad.legacy_token_maps()
    table = bytearray()
    for korean, original in NAME_MAPPINGS.items():
        left = keypad.encode_token_text(korean, enc)
        right = original.encode("cp932")
        if not 0 < len(left) < 0xFF or 0xFF in left or 0xFF in right:
            raise RuntimeError(f"invalid mapping record: {korean} -> {original}")
        table += bytes((len(left),)) + left + right + b"\xff"
    table += b"\x00"
    result = bytes(table)
    verify_table(result)
    return result


def verify_table(table: bytes) -> None:
    enc, _ = keypad.legacy_token_maps()
    pos = 0
    for korean, original in NAME_MAPPINGS.items():
        length = table[pos]
        pos += 1
        left = table[pos:pos + length]
        pos += length
        end = table.index(0xFF, pos)
        right = table[pos:end]
        pos = end + 1
        if left != keypad.encode_token_text(korean, enc) or right != original.encode("cp932"):
            raise RuntimeError(f"table round-trip failed: {korean} -> {original}")
    if table[pos:] != b"\x00":
        raise RuntimeError("mapping table has trailing or missing records")


def make_blob() -> tuple[bytes, int, int]:
    a = Asm(CAVE_CPU)
    a.emit(0xDA)                                      # PHX
    a.imm_label("table", high=False)
    a.addr(0x8D, "read_ptr")                         # STA read_ptr
    a.imm_label("table", high=True)
    a.addr(0x8D, "read_ptr", 1)                      # STA read_ptr+1

    a.label("next")
    a.emit(0xA0, 0x00)                                # LDY #0
    a.addr(0x20, "read_byte")                        # JSR read_byte
    a.branch(0xF0, "done")                           # zero ends table
    a.emit(0xAA, 0xA0, 0x01)                          # TAX / LDY #1

    a.label("compare")
    a.addr(0x20, "read_byte")                        # table byte
    a.emit(0xD9, 0x3D, 0x36)                          # CMP $363D,Y (input)
    a.branch(0xD0, "skip")
    a.emit(0xC8, 0xCA)                                # INY / DEX
    a.branch(0xD0, "compare")
    a.emit(0xB9, 0x3D, 0x36, 0xC9, 0xFF)             # input must end here
    a.branch(0xF0, "matched")

    a.label("skip")
    a.emit(0xA0, 0x00)
    a.addr(0x20, "read_byte")                        # reload Korean byte length
    a.emit(0xA8, 0xC8)                                # TAY / INY -> output
    a.label("scan")
    a.addr(0x20, "read_byte")
    a.emit(0xC9, 0xFF)
    a.branch(0xF0, "advance")
    a.emit(0xC8)
    a.branch(0x80, "scan")

    a.label("advance")
    a.emit(0xC8, 0x98, 0x18)                          # INY / TYA / CLC
    a.addr(0x6D, "read_ptr")                         # ADC read_ptr
    a.addr(0x8D, "read_ptr")                         # STA read_ptr
    a.branch(0x90, "next")                           # BCC next
    a.addr(0xEE, "read_ptr", 1)                      # INC read_ptr+1
    a.branch(0x80, "next")

    a.label("matched")                               # Y points to original key
    a.emit(0xA2, 0x00)                                # LDX #0
    a.label("copy")
    a.addr(0x20, "read_byte")
    a.emit(0xC9, 0xFF)
    a.branch(0xF0, "copied")
    a.emit(0x9D, 0x3E, 0x36, 0xC8, 0xE8)             # STA input,X / INY / INX
    a.branch(0x80, "copy")
    a.label("copied")
    # $FF 종결자를 쓰고, **글자 수도 새 키 길이로 갱신한다**.
    #
    # 검색 루틴은 진입할 때마다 `$B9A6 LDY $36B2 / ASL A / STA $363E,Y` 로
    # 입력을 **타이핑한 글자 수**에 맞춰 다시 자른다 (2026-09-14 실측).
    # 우리 키는 그보다 길어서 뒤가 날아가고, 그 결과 `ギリアン`->`ギリア`,
    # `ギブスン`->`ギブ` 가 되어 검색이 실패했다.  4 번째 글자가 `ー`($81 5B)로
    # 시작하는 이름(제이미·해리)만 비교가 거기서 끝나 우연히 살아남았다.
    #
    # X 는 지금 복사한 바이트 수다.  두 바이트가 한 글자이므로 LSR 로 글자 수를
    # 만들어 `$36B2` 에 넣으면, 다음 자르기가 우리 종결자 자리에 떨어진다.
    a.emit(0x9D, 0x3E, 0x36)                         # STA input,X   ($FF)
    a.emit(0x8A, 0x4A, 0x8D, 0xB2, 0x36)             # TXA / LSR A / STA $36B2
    a.emit(0xE8, 0xA9, 0x40, 0x9D, 0x3E, 0x36)       # INX / LDA #$40 / STA input,X

    a.label("done")
    a.emit(0xFA, 0xA0, 0xFF, 0xAD, 0xBA, 0x34, 0x60)  # PLX + overwritten code + RTS

    a.label("read_byte")
    a.emit(0xB9)                                      # LDA abs,Y
    a.label("read_ptr")
    a.word("table")
    a.emit(0x60)
    a.label("table")
    code_size = len(a.code)
    table = make_table()
    a.code += table
    blob = a.finish()
    if len(blob) > CAVE_CAPACITY:
        raise RuntimeError(f"search blob {len(blob)} B exceeds cave {CAVE_CAPACITY} B")
    return blob, code_size, len(table)


def patch_track(source: Path, target: Path) -> dict:
    data = bytearray(source.read_bytes())
    old = gibson.make_cave()
    if data[HOOK_RAW:HOOK_RAW + 5] != HOOK_INSTALLED:
        raise RuntimeError(f"the proven Gibson hook is not installed at {HOOK_RAW:X}")
    current = data[CAVE_RAW:CAVE_RAW + CAVE_CAPACITY]
    if current[:len(old)] != old or any(current[len(old):]):
        raise RuntimeError("the 0.7.12 Gibson cave or its trailing free space changed")

    blob, code_size, table_size = make_blob()
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
        "mappings": NAME_MAPPINGS,
    }


if __name__ == "__main__":
    blob, code_size, table_size = make_blob()
    print(f"code={code_size} table={table_size} blob={len(blob)} free={CAVE_CAPACITY-len(blob)}")
