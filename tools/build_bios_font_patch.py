#!/usr/bin/env python3
"""갈무리 한글을 시스템 카드 12x12 글리프 자리에 얹는다.

무엇을 만드나
-------------
`hangul_slot_map.tsv` 가 정한 자리(JIS 행/셀 -> ROM 오프셋)에 갈무리 글리프를 써넣은
BIOS 를 만든다.  런타임 코드 0 바이트 · AC 0 바이트 -- 글리프의 출처만 바뀐다.

    입력   Galmuri11.bdf
           build\bios_font\hangul_slot_map.tsv
           [BIOS] ....pce.JP_ORIGINAL          <- 일본 원본에 얹는다
    출력   build\bios_font\Syscard3_galmuri.pce

일본 원본에 얹는 이유
---------------------
행 오프셋 표가 일본 카드와 한글 카드에서 **완전히 동일**하다 (실측).  그래서 어느
쪽에 얹어도 같은 자리가 나오는데, 일본 원본을 쓰면 **해태 한글 카드가 필요 없어진다.**
그리고 배정표가 게임이 안 쓰는 칸만 골랐으므로 **한자가 죽지 않는다** -- 미번역
일본어도 멀쩡히 나온다.

글리프 형식 (실측)
------------------
    base   $030000
    stride 18 B      12 행 x 12 비트, 3 바이트에 2 행 (big-endian 연속 비트열)
    확인   BIOS $F2CC 언팩 루프가 CPY #$12 로 18 바이트를 읽는다
           프로브 두 표본이 base $030000 으로 정확히 일치

    python build_bios_font_patch.py --preview 가나다한글
    python build_bios_font_patch.py --write
"""
from __future__ import annotations
import argparse, csv, sys
from pathlib import Path

ROOT = Path(r"C:\snatcher")
sys.path.insert(0, str(ROOT / "extraction" / "patch" / "static"))
from build_disc_patch import parse_bdf, glyph_1bpp_left_shifted   # noqa: E402

BDF = ROOT / "extraction" / "font_research" / "Galmuri11.bdf"
MAP = ROOT / "build" / "bios_font" / "hangul_slot_map.tsv"
SRC = ROOT / "Mesen_2.2.1_Windows" / "Firmware" / "[BIOS] Super CD-ROM System (Japan) (v3.0).pce.JP_ORIGINAL"
OUT = ROOT / "build" / "bios_font" / "Syscard3_galmuri.pce"
HAITAI = SRC.with_suffix(".KR_HAITAI")

# 해태 카드에서 가져올 구간.  build_bios_boot_logo.py 의 REGIONS 와 같은 목록이고,
# 그쪽이 2026-08-18 에 JP/해태 전수 비교로 뽑았다.  **글리프는 하나도 없다.**
LOGO_REGIONS = [
    (0x00297D, 0x002A81, "tables", "작은 인덱스 표"),
    (0x0070F1, 0x007184, "menu",   "BIOS 메뉴 문자열 (DELETE/FORMAT)"),
    (0x007219, 0x007267, "menu",   "BIOS 메뉴 문자열 (SELECTION)"),
    (0x0074DA, 0x0074DD, "menu",   "값 하나"),
    (0x02C020, 0x02C3FC, "gfx",    "타일 데이터"),
    (0x02C751, 0x02C77F, "gfx",    "타일 데이터"),
    (0x02CB71, 0x02DBEF, "gfx",    "타일 데이터 (부팅화면 본체)"),
]
# 두 격자를 다 지원한다.
#
#   16x16  일본 원본 BIOS 가 타는 경로 ($F1BA, 32B 를 그대로 복사).  글리프가 셀을
#          꽉 채운다.  출하 중인 glyph_1bpp_left_shifted 가 그대로 32B 를 만든다
#   12x12  해태 한글 카드가 쓰는 경로 ($F2CC, 18B 를 24B 로 언팩).  가로 16칸 중
#          12칸, 세로 16행 중 12행만 차서 헐거워 보인다
#
# 해태가 12x12 로 줄인 것은 한글 2,350자를 ROM 에 넣기 위한 제약이었다.  우리는
# 게임이 안 쓰는 칸에만 713자를 넣으므로 그 제약이 없다 -> 16x16 을 쓴다.
W = H = 12          # 12x12 렌더 캔버스 (16x16 은 출하 렌더러가 32B 를 직접 만든다)
GRIDS = {
    "16x16": {"stride": 32, "base": None},   # base 는 프로브로 확정한 뒤 채운다
    "12x12": {"stride": 18, "base": 0x030000},
}

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def load_map():
    rows = list(csv.reader(open(MAP, encoding="utf-8-sig", newline=""), delimiter="\t"))
    ix = {n: k for k, n in enumerate(rows[0])}
    # rom_offset 은 배정표를 만든 격자 기준이라 그대로 못 쓴다.  index 를 들고 와서
    # 현재 격자의 base/stride 로 다시 계산한다.
    return {r[ix["hangul"]]: int(r[ix["index"]]) for r in rows[1:] if len(r) > ix["index"]}


def render(bbx, bitmap):
    """BDF 한 글자 -> 12x12 비트맵.

    갈무리 11 은 높이 11 px 이고 BBX 의 y 오프셋은 베이스라인 기준이다.  16x16 판이
    쓰던 고정 베이스라인(13 - height - yoff)을 12 칸으로 옮기면 11 - height - yoff 다.
    글자마다 따로 가운데 맞추면 '보' 처럼 낮은 글자가 한 줄 내려앉는다.
    """
    width, height, xoff, yoff = bbx
    canvas = [[0] * W for _ in range(H)]
    # 기준선 12 (= 12 - height - yoff).  11 로 두면 우리 글자만 한 픽셀 위에
    # 앉는다 -- 2026-08-19 실측: BIOS 자신의 글자는 바닥이 11 행이다
    #   영문 26/26 · 한자 200/200 · 가나 44/46 이 바닥 11
    #   우리 갈무리는 739/782 가 바닥 10 이었다 (소유자가 화면에서 먼저 발견)
    y0 = max(0, 12 - height - yoff)
    x0 = max(0, xoff)
    for ry, row_hex in enumerate(bitmap):
        y = y0 + ry
        if not (0 <= y < H):
            continue
        value = int(row_hex, 16)
        bits = len(row_hex) * 4
        for rx in range(width):
            if value >> (bits - 1 - rx) & 1:
                x = x0 + rx
                if 0 <= x < W:
                    canvas[y][x] = 1
    return canvas


# 손으로 그리는 글자.  갈무리의 '…' 는 yoff 5 라 가운데에 뜬다 (일본식).
# 예전 F042 의 설계를 12x12 로 옮긴 것이다 -- 2x2 점 셋, 바닥 한 줄 위, 왼쪽 치우침.
# BIOS 마침표 ．(8144) 가 9~10 행에 앉으므로 같은 높이를 쓴다.
CUSTOM_CANVAS = {
    "…": [[1 if (r in (9, 10) and c in (1, 2, 5, 6, 9, 10)) else 0
           for c in range(12)] for r in range(12)],
}


def pack(canvas, stride=18):
    """12 행 x 12 비트를 연속 비트열로 -> 18 바이트."""
    v = 0
    for row in canvas:
        for bit in row:
            v = (v << 1) | bit
    return v.to_bytes(stride, "big")


def show(canvas):
    return "\n".join("    " + "".join("██" if c else "··" for c in row) for row in canvas)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", default="")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--grid", choices=("16x16", "12x12"), default="16x16")
    ap.add_argument("--base", help="글리프 테이블 ROM 기점 (hex).  16x16 은 필수")
    ap.add_argument("--haitai-logo", dest="haitai_logo", action="store_true",
                    default=True, help="해태 부팅화면을 같이 얹는다 (기본 켜짐)")
    ap.add_argument("--no-haitai-logo", dest="haitai_logo", action="store_false",
                    help="배포용.  해태 그래픽을 빼고 일본 원본 부팅화면으로 둔다")
    args = ap.parse_args()

    grid = GRIDS[args.grid]
    stride = grid["stride"]
    base = int(args.base, 16) if args.base else grid["base"]
    if base is None:
        print(f"{args.grid} 의 base 가 아직 확정되지 않았다.  --base 로 넘길 것.")
        print("  구하는 법: 일본 BIOS 로 PROBE_FONT_ADDR_0.1.3 을 돌리고")
        print("             base = 뱅크*0x2000 + (src - $A000) - 인덱스*%d" % stride)
        return
    print(f"격자 {args.grid} · stride {stride} B · base ${base:06X}")
    slots = load_map()
    chars = args.preview or "".join(sorted(slots))
    glyphs = parse_bdf(BDF, {ord(c) for c in set(chars) | set(slots)})
    print(f"배정 {len(slots):,}자 · BDF 에서 찾은 글리프 {len(glyphs):,}자")

    missing = [c for c in slots if ord(c) not in glyphs]
    if missing:
        print(f"★ BDF 에 없는 글자 {len(missing)}: {''.join(missing[:20])}")

    if args.preview:
        for ch in args.preview:
            if ord(ch) not in glyphs:
                print(f"  '{ch}' -- BDF 에 없다")
                continue
            bbx, bitmap = glyphs[ord(ch)]
            print(f"\n  '{ch}'  BBX {bbx}  ->  ROM ${slots.get(ch, 0):06X}")
            print(show(render(bbx, bitmap)))
        return

    rom = bytearray(SRC.read_bytes())
    written = 0
    for ch, idx in slots.items():
        if ord(ch) not in glyphs and ch not in CUSTOM_CANVAS:
            continue
        if ch in CUSTOM_CANVAS:
            rom[base + idx * stride:base + (idx + 1) * stride] = pack(CUSTOM_CANVAS[ch], stride)
            written += 1
            continue
        bbx, bitmap = glyphs[ord(ch)]
        data = (glyph_1bpp_left_shifted(bbx, bitmap) if args.grid == "16x16"
                else pack(render(bbx, bitmap), stride))
        off = base + idx * stride
        rom[off:off + stride] = data
        written += 1
    print(f"써넣은 글리프 {written:,} / {len(slots):,}")
    changed = sum(1 for a, b in zip(SRC.read_bytes(), rom) if a != b)
    print(f"바뀐 바이트 {changed:,} ({changed/len(rom):.2%})")

    # 해태 카드의 부팅화면을 같이 얹는다 (소유자 지시 2026-08-20, 개인 사용).
    #
    # **폰트 테이블은 건드리지 않는다.**  글리프 구간을 옮기면 방금 써넣은 배정표와
    # 어긋나 화면에 한자가 나온다.  아래 구간에는 글리프가 하나도 없다 --
    # build_bios_boot_logo.py 의 REGIONS 를 그대로 가져온 것이고, 그쪽이
    # 2026-08-18 에 JP/해태 전수 비교로 뽑아 둔 목록이다.
    #
    # 배포용으로 만들 때는 --no-haitai-logo 로 끈다: 이 5,751 B 는 해태 카드에서
    # 그대로 복사한 남의 저작물이라 재배포에 못 넣는다 (인계서 §8).
    if args.haitai_logo:
        if not HAITAI.exists():
            print(f"\n해태 카드가 없어 부팅화면은 건너뛴다: {HAITAI}")
        else:
            kr = HAITAI.read_bytes()
            moved = 0
            for start, end, group, note in LOGO_REGIONS:
                rom[start:end + 1] = kr[start:end + 1]
                moved += end - start + 1
            print(f"해태 부팅화면 {moved:,} B 얹음 (폰트 테이블은 건드리지 않음)")

    if not args.write:
        print("\n(보고만 했다.  --write 로 기록)")
        return
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(bytes(rom))
    print(f"\nBIOS -> {OUT}  ({len(rom):,} B)")


if __name__ == "__main__":
    main()
