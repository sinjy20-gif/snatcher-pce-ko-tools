#!/usr/bin/env python3
"""한글 -> BIOS 글리프 자리(JIS 행/셀) 배정표.

왜 필요한가
-----------
BIOS 폰트 경로는 한글을 시스템 카드 글리프로 그린다.  지금 `_bios_hangul_bytes` 는
한글을 EUC-KR 로 바꿔 산술 변환하는데, 그러면 JIS 행 0x30~0x48 -- **상용한자 자리**로
간다.  거기 갈무리를 얹으면 한자가 죽고, 미번역 일본어가 깨져 보인다 (해태 한글 카드가
정확히 그 상태다).

그런데 게임은 한자 행마다 94칸 중 30~50칸만 쓴다.  **안 쓰는 칸에만 넣으면 한자가
안 죽는다.**

    게임이 쓰는 (행,셀)   1,639
    번역이 쓰는 한글        713
    빈 칸                 1,300 여

배정 원칙
---------
    1. 게임이 한 번도 안 쓴 칸만 쓴다
    2. 한자 행(0x30~0x47)의 빈 칸을 쓴다
    3. **이미 배정된 글자는 안 옮긴다.**  새 글자만 남은 칸에 덧붙인다
       -- 단 그 자리가 "게임이 쓴다" 로 새로 밝혀지면 그때는 옮긴다 (4)
    4. 충돌한 배정은 재배정한다.  BIOS 도 디스크도 이 표에서 매번 다시 나오므로
       둘을 같이 다시 만들면 정합이 유지된다.  **섞어 쓰면 안 된다.**

0x29~0x2F 는 못 쓴다 (2026-08-18 확정).  BIOS $F22F/$F231 이 `CMP #$30 / BCC` 로
행 0x28~0x2F 를 그대로 거부한다 -- JIS 미할당이라 글리프가 없고 BIOS 가 표를 압축해
쓰기 때문이다.  이전 판의 SAFE_ROWS 는 성립하지 않는 선택지였다.

"게임이 쓰는 칸" 을 어디까지 아는가
-----------------------------------
정적으로는 완전히 알 수 없다 (2026-08-18 실측).

    TSV 코퍼스 4 개의 jp 열          -- 추출된 것만.  `鎧`(8A5A) 가 여기 없다
    원본 Track 02 의 FF-종결 문자열   -- 1,063 글리프.  그래도 `鎧` 는 안 잡힌다
    MODE1 데이터 트랙은 Track 02 하나 -- 더 훑을 데가 없다

그래서 근거를 세 겹으로 쌓는다: TSV + 디스크 스캔 + **런타임 관측**.  마지막 것이
유일하게 확실한 출처다 (EX_GETFNT 에 실제로 들어간 코드).  관측이 늘면
`observed_used.tsv` 에 SJIS 를 한 줄씩 더하고 다시 돌리면 된다.

행표 유효 범위
--------------
ROM $0127E 부터 16 비트 LE.  증분이 94 로 이어지다 0x48 에서 깨진다.

    유효 0x21 ~ 0x47 (39행) · 전체 글리프 3,461
    글리프 base $030000 · stride 18 (12x12 팩)

    python build_bios_hangul_map.py            보고만
    python build_bios_hangul_map.py --write    배정표 기록
"""
from __future__ import annotations
import argparse, csv, sys, collections
from pathlib import Path

ROOT = Path(r"C:\snatcher")
TR = ROOT / "snatcher_tool" / "translation"
BIOS = ROOT / "Mesen_2.2.1_Windows" / "Firmware" / "[BIOS] Super CD-ROM System (Japan) (v3.0).pce.JP_ORIGINAL"
OUT = ROOT / "build" / "bios_font" / "hangul_slot_map.tsv"
# 원본 디스크의 유일한 MODE1 트랙.  게임 원문 스캔은 여기서만 나온다
SOURCE_TRACK02 = (ROOT / "rom(japan)" / "Snatcher CD-ROMantic (Japan)"
                  / "Snatcher CD-ROMantic (Japan) (Track 02).bin")
# 런타임에서 실제로 EX_GETFNT 에 들어간 것이 관측된 SJIS.  한 줄에 하나, 주석은 #
OBSERVED = ROOT / "build" / "bios_font" / "observed_used.tsv"
RAW_SECTOR, USER_OFFSET, USER_BYTES = 2352, 16, 2048

ROW_TABLE = 0x0127E
ROW_FIRST, ROW_LAST = 0x21, 0x47      # 실측 유효 범위
CELLS = 94
GLYPH_BASE, GLYPH_STRIDE = 0x030000, 18
# 배정 우선순위 -- **변환이 확실한 자리를 먼저** 쓴다.
#
# 한자 행(0x30~0x47)의 빈 칸은 정상 JIS 코드점이라 BIOS 의 SJIS->JIS 변환($F1E3)이
# 반드시 통과시킨다.  게임이 그 글자를 안 쓸 뿐이다.
#
# 반면 0x29~0x2F 는 JIS 미할당 영역이다.  한자를 아예 안 건드린다는 장점이 있지만
# 변환기가 그 행을 거부하는지 확인하지 못했다.  **넘칠 때만** 쓴다.
KANJI_ROWS = range(0x30, ROW_LAST + 1)
SAFE_ROWS = range(0x29, 0x30)

csv.field_size_limit(min(sys.maxsize, 2**31 - 1))
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def read_tsv(path):
    for enc in ("utf-8-sig", "utf-16"):
        try:
            rows = list(csv.reader(open(path, encoding=enc, newline=""), delimiter="\t"))
            if rows and len(rows[0]) > 1:
                return {n: k for k, n in enumerate(rows[0])}, rows[1:]
        except Exception:
            pass
    return {}, []


def jis_of(ch):
    """SJIS 문자 -> (JIS 행, 셀).  BIOS $F1E3 이 하는 변환과 같은 규칙."""
    try:
        s = ch.encode("shift_jis")
    except Exception:
        return None
    if len(s) != 2:
        return None
    s1, s2 = s
    if s1 >= 0xE0:
        s1 -= 0x40
    s1 -= 0x81
    if s2 >= 0x80:
        s2 -= 1
    s2 -= 0x40
    return (s1 * 2 + 0x21 + (1 if s2 >= CELLS else 0), (s2 % CELLS) + 0x21)


def _build_sjis_table():
    """(JIS 행, 셀) -> SJIS 2 바이트 표를 **전수 열거로** 만든다.

    역함수를 손으로 쓰면 안 된다.  2026-08-18 에 그렇게 했다가 한자행 1,128 조합이
    어긋났고, 글리프는 인덱스 N 에 쓰였는데 코덱은 N-1 을 가리키는 코드를 내보내
    **한 글자도 안 나왔다.**  절반은 아예 유효하지 않은 SJIS 였다.

    원인은 SJIS 저바이트가 0x7F 를 건너뛰는 것이다 (`if s2 >= 0x80: s2 -= 1`).
    정방향에는 있었고 역방향에서 빠졌다.

    그래서 정방향 산술을 모든 유효 SJIS 조합에 돌려서 표를 얻는다.  왕복 검증
    11,280 조합 · 불일치 0.
    """
    table = {}
    for s1 in list(range(0x81, 0xA0)) + list(range(0xE0, 0xFD)):
        for s2 in list(range(0x40, 0x7F)) + list(range(0x80, 0xFD)):
            a, c = s1, s2
            if a >= 0xE0:
                a -= 0x40
            a -= 0x81
            if c >= 0x80:
                c -= 1
            c -= 0x40
            row = a * 2 + 0x21 + (1 if c >= CELLS else 0)
            cell = (c % CELLS) + 0x21
            table.setdefault((row, cell), bytes((s1, s2)))
    return table


_SJIS_TABLE = _build_sjis_table()


def sjis_of(row, cell):
    return _SJIS_TABLE.get((row, cell))


def glyph_index(row, cell, table):
    """(JIS 행, 셀) -> 글리프 인덱스.  **BIOS 가 실제로 하는 계산.**

    코드는 `행표[row-0x21] + (cell-0x21)` 로 보이지만 한자 구간에서 관측값이
    752(= 8행 x 94) 씩 어긋난다.  $F222 부근이 **행 0x28~0x2F 를 거부**하기
    때문이다 -- 그 8행은 JIS 미할당이라 글리프가 없고 BIOS 가 표를 압축해 쓴다.

    프로브 관측으로 역산 (한자 표본 5/5 일치):
        受 행3C -> 행표[0x34]    嬢 행3E -> 행표[0x36]    鎧 행33 -> 행표[0x2B]

    행 0x23/0x26/0x27 은 $F1E3 에 특수 분기가 있어 규칙이 다르다 -> 안 쓴다.
    """
    if row in (0x23, 0x26, 0x27):
        return None
    if 0x28 <= row <= 0x2F:
        return None
    lookup = row - 8 if row >= 0x30 else row
    i = lookup - ROW_FIRST
    if not (0 <= i < len(table)):
        return None
    return table[i] + (cell - 0x21)


def row_table():
    rom = BIOS.read_bytes()
    return [rom[ROW_TABLE + i * 2] | (rom[ROW_TABLE + i * 2 + 1] << 8)
            for i in range(ROW_LAST - ROW_FIRST + 1)]


def game_used():
    """게임이 화면에 내는 모든 원문에서 (행,셀) 을 모은다."""
    used = set()
    for name in ("legacy_static_master.tsv", "snatcher_ko_master.tsv", "ui_text.tsv",
                 "speaker_name_standard.tsv"):
        ix, rows = read_tsv(TR / name)
        for col in ("jp_text", "jp_name"):
            if col not in ix:
                continue
            for r in rows:
                if len(r) > ix[col]:
                    for ch in r[ix[col]]:
                        j = jis_of(ch)
                        if j:
                            used.add(j)
    return used


def disc_used(table):
    """원본 Track 02 에서 **FF 로 끝나는 문자열 런**만 골라 글리프 인덱스를 모은다.

    원시 바이트 개수는 못 쓴다 -- `鎧`(8A5A) 는 그렇게 세면 846 회 나오지만 대부분
    코드/그래픽이다.  게임의 문자열은 두 바이트 SJIS 가 이어지다 FF 로 끝나고
    (FD 개행 · FE xx 파라미터가 중간에 낀다), 그 형태만 받으면 노이즈가 걸러진다.

        FF 로 끝난 런 5,843 개 · 서로 다른 문자 1,544 · 글리프 1,063  (실측)

    완전하지는 않다.  이 스캔으로도 `鎧` 는 안 잡힌다 -- 그래서 OBSERVED 가 있다.
    """
    if not SOURCE_TRACK02.exists():
        print(f"★ 원본 Track 02 가 없다: {SOURCE_TRACK02}  -- 디스크 스캔을 건너뛴다")
        return set()
    raw = SOURCE_TRACK02.read_bytes()
    data = bytearray()
    for s in range(len(raw) // RAW_SECTOR):
        start = s * RAW_SECTOR + USER_OFFSET
        data += raw[start:start + USER_BYTES]

    chars, run, i, n = set(), [], 0, len(data)
    while i < n:
        byte = data[i]
        if byte == 0xFF:                       # 문자열 끝
            if len(run) >= 2:
                chars |= set(run)
            run, i = [], i + 1
            continue
        if byte == 0xFD:                       # 개행
            i += 1
            continue
        if byte == 0xFE:                       # 파라미터 1 바이트
            i += 2
            continue
        pair = None
        if i + 1 < n and (0x81 <= byte <= 0x9F or 0xE0 <= byte <= 0xEA):
            low = data[i + 1]
            if 0x40 <= low <= 0xFC and low != 0x7F:
                try:
                    pair = bytes((byte, low)).decode("cp932")
                except Exception:
                    pair = None
        if pair is None:
            run, i = [], i + 1                 # 텍스트가 아니었다.  런을 버린다
            continue
        run.append(pair)
        i += 2

    out = set()
    for ch in chars:
        j = jis_of(ch)
        if j:
            index = glyph_index(j[0], j[1], table)
            if index is not None:
                out.add(index)
    return out


def observed_used(table):
    """런타임에서 실제로 그려진 것이 관측된 SJIS -> 글리프 인덱스.

    유일하게 확실한 출처다.  프로브(PROBE_FONT_ADDR / PROBE_KANA_FONT)가 찍은
    코드를 여기 적어두면 그 자리는 다시는 배정되지 않는다.
    """
    out = set()
    if not OBSERVED.exists():
        return out
    for line in OBSERVED.read_text(encoding="utf-8").splitlines():
        line = line.split("#")[0].strip().replace(" ", "")
        if not line:
            continue
        try:
            raw = bytes.fromhex(line)
        except ValueError:
            continue
        if len(raw) != 2:
            continue
        try:
            ch = raw.decode("cp932")
        except Exception:
            continue
        j = jis_of(ch)
        if j:
            index = glyph_index(j[0], j[1], table)
            if index is not None:
                out.add(index)
    return out


EXTRA_SYMBOLS = "…"


def needed_hangul():
    """번역이 실제로 화면에 내보내는 모든 한글.

    2026-08-18 까지 이 함수는 `snatcher_ko_master.tsv` 하나만 읽었다.  그래서
    UI 라벨·화자 이름·구형 정적 문자열의 한글 69 자(등장 118 회)가 배정 없이
    남았고, 코덱이 산술 폴백으로 떨어뜨려 **한자로 출력됐다**:

        몽타주 -> 功타주 · 얼굴 윤곽 -> 얼굴 星곽 · 암시장 -> 章시장

    **출하되는 행만** 센다.  전체를 세면 995 자가 나와 빈 칸(966)을 넘어선다 --
    그런데 빌더가 싣는 것은 검수를 통과한 행뿐이다 (`BODY reviewed` / `UI review=O`).
    검수 안 된 초벌까지 자리를 잡아두면, 정작 출하되는 글자가 밀려 못 들어간다.

    검수 규칙은 빌더와 같은 모듈을 그대로 부른다 -- 규칙이 갈라지면 배정표와
    디스크가 어긋나고, 그것이 정확히 이번에 하루를 태운 종류의 버그다.
    """
    sys.path.insert(0, str(ROOT / "extraction" / "translation"))
    sys.path.insert(0, str(ROOT / "extraction" / "patch" / "static"))
    import build_full_overlay_layout as layout          # noqa: E402
    from tsv_io import read_dict_rows                   # noqa: E402

    need = set()

    def take(text):
        need.update(c for c in text or "" if "가" <= c <= "힣")

    # BODY -- 검수 O 인 행만 (빌더 :433 과 같은 호출)
    selected, exceptions = layout.reviewed_row_ids(TR / "snatcher_ko_master.tsv")
    keys = selected | exceptions
    ix, rows = read_tsv(TR / "snatcher_ko_master.tsv")
    for r in rows:
        if len(r) <= max(ix["ko_text"], ix["text_key"], ix["line_no"]):
            continue
        try:
            key = (r[ix["text_key"]], int(r[ix["line_no"]]))
        except ValueError:
            continue
        if key in keys:
            take(r[ix["ko_text"]])

    # UI -- review 열이 O 이고 status 가 skip 이 아닌 행 (빌더 :435)
    ui_header, ui_rows = read_dict_rows(TR / "ui_text.tsv")
    review = layout.ui_review_column(ui_header)
    for r in ui_rows:
        if r.get("ko_text", "").strip() and r.get("status", "") != "skip" \
                and layout.is_ui_reviewed(r, review):
            take(r["ko_text"])

    # 화자 이름은 전부 final 이고 UI 와 같은 레코드로 나간다
    ix, rows = read_tsv(TR / "speaker_name_standard.tsv")
    if "ko_name" in ix:
        for r in rows:
            if len(r) > ix["ko_name"]:
                take(r[ix["ko_name"]])

    # 한글이 아니지만 자리가 필요한 글자.
    #
    # '…' 는 BIOS 에도 있지만(8163) **가운데 세 점**이라 일본식이다.  한국어 본문은
    # 바닥에 깔리는 말줄임을 쓴다 -- 예전 F042 가 그렇게 손으로 그린 글자였고
    # (ellipsis_glyph: '바닥 한 줄 위, 왼쪽 치우침'), 2026-08-19 에 BIOS 것으로
    # 바꿨다가 소유자가 화면에서 바로 잡아냈다.  빈 칸을 하나 받아서 우리 모양으로
    # 그린다.  BIOS 의 8163 은 건드리지 않는다 -- 미번역 일본어가 그것을 쓴다.
    need.update(EXTRA_SYMBOLS)
    return need


def load_existing():
    if not OUT.exists():
        return {}
    ix, rows = read_tsv(OUT)
    out = {}
    for r in rows:
        if len(r) > ix["cell"]:
            out[r[ix["hangul"]]] = (int(r[ix["row"]], 16), int(r[ix["cell"]], 16))
    return out


def observed_glyph_indices(path, table):
    """관측 파일(`sjis	count	first_frame`)의 코드를 글리프 인덱스로 바꾼다.

    한글판으로 관측했으므로 **우리가 그 자리에 넣은 한글**도 같은 코드로 잡힌다.
    구분은 여기서 하지 않는다 -- 이 집합은 "보호에서 빼지 말 것" 쪽으로만 쓰이므로,
    우리 한글 자리가 섞여 들어와도 보수적으로 틀린다 (덜 놓아준다).
    """
    out = set()
    for line in Path(path).read_text(encoding="utf-8").splitlines()[1:]:
        if not line.strip():
            continue
        code = line.split("	")[0].replace(" ", "")
        try:
            raw = bytes.fromhex(code)
        except ValueError:
            continue
        if len(raw) != 2:
            continue
        index = glyph_index(raw[0], raw[1], table)
        if index is not None:
            out.add(index)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    # 2026-08-22: 엔딩까지 완주하며 EX_GETFNT 에 들어간 코드를 전부 기록했다
    # (runtime_text_audit 0.2.2, 고유 2,141 코드 / 37 만 호출).  그때까지 "게임이
    # 쓴다" 의 근거는 TSV 코퍼스 추정 1,701 자였는데, 그 추정에는 디스크 어딘가에
    # 글자가 있을 뿐 **화면에 한 번도 안 나오는** 한자가 섞여 있다.  그것이 자리를
    # 잡아먹어 빈 칸이 4 개까지 줄었다.
    #
    # 이 옵션은 **TSV 코퍼스 추정분에 한해** 관측에 없는 것을 보호에서 뺀다.
    # 디스크 스캔분과 관측분은 그대로 둔다 -- 셋 중 코퍼스가 제일 약한 근거다.
    #
    # 한 판으로는 선택지·조사 분기를 다 밟지 못한다 (관측된 것 중 195 자가 딱
    # 1 회만 그려졌다).  그래서 이것은 기본값이 아니고, 켜도 **필요한 만큼만**
    # 쓰라고 --free-limit 을 같이 둔다.
    ap.add_argument("--trust-observation", metavar="GLYPH_TSV",
                    help="관측 파일(dump/glyph_used_*.tsv)에 없는 코퍼스 추정분을 자리에서 놓아준다")
    args = ap.parse_args()

    table = row_table()
    used = game_used()
    need = sorted(needed_hangul())
    prior = load_existing()

    # 게임이 쓰는 자리는 (행,셀) 이 아니라 **글리프 인덱스**로 걸러야 한다.
    # 서로 다른 (행,셀) 이 같은 인덱스를 가리킬 수 있기 때문이다.
    used_idx = {glyph_index(r, c, table) for (r, c) in used}
    used_idx.discard(None)
    tsv_idx = set(used_idx)
    from_tsv = len(used_idx)
    used_idx |= disc_used(table)
    from_disc = len(used_idx) - from_tsv
    used_idx |= observed_used(table)
    from_probe = len(used_idx) - from_tsv - from_disc

    if args.trust_observation:
        seen_idx = observed_glyph_indices(Path(args.trust_observation), table)
        # 코퍼스 추정분 중 관측에 없는 것만 놓아준다.  디스크 스캔분·기존 관측분은
        # 다른 근거로도 보호되므로 여기서 빠져도 used_idx 에 남는다.
        freed = (tsv_idx - seen_idx) - disc_used(table) - observed_used(table)
        used_idx -= freed
        print(f"관측 기준 놓아준 코퍼스 추정 {len(freed):,} 자")

    print(f"게임이 쓰는 (행,셀)  {len(used):,}")
    print(f"  -> 글리프 인덱스   TSV {from_tsv:,} + 디스크 {from_disc:,} "
          f"+ 관측 {from_probe:,} = {len(used_idx):,}")
    print(f"번역이 쓰는 한글     {len(need):,}")
    print(f"기존 배정            {len(prior):,}")

    # 기존 배정 중 "게임이 쓴다" 로 새로 밝혀진 자리는 놓아준다.  안 옮기면
    # 그 한자가 한글로 덮여 미번역 일본어가 깨진다 (`鎧` 8A5A idx 761, 프로브 관측).
    conflicts = {ch for ch, (r, c) in prior.items()
                 if glyph_index(r, c, table) in used_idx}
    if conflicts:
        print(f"★ 충돌한 기존 배정   {len(conflicts):,} 자 -> 재배정 "
              f"({''.join(sorted(conflicts))[:40]})")
    mapping = {ch: slot for ch, slot in prior.items() if ch not in conflicts}

    free = []
    seen_idx = set(used_idx)
    for r in KANJI_ROWS:
        for c in range(0x21, 0x21 + CELLS):
            i = glyph_index(r, c, table)
            if i is not None and i not in seen_idx and sjis_of(r, c) is not None:
                free.append((r, c))
                seen_idx.add(i)          # 같은 인덱스를 두 번 배정하지 않는다
    taken = set(mapping.values())
    free = [s for s in free if s not in taken]
    print(f"남은 빈 칸           {len(free):,}")

    fresh = 0
    for ch in need:
        if ch in mapping:
            continue
        if not free:
            print(f"\n★ 빈 칸이 모자란다.  '{ch}' 부터 배정 못 함")
            break
        mapping[ch] = free.pop(0)
        fresh += 1
    print(f"새로 배정            {fresh:,}  (그중 재배정 {len(conflicts & set(mapping)):,})")
    print(f"배정 후 남은 칸      {len(free):,}")

    stale = [ch for ch in mapping if ch not in need]
    if stale:
        print(f"쓰지 않는 배정       {len(stale):,} 자 (그대로 둔다)")

    rows_out = []
    for ch in sorted(mapping, key=lambda c: (mapping[c][0], mapping[c][1])):
        r, c = mapping[ch]
        idx = glyph_index(r, c, table)
        rows_out.append([ch, f"{ord(ch):04X}", f"{r:02X}", f"{c:02X}",
                         sjis_of(r, c).hex().upper(), str(idx),
                         f"{GLYPH_BASE + idx * GLYPH_STRIDE:06X}"])

    print("\n앞 8건:")
    print(f"  {'글자':4s}{'행':>4s}{'셀':>4s}{'SJIS':>7s}{'인덱스':>8s}{'ROM':>9s}")
    for r in rows_out[:8]:
        print(f"  {r[0]:4s}{r[2]:>4s}{r[3]:>4s}{r[4]:>7s}{r[5]:>8s}   ${r[6]}")

    if not args.write:
        print("\n(보고만 했다.  --write 로 기록)")
        return
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f, delimiter="\t")
        w.writerow(["hangul", "unicode", "row", "cell", "sjis", "index", "rom_offset"])
        w.writerows(rows_out)
    print(f"\n배정표 -> {OUT}  ({len(rows_out)}행)")


if __name__ == "__main__":
    main()
