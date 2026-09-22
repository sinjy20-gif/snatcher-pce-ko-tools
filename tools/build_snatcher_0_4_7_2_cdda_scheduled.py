#!/usr/bin/env python3
"""0.4.7.2: CD-DA 트랙 17 을 **스케줄러로** 그린다 (2 줄 -> 39 구간).

무엇이 달라지나
---------------
```
지금(0.4.7.1)   CD-DA 엔진이 자기 타이머로 문턱 3 개를 세서 2 줄만 그린다
                디스패처는 CD-DA 면 스케줄러를 통째로 건너뛴다
이 판           엔진에서 타이머를 빼고(615 B), 39 구간 표를 스케줄러가 걷는다
                ADPCM 이 쓰는 것과 같은 구조 -- blank_frame 보호도 같이 받는다
```

무엇을 안 건드리나
------------------
**ADPCM 은 한 바이트도 안 바뀐다.**  기존 사슬 파일은 몽키패치로만 만진다.
매 빌드마다 `tools/verify_adpcm_untouched.py` 로 증명한다.

자리
----
```
AC  $1FE800   스케줄 연동 렌더러 671 B (코드 615 + FF 패딩 + 매체 지문 $CD @+670)
AC  $1FEB00   mini index 39 x 13 = 507 B   ★ 정적 선적재.  런타임 복사 없음
뱅크 $ECF9    scheduler_cdda 467 B         ★ BANK1_FREE 밖.  따로 심는다
BANK1_FREE    +63 B (AC_SCHED 초기화) +6 B (JSR 트램폴린) 만 더 쓴다
```

⚠ 아직 승격 안 된 자리 둘
-------------------------
```
뱅크 $ECF9-$F04D   CDL 감사 통과 (실행0·데이터0·직접참조0).  실주행 무접촉은 미확인
AC   $1FEB00       AC 상단 자유 구간 안이지만 런타임 무접촉은 미확인
```
`lua/SUB/0.5.165-borrow-tail-alive.lua` 로 확인한 뒤에 실기에 올릴 것.
빌드는 막지 않는다 -- 심기 전에 그 자리가 $FF 인지는 도구가 확인한다.

    python tools/build_snatcher_0_4_7_2_cdda_scheduled.py
    python tools/patch_bios_cdda_scheduler.py 0.4.7.2 --write
    python tools/verify_adpcm_untouched.py
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import build_snatcher_0_4_6_63_all_in_one as chain  # noqa: E402
import build_snatcher_0_4_6_47_cdda_adpcm_overlay as overlay  # noqa: E402
import build_subtitle_engine_cdda_scheduled as scheduled  # noqa: E402
import build_subtitle_engine_cdda_rom as rom_renderer  # noqa: E402
import build_snatcher_cdda_scheduler as sched  # noqa: E402

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

VERSION = "0.5.2"
BUILD = ROOT / "build" / "cutscene_subs"
SCHEDULER_ORIGIN = "bankA"           # sched.ORIGINS 의 키

# ★ 2026-09-04 밤: 전 트랙 연결.
#   False 면 트랙 17 하나(13 B mini), True 면 15 트랙(5 B mini + 트랙 디렉터리).
ALL_TRACKS = True


def main() -> None:
    args = sys.argv[1:]
    force_release = None
    for index, value in enumerate(list(args)):
        if value == "--adpcm-force-release-after" and index + 1 < len(args):
            force_release = int(args[index + 1], 0)
            args = args[:index] + args[index + 2:]
            break
        if value.startswith("--adpcm-force-release-after="):
            force_release = int(value.split("=", 1)[1], 0)
            args = args[:index] + args[index + 1:]
            break
    rom_resident = "--rom-resident" in args
    if rom_resident:
        args = [arg for arg in args if arg != "--rom-resident"]
    lo, _hi, note = sched.ORIGINS[SCHEDULER_ORIGIN]

    # ★ 2026-09-05.  아래 [3/3] 안내가 `VERSION` 을 그대로 찍는 바람에, CLI 로
    #   `--version 0.5.8` 을 준 빌드가 "patch_... 0.5.2 --write" 를 안내했다.
    #   그대로 따라 하면 **방금 구운 것이 아니라 옛 판을 패치한다.**  사슬은
    #   argparse 가 마지막 --version 을 쓰므로 산출물만 맞고 안내가 틀렸다.
    #   실제로 넘어가는 값을 그대로 찍는다.
    effective = VERSION
    for index, value in enumerate(args):
        if value == "--version" and index + 1 < len(args):
            effective = args[index + 1]
        elif value.startswith("--version="):
            effective = value.split("=", 1)[1]

    # 1) 스케줄 연동 렌더러를 지금 팩으로 다시 굽는다 (매체 지문 포함).
    print("[1/3] 스케줄 연동 렌더러")
    saved, sys.argv = sys.argv, [sys.argv[0], "--write"]
    try:
        scheduled.main()
    finally:
        sys.argv = saved
    print()

    if rom_resident:
        print("[1-R] CD-DA ROM 상주 렌더러")
        saved, sys.argv = sys.argv, [sys.argv[0], "--write"]
        try:
            rom_renderer.main()
        finally:
            sys.argv = saved
        print()

    # 1-b) ★ 레거시 2 줄 엔진은 스케줄러 모드에서 **안 쓴다.**  굽지도 않는다.
    #
    #   `overlay.build_frozen_cdda_engine()` 은 이름과 달리 동결 팩이 아니라
    #   **작업 팩**으로 굽는다 -- `all_in_one` 이 `preload.PACK` 을 작업 팩으로
    #   덮어쓰기 때문이다.  그 엔진(`track17_poc`)은 기록 포인터를 둘만 들고
    #   elapsed 상위 바이트를 0/1/2 색인으로 쓰므로, **오프닝 창의 앞 두 줄이
    #   LBA 로 정확히 맞닿아야** 한다.
    #
    #   그런데 스케줄러 모드에서는 바로 아래 `main_with_scheduler` 가
    #   `CDDA_ENGINE` 을 스케줄 렌더러로 갈아끼워 그 엔진을 **버린다.**  쓰지도
    #   않는 엔진의 제약이 빌드를 막는 셈이다.
    #
    #   ★ 2026-09-05, 0.5.1 빌드에서 실제로 막혔다.  자막 싱크를 다시 맞추자
    #     트랙 17 오프닝 두 줄이 187084~187356 / 187357~ 로 1 LBA 어긋났고
    #     "Track 17 앞 두 줄이 이어지지 않는다" 로 사슬이 멈췄다.  0.4.7.11 은
    #     그 두 줄이 우연히 맞닿아 있어 안 걸렸을 뿐이다 -- 잠복해 있던 것이다.
    #
    #   그래서 굽는 대신 **감사를 실제로 싣는 렌더러로 돌린다.**  manifest 의
    #   `frozen_cdda_engine_sha256` 도 그편이 맞다 (안 쓰는 파일의 해시보다
    #   실제 출하물의 해시가 낫다).  사슬 파일은 한 줄도 안 고친다.
    def _use_scheduled_renderer_for_audit() -> None:
        overlay.FROZEN_CDDA_ENGINE = scheduled.OUT
        overlay.FROZEN_CDDA_INFO = scheduled.INFO
        print("      레거시 2 줄 엔진  건너뜀 (스케줄러가 대체한다)")
        print(f"      감사 대상 렌더러  {scheduled.OUT.name}")

    overlay.build_frozen_cdda_engine = _use_scheduled_renderer_for_audit

    # 2) 사슬을 돌리되, build.main() 직전에 스케줄러 연동 스위치를 켠다.
    #    overlay 가 CDDA_ENGINE 을 자기 것으로 덮으므로 **그 뒤**에 끼어들어야
    #    한다.  그래서 build.main 을 감싼다 (이 저장소의 몽키패치 관례 그대로).
    build = overlay.build
    real_main = build.main
    old_force_release = build.ADPCM_FORCE_RELEASE_AFTER_FRAMES
    build.ADPCM_FORCE_RELEASE_AFTER_FRAMES = force_release

    def main_with_scheduler() -> None:
        build.CDDA_ENGINE = scheduled.OUT
        build.CDDA_INFO = scheduled.INFO
        build.CDDA_SCHEDULER_AT = lo
        build.CDDA_ROM_INFO = rom_renderer.INFO if rom_resident else None
        print(f"      CD-DA 렌더러  {scheduled.OUT.name}")
        if ALL_TRACKS:
            build.CDDA_MINI_ALL = BUILD / "cdda_mini_index_all.bin"
            build.CDDA_TRACK_DIR = BUILD / "cdda_track_directory.bin"
            for f in (build.CDDA_MINI_ALL, build.CDDA_TRACK_DIR):
                if not f.exists():
                    raise SystemExit(
                        f"없다: {f}\n"
                        "  python tools/build_cdda_mini_index_all.py --write 먼저")
            n = build.CDDA_MINI_ALL.stat().st_size // build.CDDA_MINI_STRIDE
            tn = build.CDDA_TRACK_DIR.stat().st_size // build.CDDA_DIR_STRIDE
            print(f"      mini index    {n} 구간 · {tn} 트랙 "
                  f"-> AC ${build.AC_CDDA_MINI:06X}")
            print(f"      트랙 디렉터리 AC ${build.AC_CDDA_DIR:06X} "
                  f"· 트랙 BCD 자리 렌더러 +{build.CDDA_TRACK_BYTE_OFF}")
        else:
            build.CDDA_MINI_INDEX = BUILD / "cdda_track17_mini_index.bin"
            if not build.CDDA_MINI_INDEX.exists():
                raise SystemExit(
                    f"mini index 가 없다: {build.CDDA_MINI_INDEX}\n"
                    "  python tools/build_cdda_track17_mini_index.py --write 먼저")
            n = build.CDDA_MINI_INDEX.stat().st_size // 13
            print(f"      mini index    {n} 구간 -> AC ${build.AC_CDDA_MINI:06X}")
        print(f"      스케줄러      ${lo:04X}  ({note})")
        if rom_resident:
            print(f"      ROM 렌더러   ${rom_renderer.ROM_ORIGIN:04X} · RAM ${rom_renderer.DATA_ORIGIN:04X}")
        print()
        real_main()

    build.main = main_with_scheduler
    print("[2/3] 사슬 (all_in_one -> overlay -> 43)")
    saved, sys.argv = sys.argv, [sys.argv[0], "--version", VERSION, *args]
    try:
        chain.main()
    finally:
        sys.argv = saved
        build.main = real_main
        build.ADPCM_FORCE_RELEASE_AFTER_FRAMES = old_force_release

    print()
    print("[3/3] 다음 단계 -- 순서대로")
    print(f"  python tools/patch_track24_subtitle_pack.py {effective} --write")
    print(f"  python tools/patch_bios_cpu_cache.py {effective} --write")
    print(f"  python tools/patch_bios_cdda_scheduler.py {effective} "
          f"--origin {SCHEDULER_ORIGIN}"
          + (" --all-tracks" if ALL_TRACKS else "") + " --write")
    print("  python tools/verify_adpcm_untouched.py")
    print()
    print("⚠ 실기에 올리기 전에 lua/SUB/0.5.165 로 $ECF9 구간과 AC $1FEB00 을 확인할 것")


if __name__ == "__main__":
    main()
