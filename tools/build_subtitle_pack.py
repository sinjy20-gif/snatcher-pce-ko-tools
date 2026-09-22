#!/usr/bin/env python3
"""자막 팩을 만든다 -- 아케이드 카드 $160000 에 통째로 올라갈 한 덩어리.

왜 이 빌더가 따로 있나
----------------------
`build_subtitle_disc_payload.py` 는 폐기됐다.  그것은 **코드가 $5C40 에 상주한다**
고 가정했는데, `$5C40-$5E1F` 는 스크립트 VM 데이터 스택 안이었다 (PIPELINE §9.1).

그 폐기는 **배치**를 무효로 했지 **데이터**를 무효로 하지 않았다.  자막 글자·트리거·
글리프는 코드가 어디서 돌든 똑같이 필요하다.  그래서 데이터만 따로 굽는다.

    폐기됨   $5C40 상주 가정 · 1 차 페이로드의 코드 배치
    살아남음 글꼴 · 트리거(ADPCM 지문 · CD-DA LBA) · 세그먼트 표  <- 여기서 굽는다

감시자를 어디 둘지(헬퍼 여유 151 B 가 후보)가 아직 안 정해졌지만, 그 답이 무엇이든
이 팩은 바뀌지 않는다.  그래서 지금 만들 수 있다.

두 트리거는 성격이 다르다
-------------------------
    ADPCM   사건 기반.  재생 시작 순간의 레지스터 세 값이 열쇠다
            (읽기주소 · 길이 · 재생률)
    CD-DA   시계 기반.  재생 위치가 어느 LBA 구간에 드는가

그래서 색인도 둘이다.  CD-DA 색인은 `lba_from` 으로 정렬해 둔다 -- 런타임이
이분 탐색만 하면 되도록.  613 항목이면 비교 10 번이다.

런타임이 계산을 하나도 안 하게 한다
-----------------------------------
6280 은 곱셈이 없고 자막은 **비례폭**이다.  그래서 글자마다 펜 위치를 여기서
미리 다 계산해 박는다.  런타임은 SATB 에 그대로 밀어 넣기만 한다.

입력
----
    build/cutscene_subs/subfont_Galmuri9.bin / .tsv    글꼴 3320 자
    build/cutscene_subs/cdda_segments.tsv              구간 407 개의 절대 LBA
    snatcher_tool/translation/cdda_subtitles.tsv       CD-DA 한국어 (clip + part)
    snatcher_tool/translation/voice_subtitles_keyed.tsv ADPCM 한국어 (음성 key + part)
    snatcher_tool/translation/voice_console_keys.tsv    음성 key -> 콘솔 6 B 지문

출력
----
    build/cutscene_subs/subtitle_pack.bin       AC $160000 에 그대로 올린다
    build/cutscene_subs/subtitle_pack.json      오프셋 표 (Lua·엔진이 읽는다)
    build/cutscene_subs/pack_overwidth.tsv      폭이 넘친 자막 (있을 때만)
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import struct
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "build" / "cutscene_subs"
TRANS = ROOT / "snatcher_tool" / "translation"

FONT_BIN = OUT_DIR / "subfont_Galmuri9.bin"
FONT_TSV = OUT_DIR / "subfont_Galmuri9.tsv"
SEGMENTS = OUT_DIR / "cdda_segments.tsv"
# 시험 빌드는 마스터 파일을 직접 입력으로 잡지 않고, 호출자가 만든 불변
# 스냅샷을 지정할 수 있다. 미지정 시 기존 동작은 그대로 유지한다.
CDDA_SUBS = Path(os.environ.get("SNATCHER_CDDA_SUBS", TRANS / "cdda_subtitles.tsv"))
VOICE_SUBS = TRANS / "voice_subtitles_keyed.tsv"
VOICE_KEYS = TRANS / "voice_keys.tsv"
VOICE_EVENTS = TRANS / "voice_events.tsv"   # 스튜디오가 kind/speaker 를 쓰는 표
VOICE_CONSOLE_KEYS = TRANS / "voice_console_keys.tsv"

PACK_BIN = OUT_DIR / "subtitle_pack.bin"
PACK_JSON = OUT_DIR / "subtitle_pack.json"
OVERWIDTH = OUT_DIR / "pack_overwidth.tsv"
OVER_CAPACITY = OUT_DIR / "pack_over_capacity.tsv"
ADPCM_COLLISIONS = OUT_DIR / "adpcm_key_collisions.tsv"

sys.path.insert(0, str(Path(__file__).resolve().parent))
import subtitle_layout as L     # noqa: E402  자리는 한 곳에만 적는다
import subtitle_split as S      # noqa: E402  나누는 규칙은 검증기와 같이 쓴다

AC_BASE = L.AC_PACK
AC_RESERVE = L.AC_PACK_MAX      # 침범하면 빌드가 멈춘다
GLYPH_BYTES = 64                # 플레인 0 본체 · 플레인 1 검은 외곽선
SECTORS_PER_SEC = 75
# 한 줄 한도는 tools/subtitle_split.py 에 한 번만 적는다 -- 검증기도 같은 것을 본다.
LIMIT_PX = S.LIMIT_PX                    # 192.  초상화 위 한 줄에 들어가는 폭 (실측)
# ★ 번역문 운용 한도는 공백 포함 16 칸이다 (실측, 2026-09-01).
#   VRAM 물리 상한은 19 칸, 마지막 잘림을 피한 안전 상한은 18 칸이지만 화면에서
#   끝까지 확실히 보이는 16 칸에서 미리 나눈다.
LIMIT_CELLS = S.LIMIT_CELLS              # 16.  나눌 때 맞추는 자리
ENGINE_MAX_CELLS = S.ENGINE_MAX_CELLS    # 19.  넘으면 엔진이 글자를 조용히 버린다
# 자막 자리 세 칸.  글리프가 16 px 이므로 아래는 224-16 을 넘지 않는다.
#   중간 122 는 눈으로 맞춘 값이다 -- 게임 중 대사가 초상화 위에 걸리는 자리
POSITIONS = {"위": 32, "중간": 122, "아래": 192}
DEFAULT_POS = {"adpcm": "중간", "cdda": "아래"}   # 컷신은 화면을 다 쓴다
DISPLAY_ALIASES = S.DISPLAY_ALIASES  # Galmuri9에 없는 문장부호만 표시용 대체
HEADER_BYTES = 64
CELL_BYTES = 3                  # 글리프 번호 u16 · x u8 (셀별 y는 늘 0이라 제거)
REC_HEADER = 6
ADPCM_STRIDE = 13               # 런타임 키 6 · 플래그 1 · 시작프레임 2 · 기록 4
CDDA_STRIDE = 10                # LBA 3+3 · 기록 3 · 플래그 1

MAGIC = b"SNSB"
VERSION = 6   # 6: end+rate+ADPCM RAM 3표본의 콘솔 가시 6바이트 키

def pos_y(name: str | None, source: str) -> int:
    """자리 이름 -> y.  비어 있으면 그 출처의 기본값."""
    key = (name or "").strip()
    if key not in POSITIONS:
        key = DEFAULT_POS[source]
    return POSITIONS[key]


def read_tsv(path: Path) -> list[dict]:
    """TSV 를 읽는다.

    `quoting=QUOTE_NONE` 이 중요하다 -- 글꼴 표에 홑따옴표(U+0022) 글자가 있어서
    기본 설정이면 3320 행이 3 행으로 뭉개진다.  한 번 당했다.
    """
    if not path.exists():
        raise SystemExit(f"파일이 없다: {path}")
    with path.open(encoding="utf-8-sig", newline="") as fh:
        # 글꼴표는 `"` 글자 자체가 행이라 quoting을 끄지만,
        # Studio가 쓰는 번역표는 줄바꿈이 든 셀을 CSV 규칙으로
        # 인용한다. 그 표까지 QUOTE_NONE으로 읽으면 구조적 `"`가
        # 자막 한 칸으로 잘못 실린다.
        quoting = csv.QUOTE_NONE if path == FONT_TSV else csv.QUOTE_MINIMAL
        return list(csv.DictReader(fh, delimiter="\t", quoting=quoting))


def load_font() -> tuple[bytes, dict[str, tuple[int, int]]]:
    """글꼴 -> (원본 바이트, 글자 -> (오프셋, 폭))."""
    if not FONT_BIN.exists():
        raise SystemExit(f"글꼴이 없다: {FONT_BIN}\n먼저 tools/build_subtitle_font.py 를 돌려라")
    blob = FONT_BIN.read_bytes()
    table: dict[str, tuple[int, int]] = {}
    for row in read_tsv(FONT_TSV):
        char = row["char"]
        if len(char) == 1:
            table[char] = (int(row["offset"], 16), int(row["advance"]))
    if not table:
        raise SystemExit("글꼴 표가 비었다")
    return blob, table


def layout(text: str, font: dict[str, tuple[int, int]]) -> tuple[list[tuple[str, int]], int]:
    """**표시용** 문장 -> ([(글자, 펜 위치)], 줄 폭).

    글꼴에 없는 글자는 `subtitle_split.display_text` 가 이미 걷어냈다.  나누기
    **전에** 걷어내야 조각 경계가 빌더와 검증기에서 같아진다 -- 없는 글자를
    세면서 자르면 두 쪽이 서로 다른 자리에서 끊는다.
    """
    cells: list[tuple[str, int]] = []
    pen = 0
    for char in text:
        cells.append((char, pen))
        pen += font[char][1]
    return cells, pen


class Records:
    """자막 기록들을 한 덩어리로 쌓는다.  같은 글이면 한 번만 넣는다."""

    def __init__(self) -> None:
        self.blob = bytearray()
        self.seen: dict[tuple, int] = {}

    def add(self, cells: list[tuple[int, int]], width: int, flags: int,
            duration_frames: int, text_y: int) -> int:
        key = (tuple(cells), width, flags, duration_frames, text_y)
        if key in self.seen:
            return self.seen[key]
        offset = len(self.blob)
        # +03 은 예전에 남는 자리였다.  이제 y 다 -- 같은 글이라도 컷신이면
        # 다른 자리에 떠야 하므로 기록마다 갖는다
        self.blob += struct.pack("<BBBBH", len(cells), min(width, 255), flags,
                                 text_y & 0xFF, min(duration_frames, 0xFFFF))
        for glyph_id, x in cells:
            self.blob += struct.pack("<HB", glyph_id, min(x, 255))
        self.seen[key] = offset
        return offset


def reviewed(row: dict) -> bool:
    """검토 표시가 "O" 인가.  대사·UI 탭과 같은 규약이다."""
    return (row.get("review") or "").strip().upper() == "O"



def voice_start_lba() -> dict:
    """event_id(고유 문자열 키) -> start_lba.

    `adpcm_lba_master_index.tsv` 는 `key`(sector 가 든 고유 키)와 `start_lba` 를
    같이 들고 있다.  런타임 키가 겹쳐도 이 표에서는 음성이 갈린다.
    """
    path = OUT_DIR / "adpcm_lba_master_index.tsv"
    if not path.exists():
        return {}
    out = {}
    with path.open(encoding="utf-8-sig", newline="") as fh:
        for row in csv.DictReader(fh, delimiter="\t"):
            key = (row.get("key") or "").strip()
            lba = (row.get("start_lba") or "").strip()
            if key and lba:
                try:
                    out[key] = int(lba, 16)
                except ValueError:
                    pass
    return out

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--reviewed-only", action="store_true",
                    help="검토 O 인 자막만 굽는다 (조금씩 확인하며 넣을 때)")
    ap.add_argument("--skip-keyless", action="store_true",
                    help="콘솔 키가 없는 음성은 자막을 빼고 굽는다 (기본은 빌드 중단)")
    ap.add_argument("--skip-oversize", action="store_true",
                    help="엔진 한도(19칸)를 넘는 자막은 빼고 굽는다 (기본은 빌드 중단)")
    ap.add_argument("--skip-collisions", action="store_true",
                    help="콘솔 키가 겹쳐 구분 안 되는 음성은 빼고 굽는다 (기본은 빌드 중단)")
    args = ap.parse_args()
    skip_keyless = args.skip_keyless or         os.environ.get("SNATCHER_SUBTITLE_SKIP_KEYLESS", "0") == "1"
    skip_oversize = args.skip_oversize or         os.environ.get("SNATCHER_SUBTITLE_SKIP_OVERSIZE", "0") == "1"
    skip_collisions = args.skip_collisions or         os.environ.get("SNATCHER_SUBTITLE_SKIP_COLLISIONS", "0") == "1"
    # 환경변수로도 켤 수 있다 -- 상위 빌더가 부를 때 인자를 못 넘기는 경우가 있다
    reviewed_only = args.reviewed_only or         os.environ.get("SNATCHER_SUBTITLE_REVIEWED_ONLY", "0") == "1"

    font_blob, font = load_font()
    # 구분(kind)은 **스튜디오가 쓰는 표**가 기준이다 (voice_events.tsv).
    # voice_keys.tsv 에도 같은 열이 있지만 build_voice_keys.py 가 옛 표에서
    # 승계만 하므로 뒤처진다 -- 2026-09-02 실측: events 는 기타 979 가 채워져
    # 있는데 keys 는 그 자리가 전부 빈칸이었다.  keys 는 뒤채움으로만 쓴다.
    voice_meta = {r["key"]: r for r in read_tsv(VOICE_KEYS) if r.get("key")}
    for row in read_tsv(VOICE_EVENTS):
        key = (row.get("event_id") or "").strip()
        kind = (row.get("kind") or "").strip()
        if key and kind:
            voice_meta.setdefault(key, {})
            voice_meta[key] = {**voice_meta.get(key, {}), "kind": kind}

    # 효과음만 뺀다.  「기타」는 **아직 안 들어본 것**이지 효과음이 아니다 --
    # 소유자 방침은 "효과음 여부를 자동 추정하지 않는다.  사용자가 효과음으로
    # 표시한 항목만 효과음으로 취급한다" 이다.  기타까지 빼면 1,110 음성이
    # 통째로 사라져 ADPCM 자막이 71 음성밖에 안 남는다 (2026-09-02).
    excluded_voice_kinds = {"효과음"}

    # ---- 쓰이는 글자만 골라 담는다.  3320 자를 통째로 실으면 208 KB 다 ----
    used: set[str] = set()
    cdda_all = [r for r in read_tsv(CDDA_SUBS) if (r.get("ko_text") or "").strip()]
    voice_all = [r for r in read_tsv(VOICE_SUBS)
                 if (r.get("ko_text") or "").strip()
                 and (voice_meta.get(r.get("key", ""), {}).get("kind") or "").strip()
                     not in excluded_voice_kinds]
    if reviewed_only:
        cdda_rows = [r for r in cdda_all if reviewed(r)]
        voice_rows = [r for r in voice_all if reviewed(r)]
        print(f"검토 O 만 굽는다 -- CD-DA {len(cdda_rows)}/{len(cdda_all)} "
              f"· 음성 {len(voice_rows)}/{len(voice_all)}")
        if not cdda_rows and not voice_rows:
            print("★ 검토 O 인 자막이 하나도 없다.  스튜디오에서 표시한 뒤 다시 굽는다")
    else:
        cdda_rows, voice_rows = cdda_all, voice_all
    for row in cdda_rows + voice_rows:
        used.update(DISPLAY_ALIASES.get(ch, ch)
                    for ch in S.normalize_ellipsis(row["ko_text"].strip()))
    glyph_chars = sorted(ch for ch in used if ch in font)
    glyph_id = {ch: i for i, ch in enumerate(glyph_chars)}
    glyph_blob = bytearray()
    for ch in glyph_chars:
        offset = font[ch][0]
        glyph_blob += font_blob[offset:offset + GLYPH_BYTES]

    # 글리프 번호 -> 코드포인트.  런타임은 안 쓴다.  팩을 되읽어 글로 되돌릴 수
    # 있게 하려고 넣는다 -- 검증기와 Lua 로그가 이것으로 "지금 뭘 그리는지" 찍는다.
    # 한글·한영 기호는 전부 BMP 라 u16 이면 된다.
    char_blob = b"".join(struct.pack("<H", ord(ch)) for ch in glyph_chars)

    records = Records()
    overwidth: list[dict] = []
    over_capacity: list[dict] = []
    missing_chars: dict[str, int] = {}
    advance = {ch: metrics[1] for ch, metrics in font.items()}

    def displayable(text: str) -> str:
        """원문 -> 그릴 수 있는 글자만 남은 문장.  빠진 글자는 세어 둔다."""
        shown, dropped = S.display_text(text, font)
        for ch in dropped:
            missing_chars[ch] = missing_chars.get(ch, 0) + 1
        return shown

    def make_record(text: str, kind: str, seconds: float, where: str,
                    text_y: int) -> tuple[int, int]:
        """**표시용** 문장 하나를 기록으로 만든다 (한 줄에 들어간다고 보고)."""
        cells, width = layout(text, font)
        if not cells or len(cells) > ENGINE_MAX_CELLS:
            over_capacity.append({"where": where, "cells": len(cells),
                                  "limit": ENGINE_MAX_CELLS, "width_px": width,
                                  "ko_text": text})
            # 넘친 줄을 그대로 실으면 엔진이 스무 번째부터 글자를 조용히 버리고
            # 가운데맞춤도 어긋난다.  빼기로 했으면 기록 자체를 안 만들고 색인에서도
            # 빠지도록 -1 을 돌려준다 (2026-09-02).
            if skip_oversize:
                return -1, width
        elif width > LIMIT_PX or len(cells) > LIMIT_CELLS:
            overwidth.append({"where": where, "width_px": width,
                              "over_px": width - LIMIT_PX, "chars": len(text),
                              "ko_text": text})
        flags = 1 if kind == "대사" else 0
        packed = [(glyph_id[ch], x) for ch, x in cells]
        return records.add(packed, width, flags, int(seconds * 60), text_y), width

    # ---- CD-DA 색인.  구간 시작 LBA + 조각의 상대 시각 = 절대 LBA ----
    #
    # 나레이션에는 한 줄에 안 들어가는 문장이 있다 (실측 최대 32 칸).  엔진은
    # 운용 한도 16 칸에서 **나눠서** 각 조각에 제 시간 창을 준다.  창은 원래
    # 구간 **안에서만** 쪼개므로 이웃과 새로 겹칠 일이 없다.  글자 수에 비례해
    # 나눠 긴 조각이 더 오래 떠 있게 한다.
    segments = {r["clip"]: r for r in read_tsv(SEGMENTS)}

    # ★★ 자막 시간은 **트랙 기준 절대시각**이다 (2026-08-31).
    #
    # 예전에는 clip 안에서 0 초부터 셌다.  그러면 트랙 통짜를 들으며 싱크를 맞출
    # 수가 없다 -- 어디까지가 한 음성인지도 안 보인다.  1 트랙 = 1 음성이고 자막은
    # 그 안에 종속된다 (소유자 2026-08-31).
    #
    # LBA 는 트랙 안에서 정확히 선형이다 (75 섹터/초, 19 트랙 전부 검산).  그래서
    # 트랙마다 기준점 하나만 잡으면 절대시각에서 바로 환산된다:
    #
    #     track_base = clip.lba_from - clip.start_sec * 75
    #     lba        = track_base + 자막.start_sec * 75
    track_base, track_limit = S.cdda_track_spans(segments)

    cdda_index: list[tuple[int, int, int, int]] = []
    orphan_clips: set[str] = set()
    split_lines, split_extra = 0, 0
    for row in cdda_rows:
        track = (row.get("track") or "").strip()
        duration = float(row.get("duration_sec") or 0)
        window = S.cdda_window(row, segments, track_base, track_limit)
        if window is None:
            orphan_clips.add(track or row.get("clip") or "?")
            continue
        lba_from, lba_to = window
        kind = (row.get("kind") or "").strip()
        where = f"트랙 {track} 조각 {row.get('part') or '?'}"
        text = displayable(row["ko_text"].strip())
        chunks = S.split_line(text, advance)
        if not chunks:
            over_capacity.append({"where": where, "cells": 0,
                                  "limit": ENGINE_MAX_CELLS, "width_px": 0,
                                  "ko_text": row["ko_text"].strip()})
            continue
        windows = S.portion(lba_from, lba_to, [len(c) for c in chunks])
        if windows is None:
            raise SystemExit(
                f"CD-DA 자막을 나눌 수 없다: {where} 는 {len(chunks)} 조각인데 "
                f"구간이 {lba_to - lba_from} 섹터뿐이다 ({duration:.2f} s).\n"
                f"    {row['ko_text'].strip()}\n"
                "    원본 표의 duration_sec 를 늘리거나 문장을 줄일 것")
        if len(chunks) > 1:
            split_lines += 1
            split_extra += len(chunks) - 1
        cells_total = sum(len(chunk) for chunk in chunks)
        for i, (chunk, window) in enumerate(zip(chunks, windows)):
            # 한 조각뿐이면 예전과 **똑같이** 원본 duration 을 쓴다 -- 나누지
            # 않은 줄의 기록이 한 프레임도 달라지지 않게.
            seconds = (duration if len(chunks) == 1
                       else duration * len(chunk) / cells_total)
            label = where if len(chunks) == 1 else f"{where} ({i + 1}/{len(chunks)})"
            offset, _ = make_record(chunk, kind, seconds, label,
                                    pos_y(row.get("pos"), "cdda"))
            if offset < 0:
                continue
            cdda_index.append((window[0], window[1], offset,
                               1 if kind == "대사" else 0))
    cdda_index.sort(key=lambda e: (e[0], e[1]))

    # 이웃과 한 섹터 겹치는 것을 잘라 낸다 (규칙은 subtitle_split 에 한 곳)
    cdda_index = S.trim_cdda_overlaps(cdda_index)

    overlaps = sum(1 for a, b in zip(cdda_index, cdda_index[1:]) if b[0] < a[1])

    # ---- ADPCM 색인.  한 음성 키가 여러 조각으로 나뉜다 ----
    #
    # 조각마다 항목을 하나씩 낸다.  (지문, 시작프레임) 으로 정렬하면 한 음성의
    # 조각들이 **붙어 있게** 되므로, 런타임은 첫 항목을 찾은 뒤 지문이 같은 동안
    # 앞으로 걸어가기만 하면 된다.  사슬을 따로 만들 필요가 없다.
    #
    # 섹터는 콘솔에서 볼 수 없으므로 voice_console_keys.tsv가 제공하는
    # end/rate/ADPCM RAM 표본 3 B를 쓴다. 원본 자막표와 싱크 값은 읽기만 한다.
    console_map: dict[str, bytes] = {}
    for row in read_tsv(VOICE_CONSOLE_KEYS):
        text = (row.get("runtime_key_hex") or "").strip()
        if not text:
            continue
        try:
            key_bytes = bytes.fromhex(text)
        except ValueError:
            raise SystemExit(f"잘못된 콘솔 키: {row.get('key')} = {text}")
        if len(key_bytes) != 6:
            raise SystemExit(f"콘솔 키가 6 B가 아니다: {row.get('key')} = {text}")
        console_map[row["key"]] = key_bytes

    by_event: dict[str, list[dict]] = {}
    for row in voice_rows:
        by_event.setdefault(row["key"], []).append(row)

    # 서로 다른 자막 음성이 같은 런타임 키면 잘못된 자막이 뜨므로 빌드를 멈춘다.
    runtime_owners: dict[bytes, set[str]] = {}
    unmatched_events: set[str] = set()
    for old_key in by_event:
        runtime_key = console_map.get(old_key)
        if runtime_key is None:
            unmatched_events.add(old_key)
            continue
        runtime_owners.setdefault(runtime_key, set()).add(old_key)
    ambiguous_keys = {key: owners for key, owners in runtime_owners.items()
                      if len(owners) > 1}
    if ambiguous_keys:
        detail = "; ".join(
            f"{key.hex(' ').upper()}={'/'.join(sorted(owners))}"
            for key, owners in sorted(ambiguous_keys.items()))
        # 콘솔 키는 end_addr 2 B + rate 1 B + ADPCM RAM 표본 3 B 다.  1,211 음성에
        # end_addr 이 34 종뿐이라 뼈대가 얇고, 식별이 표본 3 B 에 걸려 있다.
        # 2026-09-02 에 표본 자리를 옮겨 고치려 했으나 안 된다 (그쪽 주석 참고).
        #
        # 기본은 fail-closed -- 구분이 안 되는 음성에 자막을 실으면 **엉뚱한
        # 자막이 뜬다**.  `--skip-collisions` 는 그 무리만 빼고 나머지를 굽는다.
        # (안전자리가 없으면 자막을 안 넣는 정책과 같은 결이다.)
        # 2026-09-02: 두 층으로 나눈다.  런타임이 LBA 디렉터리를 먼저 고르므로,
        # 충돌한 음성들이 서로 다른 LBA 면 실제로는 갈린다.
        lba_of = voice_start_lba()
        unresolved = {}
        for key, owners in ambiguous_keys.items():
            lbas = [lba_of.get(o) for o in owners]
            if any(x is None for x in lbas) or len(set(lbas)) < len(owners):
                unresolved[key] = owners
        resolved = len(ambiguous_keys) - len(unresolved)
        print(f"  런타임 키 충돌 {len(ambiguous_keys)} 쌍"
              f" · LBA 로 갈림 {resolved} · 미해결 {len(unresolved)}")
        collision_stats = {"runtime_key_collisions": len(ambiguous_keys),
                           "resolved_by_lba": resolved,
                           "unresolved_lba_collisions": len(unresolved)}
        if unresolved:
            detail2 = "; ".join(
                f"{key.hex(' ').upper()}={'/'.join(sorted(owners))}"
                for key, owners in sorted(unresolved.items()))
            if not skip_collisions:
                raise SystemExit(
                    "LBA 로도 못 가르는 콘솔 키 충돌: " + detail2
                    + "\n  같은 LBA 에 두 음성이 있다.  빼고 구우려면 --skip-collisions")
            dropped_keys = {k for owners in unresolved.values() for k in owners}
            dropped = sum(len(by_event[k]) for k in dropped_keys if k in by_event)
            print(f"  LBA 로도 못 가르는 음성 {len(dropped_keys)} 개를 건너뛴다"
                  f" -- 자막 조각 {dropped} 개가 안 실린다  ({detail2})")
            for k in dropped_keys:
                by_event.pop(k, None)
    if unmatched_events:
        # 콘솔 키는 voice_console_keys.tsv 의 `runtime_key_hex` (end_addr 2 B +
        # rate 1 B + ADPCM RAM 표본 3 B) 에서만 나온다.  그 표에 없는 음성은
        # 아직 수집이 안 된 것이다.  **기본은 fail-closed** -- 없는 키를 지어내
        # 다른 음성 자리를 선점하면 엉뚱한 자막이 뜬다.
        #
        # 다만 그 음성 하나 때문에 디스크를 아예 못 굽는 것도 곤란하다.
        # `--skip-keyless` 는 그 음성만 빼고 나머지를 굽는다 (2026-09-02).
        if not skip_keyless:
            raise SystemExit(
                "콘솔 키를 만들 수 없는 자막 음성 %d 개: %s%s"
                "  --  수집이 안 된 음성이다.  그것만 빼고 구우려면 --skip-keyless"
                % (len(unmatched_events), ", ".join(sorted(unmatched_events)[:20]),
                   " ..." if len(unmatched_events) > 20 else ""))
        dropped = sum(len(by_event[k]) for k in unmatched_events)
        print("  콘솔 키 없는 음성 %d 개를 건너뛴다 -- 자막 조각 %d 개가 안 실린다"
              % (len(unmatched_events), dropped))
        for key in unmatched_events:
            by_event.pop(key, None)

    # ADPCM 은 **나누지 않는다.**  CD-DA 는 LBA 창이라 쪼개도 런타임이 그대로
    # 범위 검색을 하지만, ADPCM 조각은 (지문, 시작프레임) 으로 이어 달리는
    # 경로이고 그 다중 조각 경로는 아직 고치는 중이다
    # (docs/handoff/SNATCHER_VOICE_SUBTITLE_RUNTIME_2026-08-28.md).
    # 여기서 조각을 새로 만들어 넣으면 그 문제를 키운다.  지금 실측 최대는
    # 16 칸이라 나눌 것도 없고, 넘치면 아래 관문이 빌드를 멈춘다.
    adpcm_index: list[tuple[bytes, int, int, int]] = []
    dropped_parts = 0
    for event_id, parts_unsorted in by_event.items():
        key = console_map[event_id]
        kind = (voice_meta.get(event_id, {}).get("kind") or "").strip()
        parts = sorted(parts_unsorted, key=lambda r: float(r.get("start_sec") or 0))
        for row in parts:
            start = float(row.get("start_sec") or 0)
            duration = float(row.get("duration_sec") or 0)
            offset, _ = make_record(displayable(row["ko_text"].strip()), kind,
                                    duration,
                                    f"{event_id} 조각 {row.get('part') or '?'}",
                                    pos_y(row.get("pos"), "adpcm"))
            if offset < 0:
                continue
            frame = int(start * 60)
            if frame > 0xFFFF:
                dropped_parts += 1
                continue
            adpcm_index.append((key, frame, 1 if kind == "대사" else 0,
                                offset, event_id))
    adpcm_index.sort(key=lambda e: (e[0], e[1]))

    # ---- 엔진이 못 그리는 기록이 하나라도 있으면 여기서 멈춘다 ----
    #
    # 예전에는 넘쳐도 pack_overwidth.tsv 에 적고 넘어갔다.  경고는 아무도 안 읽고
    # 팩만 봐서는 표가 안 난다.  실제로 엔진에서 일어나는 일은 둘 중 하나다:
    #
    #     19 칸 초과   `CMP #20 / LDA #19` 로 잘라내고 63 B 만 읽는다.  터지지는
    #                  않지만 스무 번째부터 글자가 조용히 사라지고, 줄 폭이 u8 을
    #                  넘어 (320 -> 255) 가운데맞춤도 어긋난다
    #     0 칸         글리프 루프가 do-while 이라 $15 가 $FF 로 돌아 256 번 돈다.
    #                  X 가 5 씩 늘며 `list` 를 넘어 `record`·`stage` 를 덮는다
    if over_capacity:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        with OVER_CAPACITY.open("w", encoding="utf-8", newline="") as fh:
            writer = csv.DictWriter(fh, delimiter="\t", lineterminator="\n",
                                    fieldnames=["where", "cells", "limit",
                                                "width_px", "ko_text"])
            writer.writeheader()
            writer.writerows(sorted(over_capacity, key=lambda r: -r["cells"]))
        lines = "\n".join(f"    {r['where']}  {r['cells']} 칸  {r['ko_text'][:32]}"
                          for r in sorted(over_capacity,
                                          key=lambda r: -r["cells"])[:10])
        if skip_oversize:
            print(f"  엔진 한도({ENGINE_MAX_CELLS}칸)를 넘는 자막 {len(over_capacity)} 개를 뺐다"
                  f"  --  목록: {OVER_CAPACITY}")
        else:
            raise SystemExit(
                f"엔진이 못 그리는 기록 {len(over_capacity)} 개 -- 한 줄은 1..{ENGINE_MAX_CELLS} 칸이다\n"
                f"{lines}\n"
                f"    전체 목록: {OVER_CAPACITY}\n"
                "    CD-DA 는 빌더가 알아서 나눈다.  여기 남았다면 ADPCM 쪽이므로\n"
                "    voice_subtitles_keyed.tsv 에서 문장을 조각으로 쪼갤 것")
    if not over_capacity and OVER_CAPACITY.exists():
        OVER_CAPACITY.unlink()

    # ---- 배치.  머리 64 B -> ADPCM 색인 -> CD-DA 색인 -> 기록 -> 글리프 ----
    adpcm_off = HEADER_BYTES
    adpcm_bytes = len(adpcm_index) * ADPCM_STRIDE
    cdda_off = adpcm_off + adpcm_bytes
    cdda_bytes = len(cdda_index) * CDDA_STRIDE
    record_off = cdda_off + cdda_bytes
    glyph_off = record_off + len(records.blob)
    char_off = glyph_off + len(glyph_blob)
    total = char_off + len(char_blob)

    header = bytearray(HEADER_BYTES)
    struct.pack_into("<4sHH", header, 0, MAGIC, VERSION, 0)
    struct.pack_into("<HI", header, 8, len(glyph_chars), glyph_off)
    struct.pack_into("<HI", header, 14, len(adpcm_index), adpcm_off)
    struct.pack_into("<HI", header, 20, len(cdda_index), cdda_off)
    struct.pack_into("<II", header, 26, record_off, total)
    struct.pack_into("<BBH", header, 34, GLYPH_BYTES, CELL_BYTES, LIMIT_PX)
    struct.pack_into("<I", header, 38, char_off)
    # 항목 크기를 머리에 적어 둔다.  런타임이 판마다 상수를 새로 박지 않게.
    struct.pack_into("<BBBB", header, 42, ADPCM_STRIDE, CDDA_STRIDE, REC_HEADER, 0)

    blob = bytearray(header)
    for runtime_key, start_frame, flags, offset, _owner in adpcm_index:
        blob += runtime_key
        blob += struct.pack("<BHI", flags, start_frame, offset)
    for lba_from, lba_to, offset, flags in cdda_index:
        blob += struct.pack("<I", lba_from)[:3]
        blob += struct.pack("<I", lba_to)[:3]
        blob += struct.pack("<I", offset)[:3]
        blob += bytes([flags])
    blob += records.blob
    blob += glyph_blob
    blob += char_blob

    if len(blob) != total:
        raise SystemExit(f"배치가 어긋났다: 계산 {total} · 실제 {len(blob)}")
    if total > AC_RESERVE:
        raise SystemExit(f"팩 자리를 넘겼다: {total} B > {AC_RESERVE} B "
                         f"(${AC_BASE:06X}).  tools/subtitle_layout.py 를 볼 것")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    PACK_BIN.write_bytes(bytes(blob))

    # ★ 항목 위치 -> 주인 음성 (2026-09-02).
    #   팩 항목은 6 B 런타임 키만 들고 있어서, 키가 겹치는 음성 둘의 조각이
    #   나중에 한 뭉치로 섞인다 (build_adpcm_native_subtitle_table 의
    #   groups[entry[:6]]).  event_id 는 sector 가 든 **고유** 키이므로
    #   그것을 옆에 적어 두면 표 빌더가 음성별로 정확히 나눌 수 있다.
    #   팩 바이너리는 한 바이트도 안 바뀐다 -- 형식·스트라이드 그대로다.
    owner_tsv = PACK_BIN.parent / "adpcm_index_owner.tsv"
    lines = ["index_pos\tevent_id\truntime_key"]
    for i, (key, _frame, _flags, _off, owner) in enumerate(adpcm_index):
        lines.append(f"{i}\t{owner}\t{key.hex().upper()}")
    owner_tsv.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"  항목 주인표 {len(adpcm_index):,} 행 -> {owner_tsv.name}")
    with ADPCM_COLLISIONS.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh, delimiter="\t")
        writer.writerow(["runtime_key_hex", "voice_key_count", "voice_keys"])
        for key, owners in sorted(ambiguous_keys.items()):
            writer.writerow([key.hex(" ").upper(), len(owners),
                             ",".join(sorted(owners))])
    manifest = {
        "magic": MAGIC.decode(), "version": VERSION,
        "ac_base": AC_BASE, "ac_reserve": AC_RESERVE,
        "ac_layout": {name: {"at": f"{at:06X}", "max": size}
                      for name, at, size in L.regions()},
        "pack_bytes": total, "header_bytes": HEADER_BYTES,
        "glyph": {"count": len(glyph_chars), "offset": glyph_off,
                  "bytes_each": GLYPH_BYTES, "chars": "".join(glyph_chars)},
        "char_table": {"offset": char_off, "bytes_each": 2,
                       "entry": "codepoint u16 · 글리프 번호와 같은 순서",
                       "note": "런타임은 안 쓴다 -- 팩을 글로 되돌리기 위한 것"},
        "adpcm_index": {"count": len(adpcm_index), "offset": adpcm_off,
                        "bytes_each": ADPCM_STRIDE,
                        "entry": "runtime_key 6 B · flags u8 · start_frame u16 · rec_off u32",
                        "key": "end_addr u16 LE + rate u8 + ADPCM RAM samples at end/4,end/2,5*end/8",
                        "sorted_by": "지문 · start_frame -- 한 이벤트의 조각들이 붙어 있다"},
        "adpcm_safety": {"ambiguous_keys": len(ambiguous_keys),
                         "blocked_subtitle_events": 0,
                         "policy": "build fails if two subtitled voices share a runtime key",
                         "report": str(ADPCM_COLLISIONS.relative_to(ROOT))},
        "cdda_index": {"count": len(cdda_index), "offset": cdda_off,
                       "bytes_each": CDDA_STRIDE,
                       "entry": "lba_from u24 · lba_to u24 · rec_off u24 · flags u8",
                       "sorted_by": "lba_from"},
        "records": {"offset": record_off, "bytes": len(records.blob),
                    "header": "cells u8 · width_px u8 · flags u8 · **y u8** · frames u16",
                    "cell": "glyph_id u16 · x u8"},
        "limit_px": LIMIT_PX, "positions": POSITIONS, "default_pos": DEFAULT_POS,
        "line_limits": {
            "cells": LIMIT_CELLS, "engine_max_cells": ENGINE_MAX_CELLS,
            "engine_safe_cells": S.SAFE_CELLS,
            "px": LIMIT_PX,
            "policy": "CD-DA lines over the cell limit are split into extra LBA "
                      "windows inside the original range; ADPCM lines are never "
                      "split and fail the build instead",
            "cdda_split_lines": split_lines,
            "cdda_split_extra_entries": split_extra,
            "rule": str(Path("tools/subtitle_split.py")),
        },
    }
    PACK_JSON.write_text(json.dumps(manifest, ensure_ascii=False, indent=2),
                         encoding="utf-8")

    if overwidth:
        overwidth.sort(key=lambda r: -r["over_px"])
        with OVERWIDTH.open("w", encoding="utf-8", newline="") as fh:
            writer = csv.DictWriter(fh, delimiter="\t", lineterminator="\n",
                                    fieldnames=["where", "width_px", "over_px",
                                                "chars", "ko_text"])
            writer.writeheader()
            writer.writerows(overwidth)
    elif OVERWIDTH.exists():
        OVERWIDTH.unlink()

    # ---- 보고 ----
    print(f"자막 팩 {total:,} B  ({total * 100 // AC_RESERVE}% of {AC_RESERVE // 1024} KB 팩 영역 · ${AC_BASE:06X})")
    print(f"  머리      {HEADER_BYTES:>7,} B")
    print(f"  ADPCM 색인 {adpcm_bytes:>6,} B   {len(adpcm_index):>4} 조각  ({len(by_event)} 음성)")
    print(f"  CD-DA 색인 {cdda_bytes:>6,} B   {len(cdda_index):>4} 개"
          + (f"   ★ 구간 겹침 {overlaps}" if overlaps else "   겹침 없음")
          + (f"   나눈 줄 {split_lines} (+{split_extra} 항목)" if split_lines else ""))
    print(f"  기록      {len(records.blob):>7,} B   {len(records.seen):>4} 개 (같은 글은 한 번)")
    print(f"  글리프    {len(glyph_blob):>7,} B   {len(glyph_chars):>4} 자"
          f"  (전체 {len(font)} 자 중)")
    print(f"  {PACK_BIN}")
    print(f"  {PACK_JSON}")

    if unmatched_events:
        print(f"  ★ 이벤트를 못 찾은 자막 {len(unmatched_events)} 건: "
              + ", ".join(sorted(unmatched_events)[:5]))
    if orphan_clips:
        print(f"  ★ 구간표에 없는 클립 {len(orphan_clips)} 개: "
              + ", ".join(sorted(orphan_clips)[:5]))
    if missing_chars:
        worst = sorted(missing_chars.items(), key=lambda kv: -kv[1])[:10]
        print(f"  ★ 글꼴에 없어 빠진 글자 {len(missing_chars)} 종: "
              + " ".join(f"{ch}({n})" for ch, n in worst))
    if overwidth:
        print(f"  ★ 폭이 넘친 자막 {len(overwidth)} 개 (한 줄 {LIMIT_PX} px 초과)")
        for row in overwidth[:3]:
            print(f"      {row['where']}  {row['width_px']} px  {row['ko_text'][:24]}")
        print(f"      전체 목록: {OVERWIDTH}  -- 스튜디오에서 쪼개면 된다")


if __name__ == "__main__":
    main()
