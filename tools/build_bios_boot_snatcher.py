#!/usr/bin/env python3
"""BIOS 부팅화면을 스내처 전용으로 바꾼다 (제자리 · 코드 0 B · 되돌리기 가능).

무엇을 바꾸나
-------------
    타일    $02C000 기준 타일 $80-$DF (96 장)   <- SNATCHER 워드마크 92 장
    리스트  $00297D-$002A81 (261 B)             <- 묶음 경계를 그대로 두고 다시 씀
    팔레트  $02E182 (16 색 x 4 벌 = 128 B)       <- 검은 배경 · 초록 로고 · 흰 글자

왜 이 세 자리뿐인가
-------------------
부팅화면은 **디스플레이 리스트**가 그린다.  BAT 가 아니다.

    FF <팔레트> <x> <y> <타일...>       한 줄
    FF FF                               묶음 구분

지렛대는 원본 리스트 안의 `56 45 52 2E 20 33 2E 30 30` = ASCII **"VER. 3.00"** 이었다.
글자 타일은 **타일 번호 == ASCII 코드**로 배열돼 있어서 문구는 그냥 쓰면 된다.
그걸로 타일 기준이 $02C000 임을 확정했다.

⚠ 묶음 경계를 옮기지 않는다
---------------------------
원본은 묶음이 셋이다 (141 B · 72 B · 44 B).  1·2 번은 로고의 **두 위치**로,
원래 로고가 위아래로 움직이는 연출이었다.  그 뒤로는 "PUSH RUN BUTTON!" 같은
실행 중 메시지가 **같은 표**에 이어진다.  묶음을 몇 번째로 세는 코드가 있을 수
있으므로 **개수도 크기도 그대로 두고** 남는 자리는 공백으로 채운다.

⚠ 타일 자리 한도
----------------
확인된 업로드 범위는 타일 $00-$DF 다 (해태 카드가 $DF 까지 썼고 그 부팅화면이
실제로 돌았다).  $80-$AC 는 원래 "PC Engine"+"SUPER" 로고, $AD-$DF 는 JP 에서
0 인 자리다.  합쳐 96 장.  **$E0 이상은 쓰지 않는다** -- 업로드되는지 미확인.

    python tools/build_bios_boot_snatcher.py --preview out.png     안 쓰고 그림만
    python tools/build_bios_boot_snatcher.py --base --write        기반 BIOS 에
    python tools/build_bios_boot_snatcher.py 0.8.0 --write         구운 판에
"""
from __future__ import annotations

import argparse
import hashlib
import shutil
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "build" / "bios_font" / "Syscard3_galmuri.pce"
LOGO_SRC = ROOT / "build" / "gfx" / "bios_boot" / "snatcher_wordmark.png"

TILE_BASE = 0x02C000
LIST_AT, LIST_END = 0x00297D, 0x002A81          # 끝 포함
GROUPS = (141, 72, 44)                          # 묶음 크기 -- 바꾸지 말 것
PAL_AT, PAL_STEPS = 0x02E182, 4

SLOTS = list(range(0x80, 0xE0))                 # 96 장.  $E0 이상은 미확인이라 안 쓴다
COLS, ROWS = 22, 5                              # 176 x 40 px
LOGO_X, LOGO_Y = (32 - COLS) // 2, 3

# ★ 색 번호와 팔레트.  2026-09-22 실기에서 배운 것:
#   · 리스트 항목의 첫 바이트가 **팔레트**다 (0x00 / 0x10 / 0x20).
#     "PUSH RUN BUTTON!" 은 0x10 이고 실기에서 **밝은 파랑**으로 잘 나왔다.
#   · 글자 타일이 쓰는 색 번호는 **8** 이다.
#   ⚠ $02E182 의 16색 x 4벌은 **부팅 팔레트가 아니었다.**  거기를 갈아도 실기
#     색이 안 바뀌었다 (로고는 올리브, 글자는 파랑 그대로).  진짜 CRAM 출처는
#     아직 못 찾았다 -- 그래서 **팔레트는 건드리지 않는다.**
#   · 그 대신 로고를 **글자와 같은 색 번호 8** 로 그린다.  그러면 실기에서
#     확실히 보이는 색을 그대로 탄다.
# ★★ 2026-09-22 실기 CRAM 덤프(`dump/gfx_20260922_163228_001.cram.bin`)로 확정.
#   관측 셋이 전부 맞아떨어져 모델이 증명됐다:
#       팔레트0 색6 = 090 올리브        <- 첫 판 로고가 이 색이었다
#       팔레트1 색8 = 107 밝은 파랑     <- "PUSH RUN BUTTON!" 이 이 색
#       팔레트2 색8 = 0F0 주황          <- 둘째 판 로고가 이 색이었다
#   즉 리스트 첫 바이트의 윗니블이 **BG 팔레트 번호**이고, 글자 타일은 색 8 이다.
#
#   초록은 **팔레트 2 의 색 5** 다:  1C0 = RGB(0,252,0) 순수 밝은 초록.
#   글자는 팔레트 0 의 색 8 = 16D = RGB(180,180,180).  색 8 이 순백(1FF)인
#   BG 팔레트는 없어서 이것이 가장 흰색에 가깝다 (원본 저작권 줄과 같은 색).
INK = 5                                         # 로고 픽셀이 쓸 색 번호
LOGO_PAL = 0x20                                 # 팔레트 2 -> 색5 = 순수 초록
TEXT_PAL = 0x00                                 # 팔레트 0 -> 색8 = 밝은 회색
TAG_LINE = "CYBER PUNK ADVENTURE"
SUB_LINE = "KOREAN  TRANSLATION"
VER_LINE = "VER. {ver}"

# 새 팔레트 (GRB333).  네 벌을 같게 써서 정지 화면으로 만든다.
#
# ★ 글자 타일이 쓰는 색은 **8 번**이다 ($20-$7F 를 전수로 세서 확인 -- 8 번이 몸통,
#   9 번은 원본에서 검정이라 안 보인다).  원본 애니메이션이 "VER. 3.00" 을
#   파랑->초록으로 바꾸던 것도 8 번을 갈아서였다.
NEW_PAL = {0: 0x000,      # 배경 검정
           6: 0x1C0,      # 로고 밝은 초록
           8: 0x1FF,      # 글자 흰색
           9: 0x000}      # 글자 둘째 색 -- 원본대로 안 보이게


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest().upper()


def encode_tile(cell: list[list[int]]) -> bytes:
    """8x8 인덱스 -> PCE 32 B (플레인 0/1 인터리브 16 B + 플레인 2/3 16 B)."""
    out = bytearray(32)
    for y in range(8):
        p0 = p1 = p2 = p3 = 0
        for x in range(8):
            v = cell[y][x] & 0xF
            bit = 7 - x
            p0 |= (v & 1) << bit
            p1 |= ((v >> 1) & 1) << bit
            p2 |= ((v >> 2) & 1) << bit
            p3 |= ((v >> 3) & 1) << bit
        out[y * 2], out[y * 2 + 1] = p0, p1
        out[16 + y * 2], out[16 + y * 2 + 1] = p2, p3
    return bytes(out)


def decode_tile(rom: bytes, n: int) -> list[list[int]]:
    t = rom[TILE_BASE + n * 32: TILE_BASE + n * 32 + 32]
    if len(t) < 32:
        return [[0] * 8 for _ in range(8)]
    return [[((t[y*2] >> (7-x)) & 1) | (((t[y*2+1] >> (7-x)) & 1) << 1)
             | (((t[16+y*2] >> (7-x)) & 1) << 2) | (((t[16+y*2+1] >> (7-x)) & 1) << 3)
             for x in range(8)] for y in range(8)]


def trace_logo() -> tuple[dict[int, bytes], list[list[int]]]:
    """참고 그림을 COLS x ROWS 칸 1 비트로 줄이고, 같은 무늬는 한 장으로 접는다."""
    from PIL import Image
    if not LOGO_SRC.is_file():
        sys.exit(f"로고 원본이 없다: {LOGO_SRC}")
    im = Image.open(LOGO_SRC).convert("L")
    w, h = im.size
    im = im.crop((0, int(h * 0.17), w, int(h * 0.80)))      # 워드마크만
    im = im.resize((COLS * 8, ROWS * 8), Image.LANCZOS)
    px = im.load()
    bits = [[INK if px[x, y] > 96 else 0 for x in range(COLS * 8)]
            for y in range(ROWS * 8)]

    blobs: dict[bytes, int] = {}
    grid: list[list[int]] = []
    for ty in range(ROWS):
        row = []
        for tx in range(COLS):
            cell = [[bits[ty*8+y][tx*8+x] for x in range(8)] for y in range(8)]
            data = encode_tile(cell)
            if data not in blobs:
                if len(blobs) >= len(SLOTS):
                    sys.exit(f"★ 타일이 자리보다 많다 ({len(blobs)+1} > {len(SLOTS)})")
                blobs[data] = SLOTS[len(blobs)]
            row.append(blobs[data])
        grid.append(row)
    return {n: d for d, n in blobs.items()}, grid


def build_list(grid: list[list[int]], rom: bytes, ver: str) -> bytes:
    """묶음 셋을 **원본과 같은 크기로** 만든다."""
    def entry(a, x, y, tiles):
        return bytes([0xFF, a, x, y]) + bytes(tiles)

    def pad(blob: bytes, size: int) -> bytes:
        """남는 자리는 화면 밖 공백 줄로 채운다 (보이지 않는다).

        ★★ 자투리를 **맨 `FF` 로 메우면 안 된다.**  `FF FF` 가 되어 빈 묶음이
        생기고, 그러면 뒤쪽 메시지 표("PUSH RUN BUTTON!")가 통째로 날아가
        게임 로딩이 시작도 안 된다 (2026-09-22 실기).

        자투리(5 B 미만)는 **마지막 항목의 타일 목록을 늘려** 흡수한다.
        항목은 다음 `FF` 까지가 타일이므로 공백 `$20` 을 덧붙이면 그 줄이
        몇 칸 더 그려질 뿐이고, 채움 항목은 화면 밖(y=31)이라 안 보인다.

        ⚠ 판 이름이 길면(`0.8.3-qtest`) `VER.` 줄이 늘어 여기로 떨어진다 --
          감사의 `부팅화면 묶음` 검사가 이것을 잡아냈다.
        """
        while len(blob) < size:
            room = size - len(blob)
            if room < 5:
                return blob + b"\x20" * room
            blob += entry(0x00, 0, 31, [0x20] * min(room - 4, 24))
        return blob

    # ★★ 2026-09-22 실기: **묶음 0 만 그려진다.**
    #   처음에 저작권을 묶음 1, 부제를 묶음 2 로 옮겼더니 화면에서 통째로 사라졌다.
    #   원본도 저작권 두 줄이 묶음 0 에 있었다 (y=23 · y=25).
    #   묶음 1·2 는 원래 로고가 움직이던 연출 자리인데 이 경로에선 안 돈다.
    #   -> **전부 묶음 0 에 넣고** 1·2 는 빈 묶음으로 둔다 (개수는 셋 그대로).
    keep = []
    d = rom[LIST_AT:LIST_END + 1]
    i = 0
    while i < len(d):
        if d[i] == 0xFF:
            i += 1
            continue
        a, x, y = d[i], d[i+1], d[i+2]
        j = i + 3
        t = []
        while j < len(d) and d[j] != 0xFF:
            t.append(d[j])
            j += 1
        if y in (23, 25):
            keep.append((a, x, y, t))
        i = j

    v = VER_LINE.format(ver=ver)
    body = b"".join([
        entry(TEXT_PAL, (32 - len(TAG_LINE)) // 2, 1, [ord(c) for c in TAG_LINE]),
        *[entry(LOGO_PAL, LOGO_X, LOGO_Y + r, grid[r]) for r in range(ROWS)],
        entry(TEXT_PAL, (32 - len(SUB_LINE)) // 2, 10, [ord(c) for c in SUB_LINE]),
        entry(TEXT_PAL, (32 - len(v)) // 2, 12, [ord(c) for c in v]),
        *[entry(*k) for k in keep],
    ])
    # ★★★ 2026-09-22 실기 2차: 묶음 1·2 를 **빈 묶음으로 두면 안 된다.**
    #   비웠더니 뒤에 있는 "PUSH RUN BUTTON!"(묶음 3)이 통째로 안 나왔다 --
    #   시작 버튼 안내가 없어서 게임을 시작할 수 없다.
    #   묶음이 비면 파서가 `FF FF` 를 **표 끝**으로 읽는 것으로 보인다
    #   (첫 판은 묶음 1·2 에 채움 항목이 있었고 그때는 정상이었다).
    #   -> 둘에 **보이지 않는 항목을 한 개씩** 남긴다 (화면 밖 y=31 의 공백).
    filler = entry(0x00, 0, 31, [0x20])         # 5 B
    room = sum(GROUPS) - 2 * len(filler)
    if len(body) > room:
        sys.exit(f"★ 리스트가 자리보다 크다 ({len(body)} > {room})")
    blob = (pad(body, room) + b"\xFF\xFF" + filler
            + b"\xFF\xFF" + filler)
    assert len(blob) == LIST_END - LIST_AT + 1, (len(blob), LIST_END - LIST_AT + 1)
    return blob


def apply(rom: bytearray, ver: str) -> dict:
    tiles, grid = trace_logo()
    for n, data in tiles.items():
        rom[TILE_BASE + n*32: TILE_BASE + n*32 + 32] = data
    # 안 쓴 슬롯은 비워 둔다 (옛 "PC Engine" 조각이 남지 않게)
    for n in SLOTS:
        if n not in tiles:
            rom[TILE_BASE + n*32: TILE_BASE + n*32 + 32] = b"\x00" * 32
    rom[LIST_AT:LIST_END + 1] = build_list(grid, bytes(rom), ver)
    # ⚠ 팔레트는 **안 건드린다** -- $02E182 를 갈아도 실기 색이 안 바뀌었다.
    #   진짜 CRAM 출처를 찾기 전까지는 원본 그대로 두는 것이 맞다.
    return {"tiles": len(tiles), "slots": len(SLOTS), "grid": grid}


# 실기에서 뜬 CRAM.  미리보기는 **이걸로** 그린다 -- 색 없는 미리보기는
# 미리보기가 아니다 (2026-09-22 에 $02E182 를 부팅 팔레트로 오인해 두 판 날렸다).
LIVE_CRAM = ROOT / "dump" / "gfx_20260922_163228_001.cram.bin"


def preview(rom: bytes, out: Path) -> None:
    from PIL import Image

    def load_pal(n: int) -> list[tuple]:
        if LIVE_CRAM.is_file():
            c = LIVE_CRAM.read_bytes()
            raw = [c[(n*16+i)*2] | (c[(n*16+i)*2+1] << 8) for i in range(16)]
        else:
            raw = [rom[PAL_AT + i*2] | (rom[PAL_AT + i*2 + 1] << 8) for i in range(16)]
        return [(((v >> 3) & 7) * 36, ((v >> 6) & 7) * 36, (v & 7) * 36) for v in raw]

    pals = {n: load_pal(n) for n in range(4)}
    pal = pals[0]
    d = rom[LIST_AT:LIST_END + 1]
    SC = 3
    img = Image.new("RGB", (32*8*SC, 28*8*SC), pal[0])
    px = img.load()
    i = 0
    while i < len(d):
        if d[i] == 0xFF:
            i += 1
            continue
        if i + 3 >= len(d):
            break
        _a, x, y = d[i], d[i+1], d[i+2]
        cur = pals.get((_a >> 4) & 0xF, pal)
        j = i + 3
        tl = []
        while j < len(d) and d[j] != 0xFF:
            tl.append(d[j])
            j += 1
        for k, ti in enumerate(tl):
            cx, cy = x + k, y
            if not (0 <= cx < 32 and 0 <= cy < 28):
                continue
            for ty, row in enumerate(decode_tile(rom, ti)):
                for tx, val in enumerate(row):
                    if val == 0:
                        continue
                    c = cur[val]
                    for dy in range(SC):
                        for dx in range(SC):
                            px[(cx*8+tx)*SC+dx, (cy*8+ty)*SC+dy] = c
        i = j
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("version", nargs="?")
    ap.add_argument("--base", action="store_true")
    ap.add_argument("--ver-text", default=None, help="화면에 찍을 판 번호")
    ap.add_argument("--ink", type=lambda s: int(s, 0), default=None,
                    help="로고 픽셀 색 번호 (기본 8 = 글자와 같은 색)")
    ap.add_argument("--logo-pal", type=lambda s: int(s, 0), default=None,
                    help="로고 줄 팔레트 0x00/0x10/0x20")
    ap.add_argument("--text-pal", type=lambda s: int(s, 0), default=None,
                    help="글자 줄 팔레트 0x00/0x10/0x20")
    ap.add_argument("--preview", type=Path)
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    if args.base or not args.version:
        target = BASE
    else:
        d = ROOT / "build" / "patch" / args.version
        hits = [p for p in d.glob("Syscard3_galmuri_*.pce") if p.suffix == ".pce"]
        if not hits:
            sys.exit(f"BIOS 가 없다: {d}")
        target = hits[0]

    global INK, LOGO_PAL, TEXT_PAL
    if args.ink is not None:
        INK = args.ink
    if args.logo_pal is not None:
        LOGO_PAL = args.logo_pal
    if args.text_pal is not None:
        TEXT_PAL = args.text_pal
    ver = args.ver_text or args.version or "0.8.0"
    rom = bytearray(target.read_bytes())
    info = apply(rom, ver)
    print(f"대상   {target.relative_to(ROOT)}")
    print(f"로고   {COLS}x{ROWS} 칸 · 고유 타일 {info['tiles']} 장 / 자리 {info['slots']} 장")
    print(f"리스트 {LIST_END-LIST_AT+1} B · 묶음 {GROUPS} 그대로")
    print(f"색     로고 ink={INK} pal=0x{LOGO_PAL:02X} · 글자 pal=0x{TEXT_PAL:02X}"
          "  (팔레트 표는 안 건드림)")

    if args.preview:
        preview(bytes(rom), args.preview)
        print(f"미리보기 {args.preview}   ※ **패치된 ROM 에서 되읽어 그린 것**")
    if not args.write:
        print("\n(안 썼다.  --write 로 기록)")
        return
    backup = target.with_suffix(target.suffix + ".before_boot_logo.bak")
    if not backup.exists():
        shutil.copy2(target, backup)
        print(f"원본 보관 {backup.name}")
    target.write_bytes(bytes(rom))
    print(f"새 SHA-256 {sha(bytes(rom))}")


if __name__ == "__main__":
    main()
