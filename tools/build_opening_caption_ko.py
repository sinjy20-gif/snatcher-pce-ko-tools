#!/usr/bin/env python3
"""오프닝 자막 다섯 장을 한글로 그린다 -- 화면 좌표에 그리고 스프라이트가 퍼간다.

무엇을 고치나
-------------
오프닝 자막 세 화면.  전부 스프라이트다 (BG 아니다 -- 2026-09-16 실기 확인).

    1991년 6월 6일 / 모스크바     프레임 5280 · 팔레트 0
    50년 후                      프레임 8004 · 팔레트 0
    2042.12. / 네오 고베 시티     프레임 10149 · 팔레트 7

왜 칸별로 안 그리나
-------------------
글자가 **스프라이트 경계를 가로질러** 흐른다.  `$4080`(x64,y72) 과 `$4040`(x80,y56)
을 풀어 보면 둘 다 글자 한 자가 아니라 **획의 조각**이다.  그래서 칸마다 글자를
배정하면 안 된다.  화면 좌표에 글을 한 번 그린 뒤, 스프라이트마다 자기 사각형을
퍼간다.  덮지 않은 칸은 자동으로 비워지므로 **잔상이 안 남는다**
(타이틀에서 `$6EC0` 을 목록에서 빠뜨려 금색 잔상이 남았던 것이 이 방식이면 안 생긴다).

색은 캡처에서 왔다
------------------
    팔레트 0   흰 7 #FCFCFC · 짙은파랑 테두리 14 #000090
    팔레트 7   흰 11 #FCFCFC · 짙은빨강 테두리 2 #6C0000

원본 실측 (잉크 높이) -- 글꼴 크기를 여기에 맞춘다

    모스크바 20 · 네오 고베 시티 13

글꼴은 `DNFBitBitv2` (소유자 선택 2026-09-16).  픽셀 글꼴이라 원본의 계단진 획과
결이 맞고 치수도 거의 그대로 겹친다.

쓰는 법
-------
    python tools/build_opening_caption_ko.py                미리보기 + 자리 계산
    python tools/build_opening_caption_ko.py --png <폴더>
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "extraction" / "patch" / "static")]

from PIL import Image, ImageDraw, ImageFont  # noqa: E402

import gfx_block_codec as codec  # noqa: E402

DUMP = ROOT / "dump"
FONT = ROOT / "DNFBitBitv2 (1)" / "DNFBitBitv2.ttf"
TRACKING = 1        # 글자 사이 여백.  테두리끼리 맞닿는 것을 뗀다
ALIGNED: list[int] = []      # 바닥이 맞는 글꼴 크기 -- main 에서 한 번 채운다

# 블록: (이름, VRAM 시작 워드, 풀림 바이트, 디스크 논리 주소, 압축 자리)
#   `find_at` 가 후보를 **각각 하나씩만** 내놨고, 0.8.1 업로드 맵에도 실제 목적지로
#   찍혀 있다 ($5000 3701 회 · $5800 2985 회 · $4000 2703 회).
BLOCKS = [
    ("A $5000", 0x5000, 4096, 0x023BE57, 2183),
    ("B $5800", 0x5800, 2048, 0x023C6DF, 1078),
    ("C $4000", 0x4000, 3200, 0x01FB902, 1528),
]

# 화면: (이름, VRAM 덤프, CRAM 덤프, 팔레트, 본체, 테두리, 글줄들)
#   글줄 = (한글, 글꼴크기, [그 줄이 쓰는 스프라이트들])
#   스프라이트 = (화면x, 화면y, 패턴워드, 폭, 높이)
#
# ★ 2026-09-16.  세로 자리를 **손으로 적지 않는다.**  처음에 기준선을 눈대중으로
#   넣었다가 `sy` 가 음수가 되어 「1991년 6월 6일」과 「50년 후」가 위로 통째로
#   잘려 나갔다.  이제 그 줄의 **원본 잉크 구간을 재서 거기 가운데로** 놓는다
#   (타이틀 메뉴에서 커서와 줄이 안 맞던 것도 같은 뿌리였다).
SCREENS = [
    ("모스크바", "sprite_opening_20260916_212643_vram_f005614.bin",
     "sprite_opening_20260916_212643_cram_f008158.bin", 0, 7, 14,
     [("1991년 6월 6일", 28,
       [(32, 80, 0x5000, 32, 32), (64, 80, 0x5100, 32, 32), (96, 80, 0x5200, 32, 32),
        (128, 80, 0x5300, 32, 32), (160, 80, 0x5400, 32, 32), (192, 80, 0x5500, 32, 32)]),
      ("모스크바", 28,
       [(80, 112, 0x5600, 32, 32), (112, 112, 0x5700, 32, 32), (144, 112, 0x5800, 32, 32)])]),

    ("50년 후", "sprite_opening_20260916_212643_vram_f008158.bin",
     "sprite_opening_20260916_212643_cram_f008158.bin", 0, 7, 14,
     [("50년 후", 28,
       [(80, 96, 0x5900, 32, 32), (112, 96, 0x5A00, 32, 32), (144, 96, 0x5B00, 32, 32)])]),

    ("네오 고베 시티", "sprite_neokobe_20260916_214051_vram_f010190.bin",
     "sprite_neokobe_20260916_214051_cram_f010190.bin", 7, 11, 2,
     [("2042.12.", 28,
       [(80, 56, 0x4040, 16, 16), (96, 56, 0x4100, 32, 32),
        (128, 56, 0x4200, 32, 32), (160, 56, 0x4300, 32, 32)]),
      # 띄어쓰기를 하나 줄였다.  `네오 고베 시티` 는 크기 20 에서 133px 로 칸(128)을
      # 넘어 13 까지 떨어지는데, 그러면 이 줄만 유독 작아진다.  원문도 붙여 쓴다.
      ("네오고베 시티", 28,
       [(64, 72, 0x4080, 32, 16),
        (64, 88, 0x4400, 32, 16), (96, 88, 0x4480, 32, 16),
        (128, 88, 0x4500, 32, 16), (160, 88, 0x4580, 32, 16)])]),
]


def all_sprites(lines) -> list:
    out = []
    for _text, _size, sprites in lines:
        out.extend(sprites)
    return out


def palette(cram: bytes, pal: int, entry: int) -> tuple[int, int, int]:
    at = (256 + pal * 16 + entry) * 2
    v = cram[at] | (cram[at + 1] << 8)
    g, r, b = (v >> 6) & 7, (v >> 3) & 7, v & 7
    return r * 36, g * 36, b * 36


def text_mask(text: str, size: int, tracking: int = 0) -> list[list[int]]:
    """글자를 1 비트 마스크로.  **글자마다 따로 뽑아 자간을 넣는다.**

    ★ 2026-09-16.  처음엔 `ImageDraw.text` 로 한 번에 그렸는데 두 가지가 겹쳤다.

      ① PIL 이 **안티앨리어싱**을 건다.  그것을 `0 보다 크면 잉크` 로 이진화하니
         흐린 가장자리까지 살아나 획이 굵어지고 이웃 글자와 붙었다.
         -> `getmask(mode="1")` 로 **안티앨리어싱 없이** 뽑는다.
      ② 픽셀 글꼴이라 작은 크기에서 속이 막힌다.  16~20 px 에서 `월`·`일` 의 `ㅇ`
         이 덩어리가 됐다 (소유자: "월 일이 이상해").  24 px 부터 제대로 열린다.

    자간(tracking)은 테두리끼리 붙는 것을 떼어 놓는다 -- 테두리가 1 px 씩 번지므로
    자간 0 이면 이웃 글자의 테두리가 맞닿는다.
    """
    face = ImageFont.truetype(str(FONT), size)
    # ★ 2026-09-16 (2).  글자마다 마스크를 따로 뽑아 **바닥 정렬**로 이어붙였더니
    #   각 글자의 세로 위치가 날아가 `후` 가 혼자 떠올랐다 (소유자: "후가 또 위로").
    #   `getmask` 는 잉크 사각형만 주고 기준선을 안 준다.
    #
    #   그래서 **모드 "1" 그림에 한 번에 그린다.**  1 비트 그림이라 PIL 이
    #   안티앨리어싱을 안 걸고(그게 애초에 획이 붙던 원인), 한 원점에 그리므로
    #   기준선이 저절로 맞는다.  자간은 글자마다 펜을 밀어 넣는다.
    # ⚠ 시트를 넉넉히.  `ImageDraw.text` 의 y 는 **글자 위쪽** 기준이므로 그 아래로
    #   글자 높이만큼이 더 필요하다.  처음에 높이를 `size*3` 두고 `size*2` 에
    #   그렸다가 아래가 한 칸밖에 안 남아 **받침이 통째로 잘렸다** (2026-09-16).
    pad = size
    sheet = Image.new("1", (int(face.getlength(text)) + tracking * len(text) + pad * 2,
                            size * 4), 0)
    draw = ImageDraw.Draw(sheet)
    pen = float(pad)
    for ch in text:
        draw.text((pen, pad), ch, font=face, fill=1)
        pen += face.getlength(ch) + tracking
    px = sheet.load()
    rows = [[1 if px[x, y] else 0 for x in range(sheet.width)]
            for y in range(sheet.height)]
    # 빈 가장자리를 떨어낸다.  여백이 남으면 가운데 맞춤이 그만큼 어긋난다.
    while rows and not any(rows[0]):
        rows.pop(0)
    while rows and not any(rows[-1]):
        rows.pop()
    if not rows:
        return [[0]]
    left = min((r.index(1) for r in rows if 1 in r), default=0)
    right = max((len(r) - 1 - r[::-1].index(1) for r in rows if 1 in r), default=0)
    return [r[left:right + 1] for r in rows]


def _ink_rows(face, ch: str, size: int) -> tuple[int, int] | None:
    img = Image.new("1", (size * 3, size * 4), 0)
    ImageDraw.Draw(img).text((size, size), ch, font=face, fill=1)
    px = img.load()
    rows = [y for y in range(img.height) if any(px[x, y] for x in range(img.width))]
    return (rows[0], rows[-1]) if rows else None


def aligned_sizes(lo: int = 10, hi: int = 32) -> list[int]:
    """**글자 바닥이 맞는** 크기만 고른다.

    ★ 2026-09-16 (3).  `후` 가 혼자 떠 보이던 것 (소유자: "후가 또 줄이 안맞아").
      원인은 내 코드가 아니라 **글꼴의 세로 지표**였다.  크기 21 에서 재보면

          5 · 0 · 월   잉크행 27~45      후   잉크행 25~44   ← 2 px 위 · 1 px 짧게 끝남
          getbbox      (0, 6, ...)             (0, 4, ...)

      픽셀 글꼴을 설계 크기가 아닌 값으로 뽑아 생긴 반올림이다.  전 크기를 훑어도
      **완벽히 맞는 크기는 없다** -- 한글 낱글자는 받침 유무로 세로 폭이 원래 다르다.
      그래도 **바닥이 딱 맞는** 크기는 있다 (10~32 중 13 과 20).  바닥만 맞으면
      눈에는 한 줄로 보인다.
    """
    good = []
    for size in range(lo, hi + 1):
        face = ImageFont.truetype(str(FONT), size)
        han = [_ink_rows(face, ch, size) for ch in "년후월일네오고베시티"]
        dig = [_ink_rows(face, ch, size) for ch in "0123456789"]
        if any(v is None for v in han + dig):
            continue
        hb = [b for _t, b in han]
        db = [b for _t, b in dig]
        if max(hb) == min(hb) and max(db) == min(db) and max(hb) == max(db):
            good.append(size)
    return good


def outlined(mask, body: int, edge: int) -> list[list[int]]:
    """본체 + 1 px 테두리.  원본이 그렇게 생겼다."""
    h, w = len(mask), len(mask[0])
    out = [[0] * (w + 2) for _ in range(h + 2)]
    for y in range(h):
        for x in range(w):
            if mask[y][x]:
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        out[y + 1 + dy][x + 1 + dx] = edge
    for y in range(h):
        for x in range(w):
            if mask[y][x]:
                out[y + 1][x + 1] = body
    return out


def read_cell(vram: bytes, word: int) -> list[list[int]]:
    off = word * 2
    rows = []
    for y in range(16):
        def f(o: int) -> int:
            return vram[o] | vram[o + 1] << 8
        p0, p1 = f(off + y * 2), f(off + 32 + y * 2)
        p2, p3 = f(off + 64 + y * 2), f(off + 96 + y * 2)
        rows.append([(1 if p0 & (0x8000 >> x) else 0) | (2 if p1 & (0x8000 >> x) else 0)
                     | (4 if p2 & (0x8000 >> x) else 0) | (8 if p3 & (0x8000 >> x) else 0)
                     for x in range(16)])
    return rows


def write_cell(vram: bytearray, word: int, rows: list[list[int]]) -> None:
    off = word * 2
    for y in range(16):
        planes = [0, 0, 0, 0]
        for x in range(16):
            v = rows[y][x]
            for b in range(4):
                if v >> b & 1:
                    planes[b] |= 0x8000 >> x
        for b in range(4):
            o = off + b * 32 + y * 2
            vram[o] = planes[b] & 0xFF
            vram[o + 1] = planes[b] >> 8


def ink_map(vram: bytes, sprites) -> tuple[list[list[int]], int, int]:
    """선언한 스프라이트를 화면 좌표에 펼친 원본 잉크 지도."""
    x0 = min(s[0] for s in sprites)
    y0 = min(s[1] for s in sprites)
    w = max(s[0] + s[3] for s in sprites) - x0
    h = max(s[1] + s[4] for s in sprites) - y0
    grid = [[0] * w for _ in range(h)]
    for sx, sy, word, pw, ph in sprites:
        cols, rws = pw // 16, ph // 16
        for cy in range(rws):
            for cx in range(cols):
                rows = read_cell(vram, word + (cy * cols + cx) * 64)
                for y in range(16):
                    for x in range(16):
                        if rows[y][x]:
                            ax, ay = sx + cx * 16 + x - x0, sy + cy * 16 + y - y0
                            if 0 <= ax < w and 0 <= ay < h:
                                grid[ay][ax] = 1
    return grid, x0, y0


def ink_bands(vram: bytes, sprites) -> list[tuple[int, int, int, int]]:
    """원본 잉크를 **빈 줄로 갈라** 글줄 띠를 낸다.  화면 좌표 (x0, y0, x1, y1).

    ★ 2026-09-16.  처음엔 "그 줄이 쓰는 스프라이트" 안의 잉크를 쟀는데, 스프라이트가
      줄 단위로 안 나뉘어서 틀렸다.  `$4100`(32x32, y56) 의 **아래 절반에 둘째 줄의
      윗부분**이 들어 있다.  그래서 두 줄 다 같은 사각형(높이 29)으로 재어졌고
      한 자리에 포개져 그려졌다 (소유자: "이건 왜 두개 겹쳐?").

      글줄은 스프라이트가 아니라 **잉크가 끊기는 자리**로 갈라야 한다.
    """
    grid, x0, y0 = ink_map(vram, sprites)
    bands: list[tuple[int, int, int, int]] = []
    start = None
    for y in range(len(grid) + 1):
        has = y < len(grid) and any(grid[y])
        if has and start is None:
            start = y
        elif not has and start is not None:
            xs = [x for yy in range(start, y) for x, v in enumerate(grid[yy]) if v]
            bands.append((x0 + min(xs), y0 + start, x0 + max(xs) + 1, y0 + y))
            start = None
    return bands


def build_screen(vram_src: bytes, screen, bias: int = 0) -> tuple[bytearray, dict, list]:
    name, _, _, pal, body, edge, lines = screen
    sprites = all_sprites(lines)
    vram = bytearray(vram_src)

    # ① 화면 좌표에 글을 그린다 (스프라이트 경계를 신경 쓰지 않는다)
    x0 = min(s[0] for s in sprites)
    y0 = min(s[1] for s in sprites)
    w = max(s[0] + s[3] for s in sprites) - x0
    h = max(s[1] + s[4] for s in sprites) - y0
    canvas = [[0] * w for _ in range(h)]
    report = []
    # ★ 글줄 띠는 **한 번만** 잰다 (잉크가 끊기는 자리로 가른다).  줄 순서대로 배정한다.
    bands = ink_bands(vram_src, sprites)
    if len(bands) < len(lines):
        raise SystemExit(
            f"{name}: 원본에서 글줄 띠 {len(bands)} 개만 잡혔다 (글줄 {len(lines)} 개)")
    for index, (text, size, line_sprites) in enumerate(lines):
        # ★ 크기는 **칸에 맞춰 자동으로 내린다.**  손으로 적으면 칸을 넘는 것을
        #   눈으로 확인해야 하고, 칸 폭이 줄마다 달라서 한 값으로는 못 맞춘다.
        #   작을수록 픽셀 글꼴 속이 막히므로 **들어가는 한 제일 큰 것**을 고른다.
        span = (max(q[0] + q[3] for q in line_sprites)
                - min(q[0] for q in line_sprites))
        band = (max(q[1] + q[4] for q in line_sprites)
                - min(q[1] for q in line_sprites))
        art = None
        # 바닥이 맞는 크기만 쓴다 (aligned_sizes 주석 참고)
        for try_size in [s for s in reversed(ALIGNED) if s <= size + bias]:
            cand = outlined(text_mask(text, try_size, TRACKING), body, edge)
            if len(cand[0]) <= span and len(cand) <= band:
                art, size = cand, try_size
                break
        if art is None:
            raise SystemExit(f"{text!r} 가 칸 {span}x{band} 에 안 들어간다")
        aw, ah = len(art[0]), len(art)
        # ★ 그 줄의 띠 안에 가운데로 앉힌다 -- 손으로 적지 않는다
        bx0, by0, bx1, by1 = bands[index]
        sx = bx0 + ((bx1 - bx0) - aw) // 2 - x0
        sy = by0 + ((by1 - by0) - ah) // 2 - y0
        for y, row in enumerate(art):
            for x, v in enumerate(row):
                if not v:
                    continue
                ax, ay = sx + x, sy + y
                if 0 <= ax < w and 0 <= ay < h:
                    canvas[ay][ax] = v
        report.append((text, aw, ah, bx1 - bx0, by1 - by0, bx0, by0, span, size))

    # ② 스프라이트마다 자기 사각형을 퍼간다 -- 안 덮은 칸은 비워진다
    for sx, sy, word, pw, ph in sprites:
        cols, rws = pw // 16, ph // 16
        for cy in range(rws):
            for cx in range(cols):
                rows = [[0] * 16 for _ in range(16)]
                for y in range(16):
                    for x in range(16):
                        ax = sx + cx * 16 + x - x0
                        ay = sy + cy * 16 + y - y0
                        if 0 <= ax < w and 0 <= ay < h:
                            rows[y][x] = canvas[ay][ax]
                write_cell(vram, word + (cy * cols + cx) * 64, rows)
    return vram, {"name": name, "pal": pal}, report


def render(vram: bytes, cram: bytes, screen) -> Image.Image:
    _, _, _, pal, _, _, lines = screen
    sprites = all_sprites(lines)
    x0 = min(s[0] for s in sprites)
    y0 = min(s[1] for s in sprites)
    w = max(s[0] + s[3] for s in sprites) - x0
    h = max(s[1] + s[4] for s in sprites) - y0
    img = Image.new("RGB", (w, h), (0, 0, 0))
    px = img.load()
    for sx, sy, word, pw, ph in sprites:
        cols, rws = pw // 16, ph // 16
        for cy in range(rws):
            for cx in range(cols):
                rows = read_cell(vram, word + (cy * cols + cx) * 64)
                for y in range(16):
                    for x in range(16):
                        v = rows[y][x]
                        if not v:
                            continue
                        ax, ay = sx + cx * 16 + x - x0, sy + cy * 16 + y - y0
                        if 0 <= ax < w and 0 <= ay < h:
                            px[ax, ay] = palette(cram, pal, v)
    return img


def block_sizes(bias: int) -> dict[int, tuple[int, int]]:
    """그 보정값으로 구웠을 때 블록마다 (압축 바이트, 자리) 를 낸다."""
    merged: dict[int, bytearray] = {}
    for screen in SCREENS:
        _n, vf, _cf, _p, _b, _e, lines = screen
        src = (DUMP / vf).read_bytes()
        ko, _, _ = build_screen(src, screen, bias)
        for sx, sy, word, pw, ph in all_sprites(lines):
            for _bn, base, nbytes, _bl, _br in BLOCKS:
                if base <= word < base + nbytes // 2:
                    buf = merged.setdefault(base, bytearray(src))
                    for i in range((pw // 16) * (ph // 16)):
                        w0 = (word + i * 64) * 2
                        buf[w0:w0 + 128] = ko[w0:w0 + 128]
    out = {}
    for _name, base, nbytes, _logical, room in BLOCKS:
        buf = merged.get(base)
        if buf is None:
            continue
        out[base] = (len(codec.encode(bytes(buf[base * 2:base * 2 + nbytes]))), room)
    return out


def pick_bias(_png: str) -> int:
    """압축 자리에 다 들어가는 **제일 큰** 크기 보정을 고른다."""
    for bias in range(0, -9, -1):
        sizes = block_sizes(bias)
        if all(n <= room for n, room in sizes.values()):
            return bias
        worst = max(n - room for n, room in sizes.values())
        print(f"  보정 {bias:+d} -> 제일 넘치는 블록 {worst:+d} B")
    raise SystemExit("크기를 8 단 내려도 압축 자리에 안 들어간다")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--png", default=str(ROOT / "build" / "gfx" / "captions"))
    args = ap.parse_args()
    if not FONT.is_file():
        raise SystemExit(f"글꼴이 없다: {FONT}")

    out = Path(args.png)
    out.mkdir(parents=True, exist_ok=True)

    # ★ 칸에 들어가는 것만으로는 부족하다.  글자가 커지면 잉크가 늘어 **압축이
    #   나빠진다** -- 자동 맞춤이 제일 큰 크기를 고르자 A 가 107 B, B 가 45 B
    #   넘쳤다 (2026-09-16).  압축 자리까지 들어갈 때까지 크기를 한 단씩 내린다.
    ALIGNED[:] = aligned_sizes()
    if not ALIGNED:
        raise SystemExit("바닥이 맞는 글꼴 크기가 없다")
    print("바닥이 맞는 크기: " + " ".join(str(s) for s in ALIGNED))

    bias = pick_bias(args.png)
    print(f"크기 보정 {bias:+d} (압축 자리에 맞춘 값)\n")

    panels: list[tuple[str, Image.Image]] = []
    merged: dict[int, bytearray] = {}

    for screen in SCREENS:
        name, vf, cf, pal, body, edge, lines = screen
        sprites = all_sprites(lines)
        src = (DUMP / vf).read_bytes()
        cram = (DUMP / cf).read_bytes()
        ko, _, report = build_screen(src, screen, bias)
        print(f"[{name}]  팔레트 {pal} · 본체 {body} · 테두리 {edge}")
        for text, aw, ah, ow, oh, ox, oy, span, size in report:
            # 한도는 **스프라이트 칸**이다.  원본 잉크 폭은 참고값일 뿐이다
            flag = f"칸 여유 {span - aw}px" if span >= aw else f"★ 칸 {aw - span}px 초과"
            print(f"    {text:<16} 크기 {size} · 그림 {aw}x{ah} · 칸 {span}px"
                  f" · 원본 잉크 {ow}x{oh}  -> {flag}")
        panels.append((f"{name} · 원본", render(src, cram, screen)))
        panels.append((f"{name} · 한글", render(bytes(ko), cram, screen)))
        for sx, sy, word, pw, ph in sprites:
            for _bn, base, nbytes, _bl, _br in BLOCKS:
                if base <= word < base + nbytes // 2:
                    buf = merged.setdefault(base, bytearray(src))
                    cols, rws = pw // 16, ph // 16
                    for i in range(cols * rws):
                        w0 = (word + i * 64) * 2
                        buf[w0:w0 + 128] = ko[w0:w0 + 128]
        print()

    print("=== 압축 자리 ===")
    ok = True
    for name, base, nbytes, logical, room in BLOCKS:
        src_name = SCREENS[2][1] if base == 0x4000 else SCREENS[0][1]
        src = (DUMP / src_name).read_bytes()
        before = codec.encode(bytes(src[base * 2:base * 2 + nbytes]))
        buf = merged.get(base, bytearray(src))
        after = codec.encode(bytes(buf[base * 2:base * 2 + nbytes]))
        slack = room - len(after)
        print(f"  {name}  논리 ${logical:07X} · 원본압축 {len(before):4d} · 한글압축 {len(after):4d}"
              f" · 자리 {room:4d}  -> " + (f"여유 {slack:+d} B" if slack >= 0 else f"★ {-slack} B 초과"))
        ok &= slack >= 0
        (out / f"vram_ko_{base:04X}.bin").write_bytes(bytes(buf))

    scale, pad, head = 3, 8, 13
    width = max(p[1].width for p in panels) * scale + pad * 2
    height = sum(p[1].height * scale + head for p in panels) + pad * 2
    sheet = Image.new("RGB", (width, height), (20, 20, 26))
    d = ImageDraw.Draw(sheet)
    y = pad
    for label, img in panels:
        d.text((pad, y), label, fill=(240, 230, 150))
        y += head
        sheet.paste(img.resize((img.width * scale, img.height * scale),
                               Image.Resampling.NEAREST), (pad, y))
        y += img.height * scale
    sheet.save(out / "caption_before_after.png")
    print(f"\n미리보기 {out / 'caption_before_after.png'}")
    print("판정: " + ("세 블록 다 들어간다" if ok else "★ 자리 초과 -- 글자를 줄이거나 크기를 낮출 것"))


if __name__ == "__main__":
    main()
