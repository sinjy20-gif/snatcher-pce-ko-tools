#!/usr/bin/env python3
"""0.4.6.61: 지금 스튜디오 마스터로 수집용 key-VRAM 디스크를 다시 굽는다.

왜
--
`0.4.6.22-dictionary-key-vram` 은 08-30 마스터다.  미수집 대사를 찾으러 돌 때
그 뒤에 번역된 것도 화면에 일본어로 남아 구분이 안 된다.  (수집기 MISSONLY 는
정적 대장으로 거르므로 그쪽은 `tools/refresh_runtime_static_index.py` 로 이미
해결했지만, 눈으로 보며 도는 작업에는 최신 디스크가 편하다.)

체인
----
2026-09-01 에 `build_snatcher_ko_0_4_5_8.py` 가 없어서 마스터 -> 디스크 경로가
통째로 끊겨 있었다.  환경 A에서 가져와 복구했다.  이 스크립트는 그 위에 세 단계를
연달아 돌린다.

    1  0.4.5.12 계열   마스터를 디스크에 굽는다      -> EXPERIMENT/0.4.6.61-...-unpatched
    2  0.4.6.21 계열   448 B 헬퍼 인터페이스 preload -> 0.4.6.61-reviewed-dictionary
    3  0.4.6.22 계열   상주부 0.8.5 + key-VRAM 헬퍼  -> 0.4.6.61-dictionary-key-vram

★ 번역 입력은 **스튜디오를 직접** 본다 (`snatcher_tool/translation`).
  옛 체인은 `build/work/0.4.6.13-reviewed/translation` 스냅샷을 봤는데, 그것이
  낡는 것이 애초에 이 문제의 절반이었다.

★ 기존 `0.4.6.22-dictionary-key-vram` 은 건드리지 않는다 -- 새 폴더로 낸다.

    python tools/build_snatcher_0_4_6_61_dictionary_key_vram.py
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "extraction" / "patch" / "static")]

VERSION = "0.4.6.61"
TRANSLATION = ROOT / "snatcher_tool" / "translation"
STAGE1 = f"ac_0.1.12-source-{VERSION}-reviewed-dictionary"
UNPATCHED = ROOT / "build" / "patch" / "EXPERIMENT" / f"{VERSION}-reviewed-dictionary-unpatched"
PRELOAD_OUT = ROOT / "build" / "patch" / f"{VERSION}-reviewed-dictionary"
FINAL_OUT = ROOT / "build" / "patch" / f"{VERSION}-dictionary-key-vram"

CANONICAL = ("snatcher_ko_master.tsv", "ui_text.tsv",
             "speaker_name_standard.tsv", "master_conflict_exclusions.tsv")


def banner(step: int, text: str) -> None:
    print(f"\n{'=' * 68}\n[{step}/3] {text}\n{'=' * 68}", flush=True)


def step1() -> None:
    """마스터를 디스크에 굽는다 (0.4.5.12 가 하던 일 · 입력만 스튜디오로 바꾼다)."""
    banner(1, f"마스터 -> 디스크   {UNPATCHED.name}")
    import os
    os.environ.setdefault("SNATCHER_KO_BIOS", "1")
    import build_snatcher_ko_0_4_5_8 as base

    base.VERSION = f"{VERSION}-reviewed-dictionary"
    base.STAGE1_VERSION = STAGE1
    base.STAGE1_BUILD = ROOT / "build" / "patch" / STAGE1
    base.OUT = UNPATCHED
    base.PROTECTED.update({base.VERSION, base.STAGE1_VERSION})
    base.TRANSLATION = TRANSLATION
    base.CANONICAL_INPUTS = tuple(TRANSLATION / name for name in CANONICAL)
    missing = [p for p in base.CANONICAL_INPUTS if not p.exists()]
    if missing:
        raise SystemExit("번역 입력이 없다:\n  " + "\n  ".join(str(p) for p in missing))
    print(f"  번역 입력  {TRANSLATION}")
    for p in base.CANONICAL_INPUTS:
        print(f"    {p.name:34s} {sum(1 for _ in p.open('rb')):6d} 행")
    base.main()


def step2() -> None:
    """448 B 헬퍼 인터페이스 preload (0.4.6.21 이 하던 일)."""
    banner(2, f"헬퍼 인터페이스 preload   {PRELOAD_OUT.name}")
    if not UNPATCHED.is_dir():
        raise SystemExit(f"1 단계 산출물이 없다: {UNPATCHED}")
    import build_snatcher_0_4_6_11 as release

    name = f"{VERSION}-reviewed-dictionary"
    bios_name = f"Syscard3_galmuri_{name}.pce"
    base = release.base
    boot = base.boot
    base.VERSION = name
    base.BASE = UNPATCHED
    base.OUT = PRELOAD_OUT
    base.BIOS_NAME = bios_name
    base.GUARD_MAGIC = (0x6C,)
    boot.BASE = UNPATCHED
    boot.OUT = PRELOAD_OUT
    boot.TRANSLATION_IMAGE = UNPATCHED / "ac_dynamic_packs" / "disc_package_image.bin"
    boot.BIOS = PRELOAD_OUT / bios_name
    boot.BIOS_INFO = PRELOAD_OUT / "bios_preload.json"
    boot.APPEND_RAW = boot.BUILD / f"subtitle_track24_append_{name}.raw"
    boot.APPEND_USER = boot.BUILD / f"subtitle_track24_append_{name}.user.bin"
    boot.REVISION = name
    boot.DISPLAY = name
    boot.DISC_TAG = "KO"
    boot.collection.BASE = UNPATCHED
    boot.collection.SOURCE02 = next(UNPATCHED.glob("*Track 02*.bin"))
    boot.collection.SOURCE24 = next(UNPATCHED.glob("*Track 24*.bin"))
    release.OUT = PRELOAD_OUT
    release.BIOS = PRELOAD_OUT / bios_name
    release.main()


def step3() -> None:
    """상주부 0.8.5 + key-VRAM 헬퍼 (0.4.6.22 가 하던 일)."""
    banner(3, f"상주부 0.8.5 + key-VRAM 헬퍼   {FINAL_OUT.name}")
    if not PRELOAD_OUT.is_dir():
        raise SystemExit(f"2 단계 산출물이 없다: {PRELOAD_OUT}")
    import build_snatcher_0_4_6_22_dictionary_key_vram as keyvram

    keyvram.BASE = PRELOAD_OUT
    keyvram.OUT = FINAL_OUT
    keyvram.main()


def step0() -> None:
    """★ LBA 색인을 매 빌드마다 다시 만든다 (2026-09-02).

    이전에는 수동 단계였다.  그래서 그 자리에 있던 낡은 색인이 조용히 빌드에
    들어갔다.  audio_length 가 16 비트라 64 KB 초과 음성은 FFxx 로 포화하고,
    그 값으로 start_lba 를 계산하면 시작 섹터가 최대 94 섹터까지 밀린다.
    디스패처는 LBA 로 먼저 거르므로 그 음성들이 통째로 미스가 된다.

    빌더가 실측 바이트로 고치도록 바뀌었으니 빌드가 늘 부르게 한다.
    입력(v014 로그)이 없으면 빌더가 알아서 옛 동작으로 물러난다.
    """
    banner(0, "LBA 색인 재생성")
    import build_adpcm_lba_master_index as lba
    saved = sys.argv[:]
    sys.argv = [saved[0]]
    try:
        lba.main()
    finally:
        sys.argv = saved


def main() -> None:
    only = sys.argv[1] if len(sys.argv) > 1 else ""
    steps = {"0": (step0,), "1": (step1,), "2": (step2,), "3": (step3,)}.get(
        only, (step0, step1, step2, step3))
    # ★ 각 단계의 main() 이 제 argparse 를 돌린다 (base.main 은 --stage3/--check/
    #   --prune/--deep/--space/--tag 를 받는다).  우리 단계 선택 인자가 거기로
    #   새면 "unrecognized arguments" 로 죽는다.  넘기기 전에 비운다.
    sys.argv = sys.argv[:1]
    for fn in steps:
        fn()
    print(f"\n완료.  BIOS 와 cue 는 {FINAL_OUT} 에 있다.")


if __name__ == "__main__":
    main()
