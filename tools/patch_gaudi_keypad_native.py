#!/usr/bin/env python3
"""가우디 자판을 **디스크에서 제자리 치환**한다.  훅 0 개 · 런타임 코드 0 바이트.

두 가지를 고친다.

1. **글자 타일** -- 타일 `$200` 부터 129 장(4,128 B)이 한 블록으로 압축돼 있다.
   같은 블록이 디스크에 네 벌 있다.  게임 자기 해독기가 푸는 형식 그대로 다시
   압축해 넣고, **되풀어서** 바이트로 대조한다.

2. **타일맵** -- 압축이 아니라 그대로 들어 있다.  VRAM 증가값이 64 라 스트림은
   **열 단위**다: 열 하나가 행 32~39 의 8 바이트다.  그래서 행 단위로 디스크를
   뒤지면 절대 안 나온다 (2026-09-14 에 여기서 한참 헤맸다).
   45 키 중 셋은 다른 키와 타일 반쪽을 나눠 쓴다 -- 원본에서 `ク/ソ`, `テ/ナ`,
   `フ/マ` 의 반쪽이 실제로 같아서 게임이 합쳐 놓았다.  그 셋만 블록 안의 빈
   타일로 돌린다.  열·행을 알면 바이트 하나씩이다.

   그리는 쪽은 `$6DA0` (뱅크 $69) 의 스트림 해석기다:
       `$FF` 끝 · `$FE`+2 B VRAM 주소 · `$FD`+1 B 속성 · 그 밖엔 타일 하위바이트

⚠ Track 02 는 Mode 1 / 2352 B 섹터다.  논리(사용자영역) 오프셋을 물리로 옮기고
  건드린 섹터마다 EDC/ECC 를 다시 계산한다.

    python tools/patch_gaudi_keypad_native.py 0.7.12            보고만
    python tools/patch_gaudi_keypad_native.py 0.7.12 --write
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "extraction" / "patch" / "static")]

import gfx_block_codec as codec                                # noqa: E402
from build_disc_subtitle_hook import rebuild_mode1_sector      # noqa: E402

TRACK02 = "Snatcher CD-ROMantic (Japan) (Track 02) [KO].bin"
PAYLOAD = ROOT / "build" / "gfx" / "gaudi_keypad" / "gaudi_keypad_hangul_8x16_poc_vram.bin"
TILES = ROOT / "build" / "gfx" / "gaudi_keypad" / "gaudi_keypad_hangul_8x16_poc_tiles.tsv"
CAPTURE = ROOT / "dump" / "gaudi_keypad_vram_v010.bin"
RAW, USER, HDR = 2352, 2048, 16
BAT_W = 64
TILE_FIRST, TILE_COUNT = 0x200, 129          # 블록이 싣는 타일 범위
MAP_ROW_LO, MAP_ROW_HI = 32, 40              # 타일맵 열 하나가 담는 행
MAP_COL_LO, MAP_COL_HI = 2, 30               # 디스크와 일치가 실측된 열 (0·1·31 은 안 맞는다)
COPIES = 4                                   # 타일 블록·타일맵 모두 네 벌이다


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def logical_of(data: bytes) -> bytes:
    out = bytearray()
    for base in range(0, len(data) - RAW + 1, RAW):
        out += data[base + HDR:base + HDR + USER]
    return bytes(out)


def read_logical(data: bytes, logical: int, n: int) -> bytes:
    out = bytearray()
    while n:
        sec, off = divmod(logical, USER)
        take = min(n, USER - off)
        base = sec * RAW + HDR + off
        out += data[base:base + take]
        logical += take
        n -= take
    return bytes(out)


def write_logical(data: bytearray, logical: int, payload: bytes) -> set[int]:
    touched: set[int] = set()
    pos = 0
    while pos < len(payload):
        sec, off = divmod(logical + pos, USER)
        take = min(len(payload) - pos, USER - off)
        base = sec * RAW + HDR + off
        data[base:base + take] = payload[pos:pos + take]
        touched.add(sec)
        pos += take
    return touched


def find_all(image: bytes, blob: bytes) -> list[int]:
    out, at = [], 0
    while True:
        i = image.find(blob, at)
        if i < 0:
            return out
        out.append(i)
        at = i + 1


def column_bytes(vram: bytes, col: int) -> bytes:
    """타일맵 한 열 = 행 32..39 의 타일 하위바이트 8 개."""
    return bytes(vram[((row * BAT_W + col) * 2)] for row in range(MAP_ROW_LO, MAP_ROW_HI))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("version")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--no-backup", action="store_true",
                    help="do not leave an in-folder backup (for staged build scripts)")
    ap.add_argument(
        "--source-vram", type=Path, default=CAPTURE,
        help="VRAM image already represented by the source Track 02 (default: stock capture)",
    )
    args = ap.parse_args()

    folder = ROOT / "build" / "patch" / args.version
    track = folder / TRACK02
    if not track.is_file():
        sys.exit(f"Track 02 가 없다: {track}")
    source_vram = args.source_vram.read_bytes()
    payload = PAYLOAD.read_bytes()
    if len(source_vram) != 0x10000 or len(payload) != 0x10000:
        sys.exit("64 KB source-vram/페이로드가 아니다")

    original_track = track.read_bytes()
    data = bytearray(original_track)
    image = logical_of(bytes(data))
    print(f"판 {args.version} · Track 02 {len(data):,} B · 논리 {len(image):,} B")

    # --- 1. 글자 타일 블록 --------------------------------------------------
    first, size = TILE_FIRST * 32, TILE_COUNT * 32
    old_block, new_block = source_vram[first:first + size], payload[first:first + size]
    if old_block == new_block:
        sys.exit("타일 블록에 바뀐 것이 없다 -- 먼저 build_gaudi_keypad_bg_8x16_poc.py 를 돌릴 것")

    # 압축된 원본을 찾아 자리(room)를 잰다.  블록마다 헤더 1 B 가 앞에 붙는다.
    # 자리를 추측하지 않는다 -- 게임 해독기로 풀어서 캡처와 맞는 스트림만 고른다.
    import gfx_locate_blocks as loc                                    # noqa: E402
    hits = loc.find_at(image, source_vram, TILE_FIRST)
    if len(hits) < 1:
        sys.exit("타일 블록을 디스크에서 못 찾았다")
    room = hits[0][1] - hits[0][3]          # 압축 스트림 길이 (헤더 제외)
    block_sites = [s + hits[0][3] for s in find_all(image, image[hits[0][0]:hits[0][0] + hits[0][1]])]
    encoded = codec.encode(new_block)
    check, _ = codec.decompress(encoded, 0, max_out=0x10000, max_in=16384)
    if bytes(check) != new_block:
        sys.exit("우리 인코더가 되풀리지 않는다")
    print(f"  타일 블록  사본 {len(block_sites)} 벌 · 자리 {room} B · 새 압축 {len(encoded)} B "
          f"(여유 {room - len(encoded):+d})")
    if len(encoded) > room:
        sys.exit("새 블록이 자리보다 크다 -- 글자를 줄이거나 다른 자리를 찾아야 한다")
    if len(block_sites) != COPIES:
        print(f"  ⚠ 사본이 {len(block_sites)} 벌이다 (예상 {COPIES})")

    # --- 2. 타일맵 ----------------------------------------------------------
    rows = list(csv.DictReader(TILES.open(encoding="utf-8"), delimiter="\t"))
    labels = {(int(r["bat_row"]), int(r["column"]), int(r["target_pattern"], 16) & 0xFF):
              (r["syllable"], r["half"]) for r in rows}
    moved = []
    for row in range(MAP_ROW_LO, MAP_ROW_HI):
        for col in range(MAP_COL_LO, MAP_COL_HI + 1):
            at = (row * BAT_W + col) * 2
            old, new = source_vram[at], payload[at]
            if old != new:
                syllable, half = labels.get((row, col, new), ("(unknown)", "?"))
                moved.append((syllable, half, row, col, old, new))

    signature = column_bytes(source_vram, 4)
    map_sites = [i - 4 * 8 for i in find_all(image, signature)]
    good = []
    for origin in map_sites:
        if all(column_bytes(source_vram, c) == image[origin + c * 8:origin + c * 8 + 8]
               for c in range(MAP_COL_LO, MAP_COL_HI + 1)):
            good.append(origin)
    print(f"  타일맵     사본 {len(good)} 벌 (열 {MAP_COL_LO}~{MAP_COL_HI} 전부 일치)")
    if not good:
        sys.exit("타일맵을 디스크에서 못 찾았다")
    if len(good) != COPIES:
        print(f"  ⚠ 사본이 {len(good)} 벌이다 (예상 {COPIES})")

    edits = []
    for syllable, half, row, col, old, new in moved:
        if not (MAP_ROW_LO <= row < MAP_ROW_HI and MAP_COL_LO <= col <= MAP_COL_HI):
            sys.exit(f"옮긴 칸 ({row},{col}) 이 타일맵 범위 밖이다")
        edits.append((syllable, half, row, col, old, new))
        print(f"    {syllable} {half:6s} 칸({row},{col})  ${old:02X} -> ${new:02X}")

    if not args.write:
        print("\n보고만 했다.  실제로 쓰려면 --write")
        return

    # --- 3. 쓰기 ------------------------------------------------------------
    backup = track.with_suffix(track.suffix + ".bak_gaudi_keypad")
    if not args.no_backup and not backup.exists():
        shutil.copy2(track, backup)
        print(f"\n  원본 보관 {backup.name}")
    touched: set[int] = set()
    for site in block_sites:
        touched |= write_logical(data, site, encoded)
    for origin in good:
        for _, _, row, col, old, new in edits:
            at = origin + col * 8 + (row - MAP_ROW_LO)
            if read_logical(bytes(data), at, 1)[0] != old:
                sys.exit(f"타일맵 ${at:07X} 의 현재 값이 ${old:02X} 가 아니다 -- 멈춘다")
            touched |= write_logical(data, at, bytes([new]))
    for sec in sorted(touched):
        blk = bytearray(data[sec * RAW:(sec + 1) * RAW])
        rebuild_mode1_sector(blk)
        data[sec * RAW:(sec + 1) * RAW] = blk
    track.write_bytes(bytes(data))
    print(f"  섹터 {len(touched)} 개를 다시 구웠다")

    # --- 4. 되읽어 검산 ------------------------------------------------------
    final = track.read_bytes()
    fimage = logical_of(final)
    for site in block_sites:
        blob = read_logical(final, site, room)
        got, _ = codec.decompress(blob, 0, max_out=0x10000, max_in=16384)
        if bytes(got) != new_block:
            sys.exit(f"검산 실패: ${site:07X} 가 새 블록으로 안 풀린다")
    for origin in good:
        for _, _, row, col, _, new in edits:
            at = origin + col * 8 + (row - MAP_ROW_LO)
            if read_logical(final, at, 1)[0] != new:
                sys.exit(f"검산 실패: 타일맵 ${at:07X}")
    # 자판 밖은 한 바이트도 안 바뀌어야 한다
    before = logical_of(original_track)
    diff = [i for i in range(len(before)) if before[i] != fimage[i]]
    ranges = [(s, s + room) for s in block_sites] + \
             [(origin + col * 8 + (row - MAP_ROW_LO),) * 1 + (origin + col * 8 + (row - MAP_ROW_LO) + 1,)
              for origin in good for _, _, row, col, _, _ in edits]
    stray = [i for i in diff if not any(lo <= i < hi for lo, hi in ranges)]
    print(f"  논리 이미지 변경 {len(diff):,} B · 허용 범위 밖 {len(stray)}")
    if stray:
        sys.exit("자판 밖이 바뀌었다 -- 되돌릴 것")
    print(f"\n  Track 02 SHA-256  {sha(final)}")
    print("  통과: 타일 블록은 게임 해독기로 되풀어 대조 · 타일맵은 바이트 대조")


if __name__ == "__main__":
    main()
