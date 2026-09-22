#!/usr/bin/env python3
"""수집한 CD-DA VRAM 관찰을 출하 게이트가 읽는 안전 위치표로 바꾼다.

왜 필요한가
-----------
`verify_subtitle_safe_positions.py` 는 `cdda_runtime_safe_positions.tsv` 를
**읽기만** 한다.  만드는 코드가 저장소에 없었다 (baseline §6.2).
그래서 CD-DA 커버리지는 아무리 수집해도 0/N 이었다.  이 도구가 그 빈칸이다.

무엇을 하나
-----------
    subtitle_pack.bin                 팩이 authoritative.  창 목록을 여기서 읽는다
    dump/cdda_vram_spans_*.tsv        수집기가 남긴 자유 구간 (관찰 단위)
      -> 창마다 **그 구간과 겹치는 모든 관찰**을 모은다
      -> 관찰별 자유 구간에서 19 글자 블록이 들어갈 base 를 편다
      -> 관찰들 사이에서 **교집합** (fail-closed)
      -> 게이트의 `valid_base` 로 거른다
    build/cutscene_subs/cdda_runtime_safe_positions.tsv

★★ 왜 팩에서 창을 가져오나 (2026-08-30 설계 정정)
    처음에는 `cdda_segments.tsv` 의 clip 창을 그대로 냈다.  **틀렸다.**
    게이트의 CD-DA 채점은 `(lba_from, lba_to)` **정확 일치**이고, 팩의 창은
    clip 을 다시 `part` 로 쪼갠 것이다 (재설정 전 표 clip+part 649 행 -> 창 698 개).
    clip 창 하나만 내면 part 가 2 개 이상인 clip 은 **영영 안 맞는다**
    (실측: 39 개를 검증했는데 게이트는 15 개만 인정했다).

    검증기 docstring 그대로 **팩이 authoritative** 다.  그래서 팩의 창을 먼저 읽고
    창마다 답을 낸다.  창 경계가 clip 이든 part 든 트랙이든 항상 정확히 일치한다.

★ 왜 겹침으로 대응하나
    한 창이 재생되는 **내내** 비어 있어야 안전하다.  그래서 그 창과 겹치는
    관찰을 모두 모아 교집합을 낸다.  한 번이라도 쓰였으면 그 자리는 버린다.

★★ 왜 map 이 아니라 spans 인가 (2026-08-30 실측)
    `cdda_vram_map_*.tsv` 의 `bases` 열은 **24 개에서 잘린다.**  같은 행의
    `base_count` 는 399 · 741 같은 진짜 개수를 들고 있는데 목록은 늘 24 개다.
    게다가 그 24 개는 가장 낮은 주소들이라 전부 `$2000` 미만 -- 규칙상 전멸이다.
    그것만 보면 "안전한 자리가 없다" 는 **거짓 결론**이 난다.
    `cdda_vram_spans_*.tsv` 는 `first`/`last`/`words` 로 구간을 통째로 담아
    잘리지 않는다.  그래서 이쪽이 진짜 입력이다.

★ 규칙은 검증기에서 직접 import 한다
    `valid_base` 를 베껴 쓰면 언젠가 조용히 어긋난다.  같은 함수를 부른다.

쓰는 법
    python tools/build_cdda_runtime_safe_positions.py
    python tools/build_cdda_runtime_safe_positions.py --dry-run
"""
from __future__ import annotations

import argparse
import csv
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# 게이트와 같은 규칙·같은 창 목록을 쓰기 위해 검증기에서 직접 가져온다.
from verify_subtitle_safe_positions import (  # noqa: E402
    NEED_WORDS, REQUIRED_ALIGN, parse_pack, valid_base,
)

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "cutscene_subs"
SEGMENTS = BUILD / "cdda_segments.tsv"
DEFAULT_GLOB = "dump/cdda_vram_spans_*.tsv"
OUT = BUILD / "cdda_runtime_safe_positions.tsv"

# ★★ 관찰 창고 (2026-08-31 추가)
#
# 예전에는 `dump/` 에 그때 남아 있는 파일만 읽고 결과를 통째로 덮어썼다.  그래서
# **덤프가 사라지면 결과도 같이 사라졌다** -- 환경 A/환경 B 이관 때 `dump/` 가 번들에서
# 빠지는 일이 반복됐고 (255/698 을 만든 원자료가 그렇게 유실됐다), 그 상태로 이
# 도구를 돌리면 조용히 회귀한다.
#
# 그렇다고 결과 파일(`vram_base`)을 합칠 수는 없다.  창의 답은 **관찰들의
# 교집합**이라, 새 관찰이 "그 자리 쓰였다" 고 말하면 옛 답은 틀린 답이 된다.
# 옛 답을 살려두면 자막을 그래픽 위에 올린다.
#
# 그래서 합치는 것은 답이 아니라 **관찰 그 자체**다.  덤프를 한 번 읽으면 이
# 창고에 붙여 두고, 계산은 늘 창고 전체로 한다.  덤프가 없어져도 관찰은 남고,
# 교집합은 여전히 정확하다.
ARCHIVE = BUILD / "cdda_vram_observations.tsv"
ARCHIVE_FIELDS = ("source", "clip", "lba_from", "lba_to", "first", "last")

FIELDS = ("lba_from", "lba_to", "status", "vram_base",
          "observations", "candidates", "clips", "note")


def norm_clip(value: str) -> str:
    name = (value or "").strip()
    return name[:-4] if name.lower().endswith(".wav") else name


def read_tsv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


# ★★★ 2026-09-06.  자기 자막을 자기가 금지하는 되먹임 -- 격리 목록
#
# 프로브는 "그 음성 동안 아무도 안 가리킨 VRAM" 을 자유로 친다.  그런데 **우리
# 자막 글리프도 스프라이트가 가리킨다.**  그래서 자막이 켜진 채로 관찰을 뜨면
# 우리가 쓰는 자리가 점유로 기록되고, 다음 빌드는 그 자리를 못 쓴다.  도망친
# 자리에서 다시 재면 그 자리도 죽는다 -- 잴수록 나빠지는 나선이다.
#
# 실측 (트랙 3, 19 글자 블록 = 1216 word 가 통째로 들어가는 LBA 구간 수):
#
#   덤프        $4500    $4B00    $6300    $7600    $7B00   그때 쓰던 자리
#   083045      17/20    17/20    16/20    11/20   ★1/20   $7B00 (0.5.11)
#   090538      ★0/14    12/14     8/14     6/14     8/14   $4500 (0.5.12)
#   090806      ★0/14    13/14     9/14     5/14     8/14   $4500 (0.5.12)
#   0901_212205 218/361 291/361  222/361  186/361  193/361  트랙3 자막 없음
#
# 덤프마다 **그때 우리가 쓰던 자리 하나만** 죽는다.  마지막 줄이 대조군이다.
#
# 이 오염이 실제로 한 일: 0.5.12 를 돌리며 뜬 두 판이 각각 단독으로 트랙 3의
# 이사 계획을 무너뜨렸다 ("✘관찰 없음").  그리고 아침에 "$7B00 이 국장님
# 스프라이트를 잡아먹었다" 고 지목한 근거도 083045 의 1/20 이었다 -- 우리가
# 만든 숫자였다.
#
# ⚠ 규칙:  **그 트랙 자막이 켜진 빌드로는 그 트랙 자리를 재지 마라.**
#   근본 수정은 프로브가 현재 base 를 점유에서 빼는 것이다 (렌더러 base 는
#   AC 디렉터리에 있으니 읽을 수 있다).  그때까지 이 목록이 방어한다.
#
# 격리한 원본은 `_backup_pregap_20260906/dumps_0906_held/` 에 있다.
POISONED_DUMPS = {
    # 0.5.11 ($7B00) 를 돌리며 뜬 판
    "cdda_vram_spans_20260906_082846.tsv",
    "cdda_vram_spans_20260906_082931.tsv",
    "cdda_vram_spans_20260906_083045.tsv",
    # 0.5.12 ($4500) 를 돌리며 뜬 판
    "cdda_vram_spans_20260906_090538.tsv",
    "cdda_vram_spans_20260906_090806.tsv",
    # 0.6.0-rc1/rc2 ($7900) 자막을 켠 채 오늘 트랙 17을 다시 수집한 판.
    # 검증된 자막 자리 자체를 점유로 되먹임하므로 안전자리 계산에서는 격리한다.
    "cdda_vram_spans_20260907_130007.tsv",
    "cdda_vram_spans_20260907_130008.tsv",
    "cdda_vram_spans_20260907_131723.tsv",
}


def ingest(paths: list[Path], warnings: list[str]) -> list[dict[str, str]]:
    """새 덤프를 창고에 붙이고 창고 전체를 돌려준다.

    같은 덤프를 두 번 읽지 않도록 `source`(파일 이름)로 가른다.  덤프 안의 행
    순서는 그대로 지킨다 -- `split_observations` 가 `first` 가 줄어드는 지점으로
    관찰을 가르므로 순서가 곧 정보다.
    """
    stored: list[dict[str, str]] = []
    seen: set[str] = set()
    if ARCHIVE.is_file():
        for row in read_tsv(ARCHIVE):
            source = row.get("source") or ""
            if source in POISONED_DUMPS:     # 창고에 이미 섞여 있어도 여기서 뺀다
                continue
            stored.append({k: (row.get(k) or "") for k in ARCHIVE_FIELDS})
            seen.add(source)

    added_files = 0
    held = 0
    for path in paths:
        if path.name in POISONED_DUMPS:
            held += 1
            continue
        if path.name in seen:
            continue
        added_files += 1
        for index, row in enumerate(read_tsv(path), 2):
            clip = norm_clip(row.get("clip") or row.get("key") or "")
            if not clip:
                continue
            where = f"{path.name}:{index} {clip}"
            try:
                first = int((row.get("first") or "").strip(), 16)
                last = int((row.get("last") or "").strip(), 16)
            except ValueError:
                warnings.append(f"{where}: first/last 가 16 진수가 아니다")
                continue
            if last < first:
                warnings.append(f"{where}: 뒤집힌 구간 ${first:04X}-${last:04X}")
                continue
            stored.append({
                "source": path.name, "clip": clip,
                "lba_from": (row.get("lba_from") or "").strip(),
                "lba_to": (row.get("lba_to") or "").strip(),
                "first": f"{first:04X}", "last": f"{last:04X}",
            })

    if added_files:
        ARCHIVE.parent.mkdir(parents=True, exist_ok=True)
        with ARCHIVE.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=ARCHIVE_FIELDS,
                                    delimiter="\t", lineterminator="\n")
            writer.writeheader()
            writer.writerows(stored)
    print(f"관찰 창고 {ARCHIVE.name}: 덤프 {len(seen) + added_files}개 "
          f"(새로 {added_files}개) · 구간 {len(stored)}행"
          + (f" · ★오염 격리 {held}개" if held else ""))
    return stored


def bases_in_span(first: int, last: int) -> set[int]:
    """자유 구간 [first, last] 안에 19 글자 블록이 **통째로** 들어가는 base 들.

    게이트와 같은 `valid_base` 를 그대로 쓴다 -- 정렬 · VRAM 경계 ·
    8K 패턴 뱅크 횡단 금지가 전부 거기 들어 있다.
    """
    out: set[int] = set()
    base = -(-first // REQUIRED_ALIGN) * REQUIRED_ALIGN   # 올림 정렬
    while base + NEED_WORDS - 1 <= last:
        if valid_base(base, "", []):
            out.add(base)
        base += REQUIRED_ALIGN
    return out


def split_observations(
        rows: list[tuple[str, int, int]]) -> list[list[tuple[int, int]]]:
    """한 clip 의 span 행들을 관찰 단위로 가른다.

    수집기는 관찰마다 구간을 오름차순으로 한 덩어리씩 붙인다.  그래서 `first`
    가 줄어드는 지점이 새 관찰의 시작이다 (실측: c20_001 이 9 구간씩 3 번).

    ★ 덤프가 바뀌는 지점도 무조건 새 관찰이다.  창고에 여러 덤프가 이어 붙으면
    경계에서 `first` 가 우연히 안 줄어들 수 있는데, 그러면 서로 다른 주행 두 개가
    한 관찰로 뭉쳐 **합집합**이 된다 -- 교집합이어야 할 자리라 안전하지 않은
    base 가 살아남는다.  `source` 가 그것을 확실히 가른다.
    """
    groups: list[list[tuple[int, int]]] = []
    previous_source: str | None = None
    for source, first, last in rows:
        boundary = (not groups
                    or source != previous_source
                    or first < groups[-1][-1][0])
        if boundary:
            groups.append([(first, last)])
        else:
            groups[-1].append((first, last))
        previous_source = source
    return groups


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--glob", default=DEFAULT_GLOB)
    parser.add_argument("--pick", choices=("lowest", "highest"), default="lowest",
                        help="후보가 여럿일 때 고르는 방식 (기본 lowest, 결정적)")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--out", type=Path, default=OUT)
    args = parser.parse_args()

    warnings: list[str] = []

    # ---- 1) 팩의 창 목록 = authoritative -----------------------------------
    _, pack_windows = parse_pack()
    if not pack_windows:
        warnings.append(
            "팩에 CD-DA 창이 0 개다.  번역 원본(cdda_subtitles.tsv)이 비어 있으면 "
            "정상이다 -- 그때는 채울 것이 없다")

    # ---- 2) 관찰: (lba_from, lba_to, 자유 base 집합) ------------------------
    paths = sorted(ROOT.glob(args.glob))
    stored = ingest(paths, warnings)
    if not stored:
        # 창고도 비었고 새 덤프도 없다.  이때 계산하면 모든 창이 unverified 가
        # 되어 기존 결과를 지운다.  아무것도 안 하는 것이 옳다.
        raise SystemExit(
            f"관찰이 하나도 없다 (덤프 {args.glob} · 창고 {ARCHIVE.name}).\n"
            f"  {OUT.name} 은 건드리지 않았다.")

    spans_of: dict[str, list[tuple[str, int, int]]] = defaultdict(list)
    lba_of: dict[str, tuple[int, int]] = {}
    for row in stored:
        clip = row["clip"]
        spans_of[clip].append(
            (row["source"], int(row["first"], 16), int(row["last"], 16)))
        try:
            lba_of[clip] = (int(row["lba_from"]), int(row["lba_to"]))
        except (TypeError, ValueError):
            pass

    # 관찰 하나 = (구간, 그 관찰에서 비어 있던 base 집합)
    observations: list[tuple[str, tuple[int, int], set[int]]] = []
    for clip, spans in spans_of.items():
        window = lba_of.get(clip)
        if window is None:
            warnings.append(f"{clip}: 관찰에 LBA 가 없어 창에 붙일 수 없다")
            continue
        for group in split_observations(spans):
            free: set[int] = set()
            for first, last in group:
                free |= bases_in_span(first, last)
            observations.append((clip, window, free))

    # ---- 3) 창마다 겹치는 관찰을 모아 교집합 -------------------------------
    out_rows: list[dict[str, str]] = []
    verified = 0

    for lba_from, lba_to in sorted(pack_windows):
        hits = [(c, f) for c, (a, b), f in observations
                if a < lba_to and lba_from < b]        # 반열린 구간 겹침
        clips = sorted({c for c, _ in hits})
        row = {
            "lba_from": str(lba_from), "lba_to": str(lba_to),
            "status": "unverified", "vram_base": "",
            "observations": str(len(hits)), "candidates": "0",
            "clips": ",".join(clips), "note": "",
        }
        if not hits:
            row["note"] = "겹치는 관찰 없음"
            out_rows.append(row)
            continue

        acc: set[int] | None = None
        for _, free in hits:
            acc = free if acc is None else (acc & free)
        good = sorted(acc or set())
        row["candidates"] = str(len(good))
        if not good:
            row["note"] = "교집합에 규칙 통과 후보 없음"
            out_rows.append(row)
            continue

        base = good[0] if args.pick == "lowest" else good[-1]
        row["vram_base"] = f"{base:04X}"
        row["status"] = "verified"
        verified += 1
        out_rows.append(row)

    # ---- 4) 출력 -----------------------------------------------------------
    # 덮어쓰기 전에 이전 판이 몇 창이었는지 말하고 백업을 남긴다.  관찰이 늘면
    # 줄어드는 것도 **정상**이다 (새 관찰이 그 자리는 쓰인다고 말한 것).  그래서
    # 막지는 않고, 조용히 넘어가지도 않는다.
    before = None
    if args.out.is_file():
        before = sum(1 for r in read_tsv(args.out) if r.get("status") == "verified")
        if not args.dry_run:
            import datetime
            stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            backup = args.out.with_name(f"{args.out.stem}.bak_{stamp}{args.out.suffix}")
            backup.write_bytes(args.out.read_bytes())
            print(f"이전 판 백업: {backup.name}")
    if before is not None:
        arrow = "=" if verified == before else ("▲" if verified > before else "▼")
        print(f"검증된 창 {before} {arrow} {verified}")
        if verified < before:
            print("  ▼ 줄었다.  새 관찰이 옛 자리를 부정했거나, 관찰이 사라졌다."
                  "  창고 행 수를 먼저 볼 것")

    if not args.dry_run:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        with args.out.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=FIELDS,
                                    delimiter="\t", lineterminator="\n")
            writer.writeheader()
            writer.writerows(out_rows)

    print(f"관찰 파일 {len(paths)}개 · 관찰 {len(observations)}건 "
          f"({len(spans_of)} clip)")
    print(f"팩 창 {len(pack_windows)}개 · verified {verified}")
    covered = len([r for r in out_rows if r["observations"] != "0"])
    print(f"겹치는 관찰이 있는 창 {covered}")
    if warnings:
        print(f"경고 {len(warnings)}건")
        for line in warnings[:10]:
            print("  - " + line)
        if len(warnings) > 10:
            print(f"  ... 외 {len(warnings) - 10}건")
    print(args.out if not args.dry_run else "(dry-run, 안 씀)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
