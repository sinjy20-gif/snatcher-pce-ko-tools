#!/usr/bin/env python3
"""자막이 쓰는 자리를 **한 곳에** 적어 둔다.

왜 한 곳인가
------------
빌더마다 상수를 따로 들고 있었더니 실제로 겹쳤다:

    팩          $1C0000 에 두려고 했다
    글리프 스테이징  엔진과 Lua 가 $1C0000 에 썼다      <- 같은 자리

팩을 아직 AC 에 안 올려서 안 터졌을 뿐이다.  올리는 순간 첫 글자가 팩 머리를
덮는다.  그래서 자리를 먼저 못박는다 -- 적재 경로(부팅 로더)를 설계하려면
**무엇을 어디로 싣는지**가 정해져 있어야 한다.

AC 예약 구역
------------
`manifest.json` 의 `subtitle_reserve_base` · `subtitle_reserve_bytes`.
아케이드 카드가 2 MB 이므로 예약은 맨 뒤 640 KB 다 ($160000-$1FFFFF).

    $160000  팩           576 KB 까지   자막·글꼴·색인.  지금 188 KB
    $1F0000  엔진 이미지     1 KB 까지   상주부가 여기서 $5B80 으로 복사한다
    $1F0400  VRAM 백업      4 KB 까지   음성 중 빌린 VRAM 을 떠 두는 자리
             ($1F0E00 CPU 캐시 · $1F1100 SATB)
    $1F1400  글리프 스테이징  2 KB 까지   ★ 임시.  엔진이 팩을 직접 읽으면 없어진다
    $1F1C00  0.8.4 헬퍼 · $1F1F00 렌더러 · $1F2000 lifecycle POC 백업 (1,152 B)
    $1F2800  ADPCM 네이티브 자막 디렉터리 -> 본문   (2026-09-02 실측 $1F2800-$1FAD33)
    $1FAE00  남는 자리      20 KB

★ 2026-09-02: 예약을 256 KB -> 640 KB 로 넓혔다 (팩 192 -> 576 KB).
  "팩이 192 KB 를 넘을 일은 없다 -- 613 조각이면 약 110 KB" 라던 원래 추산이
  깨졌다.  ADPCM 을 전체화하면서 2,784 조각 188 KB 가 됐고 95 % 가 찼다.
  base 를 내릴 수 있는 근거는 실측이다 -- 대사 번역 이미지가 $132880 에서
  끝나므로 $160000 까지 내려도 186 KB 가 남는다.  넘치면
  `build_snatcher_ko_0_4_5_9` 의 `TRANSLATION_LIMIT` 검사가 먼저 죽는다.

  진짜 배분처는 `build_ac_dynamic_0_1_14.py` 의 `SUBTITLE_AC_BYTES` 하나이고
  (base 는 `AC_BYTES - SUBTITLE_AC_BYTES` 로 역산), 나머지는 전부 그 값의
  복제다.  옮길 때는 이 파일과 함께 build_pack_lba_index · build_subtitle_pipeline
  · build_subtitle_disc_payload · 0_4_7_0_lba_probe · 0_4_5_9(TRANSLATION_LIMIT)
  · 0_8_4(PACK_AT) · lifecycle_poc(AC_BACKUP) 를 같이 본다.

RAM · VRAM 자리
---------------
    $7FA0   상주부 32 B     헬퍼 여유 151 B 안.  디스크에 구워져 있다
    $5B80   엔진 704 B      스크립트 VM 데이터 스택.  **음성 중에만** 빌린다
    VRAM $7900  19 x $40    음성 중에만 빌리고 끝나면 되돌린다

`$5B80` 과 VRAM 은 둘 다 **빌리는** 자리다.  차이는 되돌리기다 -- RAM 은 게임이
알아서 덮지만 VRAM 은 안 지운다 (하이라이트가 음성 뒤에도 깨져 있었다).
"""
from __future__ import annotations

# ---- AC (아케이드 카드) ----
AC_RESERVE_BASE = 0x160000
AC_RESERVE_BYTES = 640 * 1024

AC_PACK = 0x160000            # 팩 통째로
# $1F0000 (엔진) 직전까지.  2026-09-02 에 192 KB -> 576 KB.
AC_PACK_MAX = 0x1F0000 - AC_PACK

# ADPCM native 디렉터가 재생 시작 LBA를 검출하는 전체 마스터.
# native 본문이 커져 예전 $1FB800 자리와 겹친다. 팩 preload 행을
# 연장해 $1E0000에 같이 싣으면 loader 행을 늘리지 않아도 된다.
AC_ADPCM_LBA_MASTER = 0x1E0000

AC_ENGINE = 0x1F0000          # 엔진 이미지 (상주부가 $5B80 으로 복사)
AC_ENGINE_MAX = 1024

AC_VRAM_BACKUP = 0x1F0400     # 음성 중 빌린 VRAM 을 떠 두는 자리
AC_VRAM_BACKUP_MAX = 4096
AC_SATB_BACKUP = 0x1F1100     # VRAM 백업 예약 안: SATB 64개 x 8B
AC_CPU_CACHE_BACKUP = 0x1F0E00 # VRAM 백업 예약 안: $5B80-$5E1E

AC_GLYPH_STAGE = 0x1F1400     # ★ 임시.  엔진이 팩을 직접 읽으면 없어진다
AC_GLYPH_STAGE_MAX = 2048

AC_FREE = 0x1F1C00

# CD-DA ROM renderer가 빌리는 CPU RAM($5CF3-$5E19, 295 B)의 전용 백업.
# helper 슬롯은 $1F1C00-$1F1DBF, renderer 슬롯은 $1F1F00부터이므로
# 그 사이의 정확히 320 B 빈틈 안에 들어간다.  ADPCM의 $1F0E00 캐시와
# 분리해야 CD-DA 재생 중 ADPCM이 끼어도 바깥쪽 CD-DA 스냅샷이 보존된다.
AC_CDDA_ROM_CACHE = 0x1F1DC0
AC_CDDA_ROM_CACHE_MAX = 0x1F1F00 - AC_CDDA_ROM_CACHE

# ---- 상주 헬퍼 슬롯과 control block ----
#
# 왜 한 곳에 모으나
# ------------------
# 예전에는 `HELPER_COMMAND = 173` 같은 **매직 오프셋**이 헬퍼 소스와 상주부 소스에
# 따로 박혀 있었다.  헬퍼 코드가 한 바이트만 늘어도 두 곳이 조용히 어긋난다.
# 그래서 resident 와 helper 가 공유하는 값은 전부 여기 하나로 묶는다.
#
#   · 슬롯 **끝**에 control block 을 둔다.  앞쪽 코드가 아무리 늘어도 안 밀린다
#   · 두 빌더는 이 상수만 import 한다.  숫자를 직접 쓰지 않는다
#
# 슬롯 크기
# ---------
# AC 배치가 helper $1F1C00 · renderer $1F1F00 이라 사이가 768 B 다.
# 448 B 는 그 안이고, 상주부의 copy_fixed 는 divmod(size,256) 이
# (1,64) -> (1,192) 로 **구조가 같아 코드 크기가 안 변한다** (상주부는 151/151 로 꽉 차 있다).
HELPER_SLOT_BYTES = 448

HELPER_CTL = HELPER_SLOT_BYTES - 16        # 432.  끝 16 B 예약
HELPER_CTL_COMMAND = HELPER_CTL + 0        # resident -> helper  (0 저장 · 그 외 복원)
HELPER_CTL_STATUS = HELPER_CTL + 1         # helper -> resident  (1 저장함 · 2 복원함)
HELPER_CTL_WIPE_SEEN = HELPER_CTL + 2      # 진단: 비어 있지 않던 SATB 슬롯 수
HELPER_CTL_WIPE_DONE = HELPER_CTL + 3      # 진단: 실제로 지운 슬롯 수
# 키별 VRAM 배치용. Lua가 음성 gate 직전에 AC helper 슬롯에 쓰고, helper가
# 저장/복원과 SATB 자기-wipe 모두에서 같은 값을 쓴다.  resident는 448 B 전체를
# 그대로 복사하므로 별도 상주부 인터페이스/바이트 증설이 필요 없다.
HELPER_CTL_VRAM_LO = HELPER_CTL + 4
HELPER_CTL_VRAM_HI = HELPER_CTL + 5
HELPER_CTL_PATTERN_BANK = HELPER_CTL + 6
HELPER_CTL_PATTERN_FIRST = HELPER_CTL + 7
# +8 .. +15 helper 전용 scratch 예약

# ---- RAM ----
STUB_CPU = 0x7FA0             # 상주부.  헬퍼 여유 안
STUB_BYTES = 32
ENGINE_CPU = 0x5B80           # 엔진.  음성 중에만
ENGINE_BYTES = 704

# ---- VRAM (워드) ----
PAT_VRAM = 0x1600             # 0.4.26 전구간 감시로 확정한 고정 경로
SATB_VRAM = 0x1000
SATB_BYTES = 64 * 8
MAX_GLYPHS = 19               # VRAM 이 잡는 칸 수 (19 x $40 워드)
SAFE_GLYPHS = 18              # ★ 실제로 쓸 수 있는 칸.  19 를 다 채우면 마지막
                              #   글자가 잘린다 (실측 2026-08-28).  한 칸 비운다
GLYPH_WORDS = 0x40            # 16x16 4 플레인 하나

# 우리 글리프 블록을 가리키는 SATB 항목을 고르는 조건 (헬퍼의 자기검증 wipe 용).
# SATB 의 pattern 필드는 VRAM 워드주소 >> 5 이므로 범위가 한 바이트 안에 들어온다.
# 이 조건이 곧 가드다 -- SATB 가 예상 주소에 없으면 아무것도 안 맞아 0 칸 지운다.
GLYPH_PATTERN_LO = PAT_VRAM >> 5                              # $B0
GLYPH_PATTERN_HI = (PAT_VRAM + MAX_GLYPHS * GLYPH_WORDS - 1) >> 5   # $D5
GLYPH_PALETTE = 0x0F


def regions() -> list[tuple[str, int, int]]:
    return [
        ("팩", AC_PACK, AC_PACK_MAX),
        ("엔진 이미지", AC_ENGINE, AC_ENGINE_MAX),
        ("VRAM 백업", AC_VRAM_BACKUP, AC_VRAM_BACKUP_MAX),
        ("글리프 스테이징", AC_GLYPH_STAGE, AC_GLYPH_STAGE_MAX),
    ]


def check() -> list[str]:
    """자리가 겹치거나 예약을 넘지 않는지."""
    problems = []
    ordered = sorted(regions(), key=lambda r: r[1])
    for (an, aa, ab), (bn, ba, _) in zip(ordered, ordered[1:]):
        if aa + ab > ba:
            problems.append(f"{an}({aa:06X}+{ab}) 이 {bn}({ba:06X}) 를 넘는다")
    last = ordered[-1]
    if last[1] + last[2] > AC_RESERVE_BASE + AC_RESERVE_BYTES:
        problems.append(f"{last[0]} 이 예약 구역을 넘는다")
    return problems


if __name__ == "__main__":
    import sys
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    print(f"AC 예약  ${AC_RESERVE_BASE:06X}-"
          f"${AC_RESERVE_BASE + AC_RESERVE_BYTES - 1:06X}  "
          f"{AC_RESERVE_BYTES // 1024} KB")
    for name, at, size in regions():
        print(f"  ${at:06X}  {size:>7,} B 까지   {name}")
    print(f"  ${AC_FREE:06X}  남는 자리")
    print()
    print(f"RAM   ${STUB_CPU:04X} 상주부 {STUB_BYTES} B · "
          f"${ENGINE_CPU:04X} 엔진 {ENGINE_BYTES} B (음성 중에만)")
    print(f"VRAM  ${PAT_VRAM:04X} 부터 {MAX_GLYPHS} x ${GLYPH_WORDS:X} 워드 "
          f"(음성 중에만 · 되돌린다)")
    bad = check()
    print()
    print("겹침 없음" if not bad else "★ " + " · ".join(bad))
