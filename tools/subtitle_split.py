#!/usr/bin/env python3
"""한 줄에 안 들어가는 자막을 조각으로 나눈다 -- 빌더와 검증기가 **같은** 규칙을 쓴다.

왜 따로 있나
------------
엔진의 한 줄은 VRAM 19 칸이다 (`subtitle_layout.MAX_GLYPHS`).  그 중 마지막 칸은
실제로 채우면 글자가 잘리므로 물리 안전 상한은 18 칸이다
(`SAFE_GLYPHS`, 실측 2026-08-28).  실제 화면에서 확인한 번역문 운용 한도는
**공백 포함 16 칸**이다 (실측 2026-09-01).  따라서 빌더는 16 칸에서 나눈다.

CD-DA 나레이션에는 32 칸짜리 줄이 있다.  엔진이 **터지지는 않는다** -- 셀 수를
`CMP #20 / LDA #19` 로 잘라내고 레코드도 63 B (머리 6 + 19 칸) 만 읽어 오므로
`list` 밖으로 나가지 않는다.  대신 스무 번째 글자부터 조용히 사라지고, 줄 폭이
u8 에 안 들어가 (320 -> 255) 가운데맞춤까지 어긋난다.  글을 버리지 않으려면
잘라내는 게 아니라 **나눠야** 한다.

나누는 규칙이 빌더와 검증기 두 곳에 있으면 반드시 어긋난다.  그래서 여기 한 번만
적는다.  검증기는 이 나눔을 그대로 쓰되 그 말을 믿지는 않는다 -- 조각을 도로
이어 붙여 **글자가 하나도 안 없어졌는지** 따로 본다 (경계의 공백만 사라진다).

셀 수가 0 인 기록은 절대 만들면 안 된다
---------------------------------------
엔진의 글리프 루프는 do-while 이다 (`DEC $15 / BEQ / JMP`).  count 가 0 이면
$15 가 $FF 로 돌아 **256 번** 돌고, X 가 5 씩 늘며 `list` 를 넘어 `record` 와
`stage` 를 덮는다.  이건 진짜 메모리 파괴다.  그래서 빈 기록은 빌드를 멈춘다.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import subtitle_layout as L     # noqa: E402  칸 수는 자리표에만 적는다

# Galmuri9 에 없는 문장부호만 표시용으로 바꾼다.  빌더와 검증기가 같이 본다.
DISPLAY_ALIASES = {"—": "-"}

# ★★ 2026-09-03: 나누는 기준은 **폭** 이다 (스튜디오와 같은 규칙).
#
#   렌더러가 가운데 정렬이라 한 줄의 오른쪽 끝은 언제나 160 + 폭/2 다.
#   화면(256) 안에 있으려면  160 + 폭/2 <= 256  ->  **폭 <= 192 px**.
#   192 는 어림값이 아니라 가운데 정렬에서 유도되는 값이다.
#
#   옛 `LIMIT_CELLS = 16` 은 그것을 12 px/자 로 어림한 대용품이었다.  실제
#   최대 advance 는 10 px 이고 띄어쓰기·문장부호는 4~6 px 라, 같은 칸 수라도
#   폭이 딴판이다 -- "메탈, JUNKER 본부로 서두르자" 는 19 칸인데 140 px 다.
#   그래서 칸으로는 판정하지 않는다.
LIMIT_PX = 192                  # ★ 화면 판정 -- 가운데 정렬에서 유도된 값
ENGINE_MAX_CELLS = L.MAX_GLYPHS # 19.  VRAM 글리프 슬롯.  넘으면 글자가 조용히 사라진다
LIMIT_CELLS = ENGINE_MAX_CELLS  # 칸 한도는 곧 엔진 슬롯이다 (폭과 성격이 다른 관문)
# 내용과 **무관하게** 안전한 칸 수.  글꼴의 최대 advance 가 10 px 이므로
# 192 // 10 = 19 다 -- 전부 가장 넓은 글자여도 190 px 라 안 넘친다.
# (옛 값 16 은 한 글자를 12 px 로 본 어림이었다.)
SAFE_CELLS = LIMIT_PX // 10


def normalize_ellipsis(text: str) -> str:
    """모든 말줄임표 표기를 한 칸짜리 U+2026으로 통일한다.

    일반 대사 코덱(game_text_codec)은 이미 같은 규칙을 쓴다. 이 네이티브
    자막 경로에도 입구에서 적용해야 ADPCM/CD-DA가 ``...``를 세 글리프로
    싣는 일이 없다.
    """

    return (text or "").replace("...", "…").replace("⋯", "…")


def display_text(text: str, font) -> tuple[str, list[str]]:
    """원문 -> (그릴 수 있는 글자만 남은 문장, 버려진 글자들).

    `font` 는 `in` 만 되면 된다 -- 빌더는 글꼴 표(dict), 검증기는 글자 집합(set).
    """
    kept: list[str] = []
    dropped: list[str] = []
    for char in normalize_ellipsis(text):
        display_char = DISPLAY_ALIASES.get(char, char)
        if display_char in font:
            kept.append(display_char)
        else:
            dropped.append(char)
    return "".join(kept), dropped


def line_width(text: str, advance: dict[str, int]) -> int:
    return sum(advance.get(ch, 0) for ch in text)


def _fits(text: str, advance: dict[str, int], limit_cells: int, limit_px: int) -> bool:
    return len(text) <= limit_cells and line_width(text, advance) <= limit_px


def _break_before(cur: str, nxt: str, advance: dict[str, int],
                  limit_cells: int, limit_px: int) -> tuple[str, str]:
    """`cur` 를 끊을 자리를 고른다 -> (앞 조각, 다음 조각으로 넘길 꼬리).

    되도록 마지막 공백에서 끊는다.  단 넘길 꼬리가 그 자체로 한도를 넘으면
    (한 낱말이 16 칸보다 길 때) 공백을 포기하고 한도에서 그냥 자른다 --
    안 그러면 다음 조각이 한도를 넘은 채 나온다.
    """
    cut = cur.rfind(" ")
    while cut > 0:
        tail = cur[cut + 1:]
        if tail and _fits(tail + nxt, advance, limit_cells, limit_px):
            return cur[:cut], tail
        cut = cur.rfind(" ", 0, cut)
    return cur, ""


def split_line(text: str, advance: dict[str, int], *,
               limit_cells: int = LIMIT_CELLS,
               limit_px: int = LIMIT_PX) -> list[str]:
    """표시용 문장 -> 한 줄에 들어가는 조각들.  붙여 놓으면 원문이 돌아온다.

    경계의 공백은 버린다 -- 줄이 바뀌는 것이 그 자리를 대신하기 때문이다.
    """
    chunks: list[str] = []
    cur = ""
    for char in text:
        if cur and not _fits(cur + char, advance, limit_cells, limit_px):
            head, cur = _break_before(cur, char, advance, limit_cells, limit_px)
            head = head.strip()
            if head:
                chunks.append(head)
        cur += char
    cur = cur.strip()
    if cur:
        chunks.append(cur)
    if not chunks:
        return []
    for chunk in chunks:
        if not _fits(chunk, advance, limit_cells, limit_px):
            raise AssertionError(f"조각이 한도를 넘었다: {len(chunk)} 칸 · "
                                 f"{line_width(chunk, advance)} px · {chunk!r}")
    return chunks


def portion(lba_from: int, lba_to: int, weights: list[int]) -> list[tuple[int, int]] | None:
    """구간 하나를 조각 수만큼 나눈다.  글자가 많은 조각이 오래 떠 있는다.

    조각마다 최소 1 섹터를 준다.  구간이 조각 수보다 짧아 그것도 못 하면 `None` --
    부르는 쪽이 빌드를 멈춘다 (원본 표의 시각이 틀렸다는 뜻이다).
    """
    count = len(weights)
    if count <= 1:
        return [(lba_from, lba_to)]
    span = lba_to - lba_from
    if span < count:
        return None
    total = sum(weights) or count
    windows: list[tuple[int, int]] = []
    at = lba_from
    done = 0
    for i, weight in enumerate(weights[:-1]):
        done += weight
        # 뒤에 남은 조각들 몫으로 최소 (count-1-i) 섹터를 남겨 둔다
        edge = lba_from + min(span - (count - 1 - i), done * span // total)
        edge = max(edge, at + 1)
        windows.append((at, edge))
        at = edge
    windows.append((at, lba_to))
    return windows


# ---------------------------------------------------------------------------
# CD-DA 자막 한 줄의 LBA 창
#
# ★ 자막 시간은 **트랙 기준 절대시각**이다 (2026-08-31).  1 트랙 = 1 음성이고
#   자막은 그 안에 종속된다 -- 그래야 트랙 통짜를 들으며 싱크를 맞출 수 있다.
#
# 빌더와 검증기가 이 값을 **똑같이** 내야 한다.  따로 적어 두었더니 한쪽만 고쳐서
# "나눈 창이 비었다" 가 698 번 났다.  그래서 여기 한 곳에만 적는다.
# ---------------------------------------------------------------------------

SECTORS_PER_SEC = 75


def cdda_track_spans(segments):
    """트랙마다 (LBA 기준점, 끝).  기준점은 그 트랙의 0 초에 해당하는 LBA 다.

    LBA 는 트랙 안에서 정확히 선형이다 (75 섹터/초, 19 트랙 전부 검산).
    """
    base: dict[str, int] = {}
    limit: dict[str, int] = {}
    for seg in segments.values():
        track = (seg.get("track") or "").strip()
        if not track:
            continue
        base.setdefault(
            track,
            int(seg["lba_from"]) - round(float(seg["start_sec"]) * SECTORS_PER_SEC))
        limit[track] = max(limit.get(track, 0), int(seg["lba_to"]))
    return base, limit


def cdda_window(row, segments, base, limit):
    """자막 한 줄 -> (lba_from, lba_to).  창을 못 잡으면 None.

    ★ 그 시각이 아직 원래 clip 안에 있으면 **clip 기준으로** 잰다.
      트랙 기준으로 재도 수학적으로는 같은 값인데, `int()` 를 어디서 자르느냐에
      따라 한 섹터가 흔들린다.  안전위치표(`cdda_runtime_safe_positions.tsv`)는
      `(lba_from, lba_to)` **정확 일치**로 채점하므로 한 섹터가 어긋나면 그동안
      쌓은 검증이 통째로 날아간다 (실측: 255 -> 104).
      시각을 옮겨 clip 밖으로 나가면 그때 트랙 기준으로 넘어간다.
    """
    track = (row.get("track") or "").strip()
    start = float(row.get("start_sec") or 0)
    duration = float(row.get("duration_sec") or 0)

    clip = segments.get((row.get("clip") or "").strip())
    if (clip is not None
            and float(clip["start_sec"]) - 1e-6 <= start <= float(clip["end_sec"]) + 1e-6):
        at, edge, rel = int(clip["lba_from"]), int(clip["lba_to"]), start - float(clip["start_sec"])
    elif track in base:
        at, edge, rel = base[track], limit[track], start
    else:
        return None

    lba_from = at + int(rel * SECTORS_PER_SEC)
    lba_to = min(edge, lba_from + max(1, int(duration * SECTORS_PER_SEC)))
    return lba_from, lba_to


def trim_cdda_overlaps(windows):
    """정렬된 (lba_from, lba_to, ...) 목록에서 이웃과 겹치는 끝을 당긴다.

    시간을 LBA 로 바꿀 때 `int()` 로 자르므로, 앞 자막이 다음 자막의 시작에 딱
    붙어 끝나면 끝이 한 섹터 넘어가는 일이 생긴다 (실측 4 건).  런타임은 이분
    탐색으로 창을 고르므로 겹치면 어느 쪽이 뜰지가 정렬 순서에 달린다.

    줄이기만 한다.  빌더와 검증기가 **같은 값**을 내야 하므로 여기 한 곳에 둔다.
    """
    out = list(windows)
    for i in range(len(out) - 1):
        a, b = out[i], out[i + 1]
        if b[0] < a[1]:
            out[i] = (a[0], max(a[0] + 1, b[0])) + tuple(a[2:])
    return out
