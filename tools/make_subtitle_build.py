#!/usr/bin/env python3
"""자막을 조금씩 넣어가며 실기로 확인하는 한 줄짜리 반복 도구.

왜
--
자막을 한 번에 다 밀어넣으면 어디서 깨지는지 모른다.  스튜디오에서 검토 O 를
몇 줄 찍고 -> 굽고 -> 실기로 보고 -> 다시 몇 줄, 이 고리가 빨라야 한다.
그런데 지금은 명령 넷을 순서대로 쳐야 하고, **하나만 빼먹어도 조용히 옛것이
실린다** (2026-09-01 에 팩과 헬퍼가 각각 그렇게 안 실려 하루를 태웠다).

    build_subtitle_set.py              팩 + 파생물 (태그로 짝을 맞춘다)
    build_cdda_mini_index_all.py       지금 팩에 맞춰 CD-DA 색인을 다시 굽는다
    build_snatcher_0_4_7_2_cdda_scheduled.py
                                       현행 전 트랙 스케줄러 경로로 디스크를 굽는다
    patch_track24_subtitle_pack.py     ★ 이걸 빼먹으면 디스크엔 옛 팩이 남는다
    patch_bios_cpu_cache.py            ★ 이걸 빼먹으면 챕터1 화면이 깨진다
    patch_bios_cdda_rom_resident.py    CD-DA ROM 렌더러와 스케줄러를 심는다

쓰는 법
-------
```
python tools/make_subtitle_build.py 0.4.6.64 --reviewed-only    검토 O 만
python tools/make_subtitle_build.py 0.4.6.65                    전부
python tools/make_subtitle_build.py --capacity                  자리만 본다
```

* 스튜디오를 닫고 돌린다.  이 도구는 표를 안 고치지만, 스튜디오가 열려 있으면
   네가 찍은 O 가 아직 파일에 없을 수 있다.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import subtitle_layout as layout

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "cutscene_subs"
PACK = BUILD / "subtitle_pack.bin"
MASTER = ROOT / "snatcher_tool" / "translation" / "snatcher_ko_master.tsv"
STAMP = "master.sha256"          # 기준판 폴더에 남기는 "이 대사로 구웠다" 표식
PACK_REGION = layout.AC_PACK_MAX
PY = sys.executable


def run(script: str, *args: str) -> None:
    """자식 출력을 **가로채지 않는다.**

    전에는 capture_output 으로 받아 다시 찍었는데, 자식이 cp949 로 쓰는 것을
    utf-8 로 읽어 U+FFFD 가 되고 그것을 다시 cp949 콘솔에 찍다가 죽었다.
    그냥 흘려보내면 인코딩 문제가 생길 자리가 없다.
    """

    cmd = [PY, str(ROOT / "tools" / script), *args]
    print(f"\n$ {script} {' '.join(args)}", flush=True)
    if subprocess.run(cmd, cwd=ROOT).returncode != 0:
        raise SystemExit(f"\n{script} 가 실패했다 -- 여기서 멈춘다")


def capacity() -> None:
    if not PACK.exists():
        raise SystemExit("팩이 없다.  먼저 한 번 구울 것")
    used = PACK.stat().st_size
    info = BUILD / "subtitle_pack.json"
    glyphs = records = None
    if info.exists():
        data = json.loads(info.read_text(encoding="utf-8"))
        glyphs = data.get("glyphs") or data.get("glyph_count")
        records = data.get("records") or data.get("record_count")
    free = PACK_REGION - used
    print(f"팩 {used:,} B / {PACK_REGION:,} B  ({used / PACK_REGION * 100:.1f}%)")
    print(f"  남은 자리 {free:,} B")
    print(f"  줄 하나 약 50 B (기록 37 + 색인 13)   -> 약 {max(free, 0) // 50:,} 줄")
    print(f"  새 한글 한 자 = 64 B                 -> 새 글자가 섞이면 그만큼 준다")
    if glyphs:
        print(f"  지금 글리프 {glyphs} 자 · {glyphs * 64:,} B (팩의 {glyphs * 64 / used * 100:.0f}%)")
        print("  SNATCHER_KO_BIOS=1 로 구우면 글리프가 팩에서 빠진다 (실기 확인 필요)")


# ★ 이 사슬은 [4/8] 에서 `--rom-resident` 를 **무조건** 넘기고
#   [7/8] 에서 `patch_bios_cdda_rom_resident.py` 를 돌린다.  그래서 상수다.
#   ⚠ 그 두 줄을 조건부로 바꾸는 날 이것도 같이 바꿀 것 -- `--adpcm-reuse` 가
#     안전한 근거(= CD-DA 가 AC_ENGINE 을 안 덮는다)가 여기에 달려 있다.
#   어긋나면 [4/8] 의 교차검사가 빌드를 세운다.
ROM_RESIDENT = True


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("version", nargs="?", help="예: 0.4.6.64")
    # ⚠ 2026-09-15 에 이걸 붙여 굽고 하루를 태웠다.  ADPCM 자막이 통째로 안 나왔다.
    #
    #       voice_subtitles.tsv  2,473 행 중 검토 O 는 614
    #       -> ADPCM 열쇠 1,081 -> 287 (0.7.22 -> 0.7.23)
    #
    #   출하판은 **검토 표시와 상관없이 다 싣는다.**  정식 명령은
    #   `make_subtitle_build <판> --skip-oversize` 한 줄이고 이 스위치는 안 쓴다.
    #   빌드는 조용히 성공하므로 산출물만 봐서는 모른다 -- 그래서 아래에서 경고한다.
    ap.add_argument("--reviewed-only", action="store_true",
                    help="검토 O 인 자막만 싣는다 (조금씩 늘려갈 때) "
                         "★출하판에는 쓰지 말 것 -- 자막 대부분이 빠진다")
    # ★ 2026-09-03: 이게 없어서 프론트도어가 통째로 막혀 있었다.  길이 초과 자막이
    #   하나라도 있으면 build_subtitle_pack.py 가 죽는데, 그 스위치를 넘길 길이
    #   없었다 -> 팩을 못 굽고 -> 새 자막이 한 판도 안 나갔다.
    ap.add_argument("--skip-oversize", action="store_true",
                    help="엔진 한도(19칸)를 넘는 자막은 빼고 굽는다 "
                         "(목록: build/cutscene_subs/pack_over_capacity.tsv)")
    ap.add_argument("--baseline", default="0.4.6.61-dictionary-key-vram",
                    help="대사 번역이 들어 있는 기준판")
    ap.add_argument("--capacity", action="store_true", help="자리만 보고 안 굽는다")
    ap.add_argument("--no-dialogue", action="store_true",
                    help="대사 기준판이 낡아도 다시 안 굽는다 (자막만 빨리 볼 때)")
    ap.add_argument("--adpcm-reuse", action="store_true",
                    help=argparse.SUPPRESS)
    # ★ 2026-09-10: 그래픽 18 장을 프론트도어 안으로 들였다.
    #   예전에는 굽고 나서 `patch_gfx_screen.py` 를 손으로 다섯 줄 더 쳐야 했고,
    #   ① 빠뜨리면 그래픽 없는 판이 그대로 나갔으며
    #   ② 단계마다 새 폴더에 Track 02(80 MB)를 새로 써서 한 판에 400 MB 를 버렸다.
    #   이제 같은 폴더에 제자리로 얹는다 (`--base` == `--version`).
    ap.add_argument("--no-gfx", action="store_true",
                    help="그래픽 18 장을 안 얹는다 (자막만 가르는 대조판용)")
    args = ap.parse_args()

    # ★ 2026-09-17: 무조건 거부를 **조건부**로 바꾼다.
    #   재사용이 성립하는 근거는 "음성 사이에 AC_ENGINE 을 건드리는 놈이 없다" 인데,
    #   그것이 참인 것은 **ROM-resident 일 때뿐**이다 -- CD-DA 의 AC 쓰기가 전부
    #   `cdda_rom_entry is None` 갈래라 상주 모드에서만 죽는다 (실측 2026-09-17).
    #   상주가 아니면 CD-DA 가 같은 슬롯을 671 B 로 덮으므로 재사용은 **엉뚱한
    #   렌더러를 실행**하게 된다.  가정으로 두지 말고 가드로 만든다.
    if args.adpcm_reuse and not ROM_RESIDENT:
        raise SystemExit(
            "--adpcm-reuse 는 ROM-resident 사슬에서만 쓸 수 있다.  "
            "CD-DA 가 같은 AC 슬롯을 덮으면 재사용이 엉뚱한 렌더러를 실행한다")

    if args.capacity or not args.version:
        capacity()
        if not args.version:
            print("\n굽으려면 버전을 준다:  python tools/make_subtitle_build.py 0.4.6.64")
        return

    out = ROOT / "build" / "patch" / args.version
    if out.exists():
        raise SystemExit(f"이미 있다: {out}\n  다른 버전 번호를 주거나 폴더를 지울 것")

    # ---- 0/4  대사 기준판이 지금 마스터로 구운 것인가 ----
    #
    # 기준판은 그 자체로 **스냅샷**이다.  마스터를 고쳐도 기준판을 다시 굽지 않으면
    # 대사는 옛것이 나간다 -- 오늘 종일 밟은 그 함정과 같은 종류다.  그래서 마스터
    # 해시를 기준판 폴더에 적어두고, 다르면 여기서 자동으로 다시 굽는다.
    baseline = ROOT / "build" / "patch" / args.baseline
    master_sha = hashlib.sha256(MASTER.read_bytes()).hexdigest().upper()
    stamp = baseline / STAMP
    stamped = stamp.read_text(encoding="utf-8").strip() if stamp.exists() else None
    if not baseline.exists() or stamped != master_sha:
        why = ("기준판이 없다" if not baseline.exists()
               else "기준판이 옛 마스터로 구워졌다" if stamped
               else "기준판에 표식이 없다")
        print("=" * 64)
        print(f"[0/4] 대사 기준판을 다시 굽는다   ({why})")
        print(f"      마스터 {master_sha[:16]}")
        print("=" * 64)
        if args.no_dialogue:
            print("  --no-dialogue 라 건너뛴다.  대사는 옛것이 나간다")
        else:
            # 하위 빌더는 기존 최종 폴더를 덮어쓰지 않는다.  예전에는 그래서
            # "낡았으니 다시 굽는다"고 해 놓고 마지막 단계에서 반드시 멈췄다.
            # 삭제하지 않고 같은 위치에 시각이 붙은 백업으로 옮겨 둔다.
            if baseline.exists():
                suffix = datetime.now().strftime("%Y%m%d_%H%M%S")
                backup = baseline.with_name(f"{baseline.name}.bak_{suffix}")
                if backup.exists():
                    raise SystemExit(f"기준판 백업 경로가 이미 있다: {backup}")
                baseline.rename(backup)
                print(f"  옛 기준판 백업  {backup.name}")
            run("build_snatcher_0_4_6_61_dictionary_key_vram.py")
            made = ROOT / "build" / "patch" / "0.4.6.61-dictionary-key-vram"
            if made.exists():
                args.baseline = made.name
                baseline = made
            (baseline / STAMP).write_text(master_sha, encoding="utf-8")
    else:
        print(f"대사 기준판 {args.baseline} 은 지금 마스터로 구운 것이다"
              f"  ({master_sha[:16]})")

    # ★★ 2026-09-03: 스튜디오 표 -> 팩이 읽는 파생물.  이게 빠져 있어서 조용히 늙었다.
    #
    #   스튜디오는 `voice_subtitles.tsv` 에 저장하는데 팩 빌더는
    #   `voice_subtitles_keyed.tsv` 를 읽는다.  둘을 잇는 단계가 손으로만 있었고
    #   프론트도어가 안 불러서, 09-02 저녁 이후의 자막이 한 판도 안 나갔다.
    #
    #   ⚠ 파생물을 통째로 갈아엎는다 (승계 없음).  정본에 없는 행은 사라진다 --
    #     그것이 옳다 (옛 분할의 꼬리 조각들이다).  도구가 먼저 백업을 뜬다.
    #   ⚠ 이것은 `build_runtime_master.py --install`(대사 병합) 과 **다른 도구**다.
    #     그쪽이 행별 작업을 뭉개는 지뢰이고, 이쪽은 아니다.
    print("=" * 64)
    print("[1/8] 자막 정본 -> 파생물 동기화")
    print("=" * 64)
    run("sync_voice_subtitles_keyed.py", "--write")

    print()
    print("=" * 64)
    print(f"[2/8] 자막 한 벌   {'검토 O 만' if args.reviewed_only else '전부'}")
    print("=" * 64)
    if args.reviewed_only:
        # 몇 행이 빠지는지 **숫자로** 보여준다.  "검토 O 만" 이라는 글자만으로는
        # 그게 90% 를 버린다는 뜻인 줄 모른다 (2026-09-15 실제로 못 알아챘다).
        import csv as _csv
        import io as _io
        for _name in ("voice_subtitles.tsv", "cdda_subtitles.tsv"):
            _p = ROOT / "snatcher_tool" / "translation" / _name
            if not _p.is_file():
                continue
            _raw = _p.read_bytes()
            _enc = "utf-16" if _raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8-sig"
            _rows = list(_csv.DictReader(_io.StringIO(_raw.decode(_enc)), delimiter="\t"))
            _ok = sum(1 for r in _rows
                      if (r.get("review") or "").strip().upper() == "O")
            print(f"  ⚠ {_name}  {_ok} / {len(_rows)} 행만 실린다 "
                  f"({len(_rows) - _ok} 행이 빠진다)")
        print("  ⚠ 출하판이면 --reviewed-only 를 빼고 다시 돌릴 것")
    run("build_subtitle_set.py",
        *(["--reviewed-only"] if args.reviewed_only else []),
        *(["--skip-oversize"] if args.skip_oversize else []))
    tag = hashlib.sha256(PACK.read_bytes()).hexdigest()[:8].upper()
    capacity()

    # 팩을 다시 구우면 record offset이 달라진다.  예전 프론트도어는 옛 mini
    # index를 그대로 재사용해서, 자막 시각을 정상적으로 바꿔도 뒤에서 레거시
    # Track 17 POC를 타거나 낡은 record를 읽었다.  현행 스케줄러의 입력을 반드시
    # 같은 팩에서 다시 만든다.
    print("\n" + "=" * 64)
    print("[3/8] CD-DA 전 트랙 색인")
    print("=" * 64)
    run("build_cdda_mini_index_all.py", "--write")

    print("\n" + "=" * 64)
    print(f"[4/8] 디스크       기준판 {args.baseline}")
    print("=" * 64)
    # 레거시 all_in_one은 Track 17 오프닝에 정확히 두 줄이 있어야 한다는 POC를
    # 아직 굽는다.  현행 경로는 그 미사용 엔진을 건너뛰고 mini index의 모든
    # 자막을 스케줄러로 처리하므로, 사용자가 정한 시각에 인위적인 제약이 없다.
    # ★ 2026-09-17: `--adpcm-reuse` 의 안전성이 **이 한 줄**에 달려 있다.
    #   CD-DA 가 AC 슬롯(AC_ENGINE)을 안 덮는 것은 ROM-resident 일 때뿐이다.
    #   그래서 상수(ROM_RESIDENT)와 실제 사슬이 어긋나면 여기서 세운다 --
    #   상수만 믿으면 언젠가 조용히 거짓말이 된다.
    cdda_args = ("--rom-resident", "--tag", tag, "--baseline", args.baseline,
                 "--version", args.version)
    # ★ 2026-09-17: 여기서 **넘겨야** 효력이 생긴다.
    #   `0_4_7_2` 는 남은 argv 를 그대로 `chain.main()`(all_in_one) 으로 흘리고,
    #   거기서 ADPCM_REUSE_SIGNATURE_* 상수가 세워진다.
    #   ⚠ 예전에는 이 줄이 없어서 `--adpcm-reuse` 가 **검사만 되고 아무 일도
    #     안 했다** -- 플래그가 있다고 도는 게 아니다.
    if args.adpcm_reuse:
        cdda_args = (*cdda_args, "--adpcm-reuse")
    if ("--rom-resident" in cdda_args) != ROM_RESIDENT:
        raise SystemExit(
            "ROM_RESIDENT 상수와 실제 사슬이 어긋났다.  "
            "--adpcm-reuse 의 안전 근거가 이것이므로 둘을 같이 고칠 것")
    run("build_snatcher_0_4_7_2_cdda_scheduled.py", *cdda_args)

    print("\n" + "=" * 64)
    print("[5/8] 팩을 Track 24 에 갈아끼운다")
    print("=" * 64)
    run("patch_track24_subtitle_pack.py", args.version, "--write")

    print("\n" + "=" * 64)
    print("[6/8] 671 B 처방")
    print("=" * 64)
    run("patch_bios_cpu_cache.py", args.version, "--write")

    print("\n" + "=" * 64)
    print("[7/8] CD-DA ROM 렌더러 + 스케줄러")
    print("=" * 64)
    run("patch_bios_cdda_rom_resident.py", args.version, "--write")

    # ★★ 그래픽 18 장 -- 같은 폴더에 제자리로 얹는다.
    #
    #   순서가 곧 규칙이다.  헌정 -> RSS -> 면책 -> 깁슨 -> 전화.  화면들이 건드리는
    #   블록은 서로 안 겹치지만(헌정/RSS/면책 $022xxxx · 깁슨 $05Exxxx · 전화
    #   $077xxxx), 단계마다 그때의 Track 02 를 다시 읽으므로 겹쳐도 옳게 쌓인다.
    #
    #   ⚠ 깁슨은 `--all-copies` 가 필수다.  같은 블록이 디스크에 두 벌 있는 장이
    #     셋이라(`$03986C4`·`$039A8E4`·`$039914A`) 한 벌만 갈면 장면에 따라 일본어가
    #     그대로 나온다.
    GFX_SCREENS = (
        ("dedication", ()),
        ("rss",        ()),
        ("disclaimer", ()),
        ("gibson",     ("--all-copies",)),
        ("phone",      ()),
        ("ending_struggle", ()),
    )
    if args.no_gfx:
        print("\n" + "=" * 64)
        print("[8/8] 그래픽 18 장   ★ --no-gfx 라 안 얹는다")
        print("=" * 64)
    else:
        for i, (screen, extra) in enumerate(GFX_SCREENS, 1):
            print("\n" + "=" * 64)
            print(f"[8/8] 그래픽 {i}/{len(GFX_SCREENS)}   {screen}")
            print("=" * 64)
            run("patch_gfx_screen.py", "--screen", screen,
                "--base", args.version, "--version", args.version,
                *extra, "--write")

        # ★ 2026-09-22: 타이틀 메뉴와 오프닝 자막은 `patch_gfx_screen.py` 가
        #   아니라 제 도구를 쓴다 (스프라이트라 블록 찾는 법이 다르다).  사슬에
        #   없어서 **0.7.26~0.7.28 실물에 아예 안 들어가 있었다** -- 환경 B 인계서
        #   §2 가 "타이틀이 일본어 그대로" 로 잡은 것이 이것이다.
        #   둘 다 매니페스트 `route_c.sectors_touched` 를 누적하므로
        #   `check_build_invariants` 의 Track02 섹터 판정을 통과한다.
        for i, script in enumerate(
                ("patch_title_menu_sprite_ko.py", "patch_opening_caption_ko.py"), 1):
            print("\n" + "=" * 64)
            print(f"[8/8] 스프라이트 화면 {i}/2   {script}")
            print("=" * 64)
            run(script, args.version, "--write", "--no-backup")

        # ★★ 가우디(인물검색·자판).  2026-09-22 에 **0.7.25 부터 조용히 빠져
        #   있던 것**을 소유자가 잡았다 -- 0.7.13~0.7.24 에는 있었는데 손으로
        #   돌리던 단계라 한 번 빠뜨리자 그대로 굳었다.  증상이 없다:
        #   빌드도 감사도 다 통과하고 인물검색만 일본어로 남는다.
        #     ① BIOS 글리프 45 개 + Track02 검색 훅 $B9E0
        #     ② 자판 타일·타일맵 제자리 치환
        #     ③ 자판 키 표 (지우기 키 자리)
        #   ★★ `apply_gaudi_to_build.py` 만으로는 **검색이 하나도 안 걸린다.**
        #     그게 넣는 것은 깁슨 하나짜리 옛 훅(97 B)이다 (2026-09-22 실기:
        #     자판은 한글인데 인물검색 0 건).  진짜 표(이름 16 + 퀴즈 4, 314 B)는
        #     `apply_gaudi_search_full.py` 가 동굴에 얹는다 -- 훅 다음에 와야 한다.
        for script, extra in (("apply_gaudi_to_build.py", ()),
                              ("apply_gaudi_search_full.py", ("--write",)),
                              ("patch_gaudi_keypad_native.py", ("--write", "--no-backup")),
                              ("patch_gaudi_keypad_key_table.py", ("--write",))):
            print("\n" + "=" * 64)
            print(f"[8/8] 가우디   {script}")
            print("=" * 64)
            run(script, args.version, *extra)

        # ★★ BIOS 부팅화면.  **사슬은 기준판에서 BIOS 를 물려받으므로**
        #   `build/bios_font/` 를 고쳐 봐야 소용없다 (2026-09-22 에 여기서 물렸다).
        #   구운 판에 직접 얹어야 한다.
        #     ① 해태 카드에서 온 5,751 B 를 JP 원본으로 되돌린다 (재배포 불가 자료)
        #     ② 그 자리에 스내처 워드마크를 얹는다
        #   순서가 중요하다 -- ①이 ②가 안 덮는 자리(메뉴 문자열·타일 $01-$3B)까지
        #   치우고, ②는 타일 $80-$DF·리스트·팔레트만 쓴다.
        for script in ("strip_haitai_logo.py", "build_bios_boot_snatcher.py"):
            print("\n" + "=" * 64)
            print(f"[8/8] BIOS 부팅화면   {script}")
            print("=" * 64)
            run(script, args.version, "--write")

        # ★ Track 02 장부를 실물에서 다시 맞춘다.  **반드시 마지막**이다.
        #   자판·스프라이트 패처는 디스크만 고치고 매니페스트를 안 건드려서
        #   그냥 두면 감사가 `track02 해시` · `선언 없이 바뀐 섹터` 로 운다
        #   (장부 문제지 디스크 파손이 아니다).  이 도구는 기준판과 바이트로
        #   비교해 **바뀐 섹터를 직접 세므로** 도구들의 보고를 안 믿는다.
        print("\n" + "=" * 64)
        print("[8/8] Track02 장부 맞추기   sync_manifest_track02.py")
        print("=" * 64)
        #   ⚠ 기준판을 **명시**해야 한다.  안 주면 매니페스트의 `base` 를 쓰는데
        #     그 폴더엔 Track 02 가 없어서 섹터를 못 세고 조용히 넘어간다
        #     (2026-09-22 실측: 12 개가 선언 없이 남아 감사가 실패했다).
        #     감사가 쓰는 것과 **같은 기준판**이어야 한다.
        run("sync_manifest_track02.py", args.version,
            "--baseline", args.baseline, "--write")

    pce = next(out.glob("*.pce"), None)
    cue = next(out.glob("*.cue"), None)
    print("\n" + "=" * 64)
    print(f"완성 · 태그 {tag}")
    print("=" * 64)
    print(f"  BIOS  {pce}")
    print(f"  CUE   {cue}")
    print("  Lua   안 올린다   ★ Mesen 에서 BIOS 와 CUE 를 둘 다 이 폴더로 맞출 것")


if __name__ == "__main__":
    main()
