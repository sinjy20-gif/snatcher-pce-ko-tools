#!/usr/bin/env python3
"""자막 훅을 디스크에 박는다 -- Track 02 섹터 251 의 스프라이트 오버레이.

무엇을 하나
-----------
게임의 SATB 조립 시작 `$601E` 를 우리 스텁 호출로 바꾼다.

    $601E   A9 3F 85 17          LDA #$3F / STA $17
        ->  20 <lo> <hi> EA      JSR <스텁> / NOP

스텁은 밀려난 원본(`LDA #$3F / STA $17`)을 **먼저** 하고, 우리 자막 스프라이트를
게임보다 앞서 민다.  슬롯 0 부터 차지하므로 그림·초상화보다 앞에 그려진다.
MAWR 은 `$6008` 에서 슬롯 0 에 서 있고, 우리 푸시가 `$17` 을 깎으므로
`$60A6` 의 0 채우기도 저절로 맞는다.  **VDC 접근 0 회.**

왜 디스크에 박나
----------------
지금은 Lua 가 매 프레임 무장/회수를 한다.  오버레이가 갈릴 때 패치가 남으면
남의 코드가 우리 스텁으로 뛰어들기 때문이다 (2026-08-23 UI 복구 실패의 원인).

**디스크에 박으면 훅이 오버레이 데이터의 일부**가 된다.  섹터 251 이 로드될
때마다 훅이 같이 오고, 다른 오버레이에는 애초에 없다.  잔류 문제가 사라진다.

스텁 자리
---------
`--stub-addr` 로 준다.  두 가지 경우가 있다.

  오버레이 안 (`--stub-in-overlay`)
      훅과 스텁이 같이 로드되고 같이 덮인다.  가장 안전하다.
      단 **런타임에 죽어 있는 자리여야 한다.**
      $7CD2-$7FFF 는 디스크에서 FF 이고 정적 참조도 0 이었지만,
      PROBE_OVERLAY_TAIL 0.1.0 이 19200 프레임을 돌려 뒤집었다 --
      $EA9E 의 루틴이 런타임에 정확히 814 B 를 그 자리에 채운다.
      ★ 디스크의 FF 는 빈 공간이 아니다.  PROBE_OVERLAY_HOLE 로 증명한 뒤에 쓸 것.

  빌린 RAM ($5B80-$5E3F, 스텁 기본 $5C20)
      펌웨어가 AC 에서 올린다.  이미 증명된 자리다.
      단 **펌웨어가 아직 안 올라온 상태에서 오버레이 A 가 로드되면**
      `JSR $5C20` 이 게임 데이터를 실행한다.  그 창을 어떻게 막을지 정해야 한다.

원본은 절대 건드리지 않는다.  결과는 build/patch/subtitle_hook/ 아래에 쓴다.

사용
----
    python build_disc_subtitle_hook.py --check
        패치 없이 대상 바이트만 확인한다 (원본이 예상과 같은가)

    python build_disc_subtitle_hook.py --stub-addr 0x7CD2 --stub-in-overlay
        스텁을 오버레이 안에 넣고 훅을 박는다

    python build_disc_subtitle_hook.py --stub-addr 0x5C20
        훅만 박는다 (스텁은 펌웨어가 RAM 에 올린다)
"""
from __future__ import annotations

import argparse
import hashlib
import shutil
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DISC = ROOT / "rom(japan)" / "Snatcher CD-ROMantic (Japan)"
SOURCE_TRACK = DISC / "Snatcher CD-ROMantic (Japan) (Track 02).bin"
SOURCE_CUE = DISC / "Snatcher CD-ROMantic (Japan).cue"
OUT_DIR = ROOT / "build" / "patch" / "subtitle_hook"

RAW_SECTOR = 2352
USER_SIZE = 2048
USER_OFFSET = 16          # Mode 1: 12 B 동기 + 4 B 헤더

OVERLAY_SECTOR = 251      # $6000 을 담은 사용자 데이터 섹터 (disasm_huc6280 --bank A)
CPU_BASE = 0x6000
HOOK_CPU = 0x601E
HOOK_OLD = bytes((0xA9, 0x3F, 0x85, 0x17))       # LDA #$3F / STA $17

# 오버레이 지문.  패치 전에 이것들이 다 맞아야 한다.
SIGNATURE = [
    (0x6000, bytes((0x20, 0x6E, 0x47))),          # JSR $476E
    (0x601E, HOOK_OLD),                            # LDA #$3F / STA $17
    (0x6463, bytes((0xC2,))),                      # CLY  엔트리 파서 머리
    (0x6500, bytes((0x82, 0xB5, 0x00))),           # CLX / LDA $00,X  푸시 루프
    (0x60A6, bytes((0xA6, 0x17))),                 # LDX $17  0 채우기 머리
    (0x6072, bytes((0x4C, 0xBE, 0x43))),           # JMP $43BE  조립 끝
]

# ---------------------------------------------------------------- EDC / ECC
def _tables() -> tuple[list[int], list[int], list[int]]:
    edc: list[int] = []
    f = [0] * 256
    b = [0] * 256
    for value in range(256):
        shifted = ((value << 1) ^ (0x11D if value & 0x80 else 0)) & 0xFF
        f[value] = shifted
        b[value ^ shifted] = value
    for value in range(256):
        current = value
        for _ in range(8):
            current = (current >> 1) ^ (0xD8018001 if current & 1 else 0)
        edc.append(current & 0xFFFFFFFF)
    return edc, f, b


EDC_LUT, ECC_F, ECC_B = _tables()


def compute_edc(data: bytes | bytearray) -> int:
    result = 0
    for value in data:
        result = (result >> 8) ^ EDC_LUT[(result ^ value) & 0xFF]
    return result


def compute_ecc(source, major_count: int, minor_count: int,
                major_mult: int, minor_inc: int) -> bytes:
    size = major_count * minor_count
    out = bytearray(major_count * 2)
    for major in range(major_count):
        index = (major >> 1) * major_mult + (major & 1)
        a = b = 0
        for _ in range(minor_count):
            value = source[index]
            index += minor_inc
            if index >= size:
                index -= size
            a ^= value
            b ^= value
            a = ECC_F[a]
        a = ECC_B[ECC_F[a] ^ b]
        out[major] = a
        out[major + major_count] = a ^ b
    return bytes(out)


def rebuild_mode1_sector(sector: bytearray) -> None:
    """사용자 데이터를 고친 뒤 EDC/ECC 를 다시 계산한다."""
    if len(sector) != RAW_SECTOR or sector[15] != 1:
        raise RuntimeError("Mode-1/2352 섹터가 아니다")
    sector[0x810:0x814] = compute_edc(sector[:0x810]).to_bytes(4, "little")
    sector[0x814:0x81C] = bytes(8)
    p_parity = compute_ecc(sector[0x0C:0x81C], 86, 24, 2, 86)
    sector[0x81C:0x8C8] = p_parity
    sector[0x8C8:0x930] = compute_ecc(sector[0x0C:0x81C] + p_parity, 52, 43, 86, 88)


# ---------------------------------------------------------------- 스텁
def build_stub(list_addr: int, text_y: int, center_x: int, count: int) -> bytes:
    """게임보다 먼저 미는 스텁.  PROBE_SUB_LIVE 가 쓰는 것과 같은 코드다."""
    y = text_y + 64
    x = center_x + 32
    return bytes((
        0x08, 0x78,                                   # PHP / SEI
        0xA9, 0x3F, 0x85, 0x17,                       # 밀려난 원본을 먼저
        0xAD, 0x00, 0x65, 0xC9, 0x82,                 # LDA $6500 / CMP #$82  오버레이 확인
        0xD0, 0x27,                                   # BNE exit
        0xA9, y & 0xFF, 0x85, 0x08,
        0xA9, (y >> 8) & 0xFF, 0x85, 0x09,
        0xA9, x & 0xFF, 0x85, 0x0A,
        0xA9, (x >> 8) & 0xFF, 0x85, 0x0B,
        0x64, 0x0C, 0x64, 0x0D, 0x64, 0x0E, 0x64, 0x0F,
        0xA9, list_addr & 0xFF, 0x85, 0x10,
        0xA9, (list_addr >> 8) & 0xFF, 0x85, 0x11,
        0xA9, count, 0x85, 0x16,
        0x20, 0x63, 0x64,                             # JSR $6463  게임 손을 빌린다
        0x28, 0x60,                                   # PLP / RTS
    ))


# ---------------------------------------------------------------- 디스크
@dataclass(frozen=True)
class Edit:
    label: str
    cpu: int
    old: bytes | None
    new: bytes


def user_slice(track: bytes, sector: int) -> bytes:
    base = sector * RAW_SECTOR + USER_OFFSET
    return track[base:base + USER_SIZE]


def read_cpu(track: bytes, cpu: int, length: int) -> bytes:
    off = cpu - CPU_BASE
    if not (0 <= off and off + length <= USER_SIZE * 4):
        raise RuntimeError(f"${cpu:04X} 가 오버레이 범위 밖이다")
    sector, within = divmod(off, USER_SIZE)
    data = user_slice(track, OVERLAY_SECTOR + sector)
    if within + length <= USER_SIZE:
        return data[within:within + length]
    tail = USER_SIZE - within
    return data[within:] + user_slice(track, OVERLAY_SECTOR + sector + 1)[:length - tail]


def apply(track: bytearray, edit: Edit) -> set[int]:
    off = edit.cpu - CPU_BASE
    touched: set[int] = set()
    for i, value in enumerate(edit.new):
        sector, within = divmod(off + i, USER_SIZE)
        absolute = OVERLAY_SECTOR + sector
        track[absolute * RAW_SECTOR + USER_OFFSET + within] = value
        touched.add(absolute)
    return touched


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="패치 없이 대상 바이트만 확인")
    # 자막용으로 빌드가 예약한 구간의 시작 ($5C40-$5E1F · 480 B · MPR2).
    # manifest.json 의 subtitle_ram_code 와 같아야 한다.
    # ★ $5C40 은 스크립트 VM 데이터 스택 안이다 (실측 최고 $5DEF).
    # 기본값을 두지 않는다 -- 새 자리가 정해지면 그것을 명시해서 준다.
    ap.add_argument("--stub-addr", type=lambda v: int(v, 0), required=True,
                    help="스텁 주소.  $5C40-$5E1F 는 스택이라 쓸 수 없다")
    ap.add_argument("--stub-in-overlay", action="store_true",
                    help="스텁을 오버레이 안에도 써 넣는다 (그 자리가 죽어 있다는 증명이 있어야 한다)")
    ap.add_argument("--list-addr", type=lambda v: int(v, 0), default=0x5C80)
    ap.add_argument("--text-y", type=int, default=122)
    ap.add_argument("--center-x", type=int, default=128)
    ap.add_argument("--count", type=int, default=1, help="스텁이 미는 엔트리 수")
    args = ap.parse_args()

    if not SOURCE_TRACK.exists():
        raise SystemExit(f"원본이 없다: {SOURCE_TRACK}")
    track = bytearray(SOURCE_TRACK.read_bytes())
    print(f"원본 {SOURCE_TRACK.name}  {len(track)/1e6:.1f} MB  "
          f"{len(track)//RAW_SECTOR} 섹터")

    print("\n오버레이 지문")
    bad = 0
    for cpu, want in SIGNATURE:
        got = read_cpu(track, cpu, len(want))
        ok = got == want
        if not ok:
            bad += 1
        print(f"  ${cpu:04X}  {want.hex(' ').upper():<12} {'일치' if ok else 'X  실제 ' + got.hex(' ').upper()}")
    if bad:
        raise SystemExit(f"★ 지문 {bad} 개가 안 맞는다 -- 원본이 예상과 다르다")

    stub = build_stub(args.list_addr, args.text_y, args.center_x, args.count)
    print(f"\n스텁 {len(stub)} B  ->  ${args.stub_addr:04X}"
          f"  ({'오버레이 안' if args.stub_in_overlay else '빌린 RAM · 펌웨어가 올린다'})")
    print(f"  자막 자리 y={args.text_y} · 가운데 x={args.center_x} · 엔트리 {args.count}")

    edits = [Edit("훅", HOOK_CPU, HOOK_OLD,
                  bytes((0x20, args.stub_addr & 0xFF, args.stub_addr >> 8, 0xEA)))]
    if args.stub_in_overlay:
        if not (CPU_BASE <= args.stub_addr and args.stub_addr + len(stub) <= 0x8000):
            raise SystemExit("스텁 주소가 오버레이 범위 밖이다")
        current = read_cpu(track, args.stub_addr, len(stub))
        print(f"  그 자리 현재: {current[:8].hex(' ').upper()} ...  "
              f"(FF 아닌 바이트 {sum(1 for b in current if b != 0xFF)}/{len(stub)})")
        edits.append(Edit("스텁", args.stub_addr, None, stub))

    print("\n고칠 곳")
    for e in edits:
        got = read_cpu(track, e.cpu, len(e.new))
        if e.old is not None and got != e.old:
            raise SystemExit(f"★ ${e.cpu:04X} 의 원본이 예상과 다르다: {got.hex(' ').upper()}")
        print(f"  {e.label:4s} ${e.cpu:04X}  {got.hex(' ').upper()[:23]:<23} -> {e.new.hex(' ').upper()[:23]}")

    if 0x5B80 <= args.stub_addr <= 0x5E3F:
        raise SystemExit(
            f"★ ${args.stub_addr:04X} 는 스크립트 VM 데이터 스택 안이다 ($5B80-$5E3F).\n"
            "  실측 최고 깊이 $5DEF (probe_arena_0_1_3.tsv).  다른 자리를 쓸 것.")

    if args.check:
        print("\n--check 이므로 여기서 끝.  아무것도 안 썼다.")
        return

    touched: set[int] = set()
    for e in edits:
        touched |= apply(track, e)
    for sector in sorted(touched):
        raw = bytearray(track[sector * RAW_SECTOR:(sector + 1) * RAW_SECTOR])
        rebuild_mode1_sector(raw)
        track[sector * RAW_SECTOR:(sector + 1) * RAW_SECTOR] = raw
    print(f"\n섹터 {sorted(touched)} 의 EDC/ECC 재계산 완료")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out_track = OUT_DIR / SOURCE_TRACK.name
    out_track.write_bytes(bytes(track))
    out_cue = OUT_DIR / SOURCE_CUE.name
    shutil.copy2(SOURCE_CUE, out_cue)
    for other in DISC.glob("*.bin"):
        if other.name == SOURCE_TRACK.name:
            continue
        link = OUT_DIR / other.name
        if not link.exists():
            try:
                link.hardlink_to(other)
            except OSError:
                shutil.copy2(other, link)

    print(f"\n{out_track}")
    print(f"  sha256 {hashlib.sha256(bytes(track)).hexdigest()[:32]}")
    print(f"{out_cue}")
    print(f"  나머지 트랙은 원본을 하드링크했다 (용량 안 늘어남)")
    print(f"\n★ 원본은 건드리지 않았다: {SOURCE_TRACK}")


if __name__ == "__main__":
    main()
