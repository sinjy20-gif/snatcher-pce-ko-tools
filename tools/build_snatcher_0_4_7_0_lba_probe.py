#!/usr/bin/env python3
"""0.4.7.0: 네이티브 LBA 조회 **관측 전용** POC (게임 동작에 영향 0).

왜 이 단계가 따로 필요한가
--------------------------
0.4.6.26 과 0.4.6.27 은 둘 다 "정적 빌드·디스어셈 통과 -> 실기 크래시" 였다.
공통 원인은 **한 번에 여러 개를 넣은 것**이다.  실패했을 때 원인이 감지기인지
가드인지 조회인지 갈라지지 않았다 (BASELINE §11.8 · §11.9).

이 판은 **아무것도 바꾸지 않는다.**  자막을 켜지 않고, state 를 안 건드리고,
selector 도 안 쓴다.  오직 다음만 한다.

    AD_PLAY 도중 SCSI CDB 의 LBA 3 B 를 읽는다
    -> 팩의 LBA 색인을 이분 검색한다
    -> **결과를 AC 관측 슬롯에 적기만 한다**

Lua 가 그 슬롯을 읽어 진짜 키와 대조한다.  네이티브 경로(뱅크 다리 · AC 접근 ·
이분 검색)가 실기에서 옳은 답을 내는지를 **위험 0 으로** 판정한다.
이것이 통과해야 selector 기입과 state 로 넘어간다.

근거 (BASELINE §12)
-------------------
```
음성의 시작 LBA 3 B  =  SCSI CDB $224D/$224E/$224F   (MSB first)
자막 대상 음성 커버리지            26/26  (0.5.34 실기)
적재 명령은 항상 직전 명령          27/27
이분 검색 오프라인 채점            902/902 정답 · 헛적중 0/4463 · 최대 10 단계
```

훅 자리 -- `$F5F2` 가 아니라 `$F5F5`
------------------------------------
```
$F5F2  8D AA 22   STA $22AA     <- A(rate) 를 쓴다.  다리가 A 를 부순다
$F5F5  AE A8 22   LDX $22A8     <- X 만 쓴다.  다리는 X 를 안 건드린다  ★ 여기
```
`$FFD4` 다리는 `PHP / SEI / LDA #$01 / TAM #$80` 이라 A 를 먼저 파괴한다.

뱅크 다리 규약 (기존 사용자 $F054 에서 실측)
--------------------------------------------
```
뱅크0 $FFD4  PHP / SEI / LDA #$01 / TAM #$80      MPR7 <- 뱅크1, $FFDA 로 이어짐
뱅크1 $FFDA  JMP <디스패처>
뱅크1 종료   PHA / LDA #$00 / JMP $F04E           ★ A 를 밀고 나간다
뱅크1 $F04E  TAM #$80  ->  뱅크0 $F050  PLA / PLP / RTS
```
`$FFDA` 는 지금 `JMP $F054`(reception repair) 하나뿐이라 둘을 받아야 한다.
**스택의 복귀주소로 호출자를 가른다** -- 우리 훅은 `$F5F7` 을 민다.

SEI 안에서 도는 코드다 -- 그래서 이분 검색이다
----------------------------------------------
다리가 `SEI` 로 들어간다.  902 항목 선형 검색은 약 1.8 ms (프레임의 11%) 로
오늘 잡은 SEI/RCR 문제를 그대로 부른다 (FLICKER §7-F).  색인을 LBA 오름차순으로
구워 둔 덕에 **10 단계**로 끝난다.

지역변수 -- 왜 스택인가
-----------------------
뱅크 6A 에도, `$7FE8-$7FFF` 에도 빈 자리가 없다 (0.5.30 실측: 24 B 전부 게임이
쓴다).  그래서 스택에 8 B 를 잡고 `TSX` 로 잡은 `X` 를 인덱스로 쓴다.
`SEI` 안이라 인터럽트가 스택을 건드리지 않는다.

    ★ 중간값(t)도 같은 지역변수에 둔다.  그래야 X 가 끝까지 고정된다.
      (첫 설계는 mid*9 계산에 `TAX` 를 써서 인덱스를 잃었다)

관측 슬롯 (AC $1F2200)
----------------------
```
+0    status  $00 아직 · $A1 찾음 · $A0 못찾음
+1~3  읽은 LBA (MSB first)
+4~9  찾은 6 B 키 (못 찾으면 그대로 둠)
+10   탐색 단계 수
```
`$1F1C00` helper · `$1F1F00` renderer(672 B, ~$1F21A0) 뒤라 겹치지 않는다.
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_subtitle_engine as engine_base   # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
PACK_LBA = ROOT / "build" / "cutscene_subs" / "subtitle_pack_lba.bin"

BANK1_FREE_LO, BANK1_FREE_HI = 0xF0EA, 0xFC76      # 실측 FF 연속 2,957 B
DISPATCH_AT = 0xFFDA                                # 뱅크1: 지금 JMP $F054
REPAIR = 0xF054
EXIT_BRIDGE = 0xF04E

HOOK = 0xF5F5
HOOK_ORIG = bytes((0xAE, 0xA8, 0x22))               # LDX $22A8
HOOK_RET = HOOK + 2                                 # JSR 가 미는 값 = $F5F7

# 두 번째 훅 -- AD_CPLAY ($E03F)
# ------------------------------
# 2026-09-03: BIOS 의 ADPCM 재생 진입점은 **둘**이다.  점프표가 그렇게 말한다.
#
#     $E03C  JMP $F5C6   AD_PLAY    ADPCM RAM 에 실린 것을 튼다   -> 훅 $F5F5
#     $E03F  JMP $F61F   AD_CPLAY   CD 에서 흘려보내며 튼다       -> ★ 여기
#
# AD_CPLAY 는 `LDA #$FF / STA $1808 / STA $1809` 로 링버퍼 끝을 $FFFF 로 열어
# 두고 32 섹터씩 먹인다.  그래서 이 계열 키가 전부 `..._FFFF_..` 로 잡힌다.
# 자막이 안 뜨던 173 건이 이것이다 -- 감지가 **실패**한 게 아니라 감지 루틴을
# 아예 **안 탔다** (0.5.142 실측: `CTRL pc=$F68A` · `$F5EC/$F5E7 KEYW` 전무).
# 그래서 A2 를 받아주는 fallback 은 금지다.  그것은 직전 음성을 다시 잡는다.
#
#     $F680  A9 0C       LDA #$0C
#     $F682  0C 02 18    TSB $1802
#     $F685  A9 60       LDA #$60     ★ A 가 상수다 -- 다리가 A 를 부숴도 된다
#     $F687  8D 0D 18    STA $180D    ★ 훅 자리 (정확히 3 B)
#     $F68A  62          CLA          복귀 지점.  A 를 바로 지운다
#     $F68B  60          RTS
#
# $F5F5 를 고른 기준은 "다리가 A 를 부순다" 였다.  여기서는 밀려난 명령이 A 를
# **쓰지만** 그 값이 바로 위의 상수 $60 이라 훅 안에서 다시 만들면 된다.
# 복귀 직후 `CLA` 가 A 를 지우므로 우리가 무엇을 밀고 나가든 무의미하고,
# 다리의 `PHP`/`PLP` 가 `LDA #$60` 이 남긴 플래그를 그대로 돌려준다.
#
# 정적으로 전수 확인한 것 (2026-09-03)
#     $F686..$F689 로 들어오는 분기·점프·BSR   전 이미지 0 건
#     $F61F 의 호출자                          $E03F 점프표 하나뿐
#     X 는 이 경로에서 이미 죽어 있다          $F64C JSR $F37F · $F664 JSR $F393
#     $224D..$224F 는 이 경로에서도 그 음성의 LBA  (0.5.143: $003123 디렉터리 HIT)
HOOK_CPLAY = 0xF687
HOOK_CPLAY_ORIG = bytes((0x8D, 0x0D, 0x18))         # STA $180D
HOOK_CPLAY_RET = HOOK_CPLAY + 2                     # $F689
CPLAY_A = 0x60                                      # $F685 의 LDA #$60
ADPCM_CTRL = 0x180D

CDB_LBA = 0x224D
ADPCM_ADDR = 0x22A8

# ★ 2026-09-03: 국장실 뒷화면 소환 고침 -- 무거운 arm 작업을 줄 148 뒤로 옮긴다.
#
# 왜: arm 1 회가 엔진 671 B 를 두 번 옮긴다 (AC->AC 복사 + precopy TIA AC->CPU).
#     뱅크1 에서 4,300 명령 ≈ 57 스캔라인.  줄 24 에서 시작하므로 **줄 32 의
#     래스터 IRQ 를 밀어낸다** -> 그 프레임만 그림 창 스크롤(BYR=96)이 늦게 닿아
#     화면 위쪽이 옛 스크롤(타일맵 꼭대기 = 천장)로 그려진다.
#     원본 BIOS 는 10,016 프레임 전부 줄 32 다 (0.5.157).  우리만 0.64% 가 밀린다.
#
# 어디에: $E41F 는 BIOS 의 "RCR 설정" 미니 서브루틴이다.  프레임당 정확히 3 번
#     불리고 (RCR lo = 71 / 199 / 212), 그중 **212(화면줄 148) 호출이 줄 160** 이다.
#     거기서 줄 250 까지 약 90 줄 ≈ 40,900 cyc 가 비어 있다.
#
#     $E41F  48        PHA          <- 밀려난 명령 ①  (A = RCR lo)
#     $E420  A9 06     LDA #$06     <- 밀려난 명령 ②
#     $E422  85 F7     STA $F7
#     ...
#
# ★ 훅 자리를 고르는 데 세 번 갈아탔다.  이유를 남긴다:
#
#   $E41F (PHA / LDA #$06)   ✗ 밀려난 명령이 **스택을 건드린다**.  게다가 진입 시
#                              A 가 RCR lo 인데 디스패처 두 번째 명령(LDA $2103,X)이
#                              그것을 덮는다 -> A 를 어딘가 맡겨야 하고, 맡길 CPU RAM
#                              을 눈대중으로 고르는 것이 바로 문서가 경고하는 함정이다
#                              ("쓰기가 없다는 것은 빈 자리라는 뜻이 아니다",
#                               CUTSCENE_SUBS_2026-08-19 §545)
#   $E42B (STX $0003)        ✗ 디스패처가 TSX 로 X 를 덮어 밀려난 STX 를 재현 못 한다
#   $E424 (STA $0000)        ✓ **채택.**  그 시점 A 는 상수 $06 이고 RCR 값은 이미
#                              스택에 안전하게 밀려 있다.  밀려난 명령이 STA 라
#                              기존 훅($F5F5 LDX · $F687 STA)과 성격이 같다.
#                              $F7 그림자도 $E422 에서 이미 $06 으로 맞춰져 있다
HOOK_RCR = 0xE424
HOOK_RCR_ORIG = bytes((0x8D, 0x00, 0x00))           # STA $0000 (VDC 레지스터 선택)
HOOK_RCR_RET = HOOK_RCR + 2                         # $E426  (상위 $E4 -- 안 겹친다)
RCR_SEL_IMM = 0x06                                  # 밀려난 STA 직전의 A (= 레지스터 6)

# 호출 구분 -- A 를 못 쓰므로 **호출 순번**으로 가른다.
#   $E424 는 프레임당 정확히 3 번 불린다 (화면줄 135@줄32 · 148@줄160 · 7@줄250).
#   FEC4(줄 24 · 프레임당 1 회)에서 0 으로 되돌리고, 여기서 +1 한 값이 2 면 줄 160 이다.
# ⚠ 스크래치는 **CPU RAM 이 아니라 AC** 에 둔다.  AC 는 우리 것이고 슬롯 옆이 비어 있다.
#   비용은 호출당 약 60 cyc · 프레임당 180 cyc = 0.4 스캔라인.  무해하다.
# ⚠ $1F2710 을 먼저 골랐다가 물릴 뻔했다 -- 거기는 `AC_SCHED` 7 B 다.  AC $1F27xx 지도:
#     $1F2700  관측 슬롯 (코드가 +12 까지 쓴다)
#     $1F2710  AC_SCHED 7 B                       (0_4_6_29_native_arm)
#     $1F2720  CD-DA 시계 (매직 5A A5 + elapsed)  (0_4_6_5x_cdda_lease)
#     $1F2800  디렉터리
#   -> 빈 곳은 $1F2717~$1F271F.  가운데를 쓴다.
AC_RCR_STATE = 0x1F2718      # +0 (안 씀) · +1 지연 arm 대기 플래그 · +2~4 LBA
RCR_SLOT_INDEX = 2           # (옛 방식) 순번 판별 -- 더 안 쓴다

# ★★ 2026-09-03: **순번이 아니라 RCR 값으로 가른다.**
#
#   옛 방식은 "$E424 는 프레임당 정확히 3 번" 을 전제하고 호출 순번을 셌다.
#   실기에서 프레임 끝 순번이 0 · 2 · 3 으로 흔들렸다 -- 리셋(FEC4)과 호출의
#   순서가 장면마다 달라서다.  그러면 엉뚱한 줄에서 무거운 arm 이 터지고,
#   게임이 AC 를 쓰는 스캔라인 40~119 에 걸리면 채널 0 포인터가 밟혀
#   이분 검색이 miss 로 끝난다 (0.4.6.74/.76 에서 자막 전멸).
#
#   그런데 **어느 호출인지는 스택에 그대로 있다.**  $E41F 의 PHA 가 RCR lo 를
#   밀어 두기 때문이다.  디스패처가 TSX 한 X 기준으로:
#
#       $2101,X  P           (다리의 PHP)
#       $2102,X  JSR ret lo  ($26)      <- 기존 복귀주소 판별이 쓰는 자리
#       $2103,X  JSR ret hi  ($E4)
#       $2104,X  ★ RCR lo    ($E41F 의 PHA 가 민 값)
#
#   0.5.164 실측 (0.4.6.72 · 4,500 프레임):
#       RCR lo=212 X=0 line 160   ★ 우리 자리 -- 212 는 여기서만 나온다
#       RCR lo=199 X=0 line 250 · 71 X=0 line 250 · 64 X=0 line 31
#       X 는 전 조합에서 0 -> rcr_tail 의 LDX #$00 근거 확보
#
#   값으로 가르면 장면·호출수·리셋순서와 전부 무관해진다.  AC 순번 바이트와
#   프레임당 리셋 코드가 통째로 필요 없어진다.
RCR_STACK_A = 0x2104         # TSX 한 X 기준 -- $E41F 이 밀어 둔 RCR lo
RCR_MATCH_LO = 212           # 화면줄 148 예약 = 줄 160 호출

AC_PACK = 0x160000   # 단일 출처는 tools/subtitle_layout.py
AC_SLOT = 0x1F2700          # 관측 슬롯 11 B
AC_INDEX = 0x1F2800         # ★ POC 에서 Lua 가 올려주는 LBA 색인 자리
# ★★ 자리를 고를 때 **데이터 끝이 아니라 섹터 끝**을 본다 (0.5.42 로 물린 것)
#   선적재는 CD 를 섹터(2048 B) 단위로 읽는다.  실데이터가 짧아도 그 뒤의
#   패딩(FF)까지 통째로 AC 에 실린다.
#
#       subtitle_helper    $1F1C00 + 1섹터 -> $1F1C00-$1F23FF   (실데이터 448 B)
#       subtitle_renderer  $1F1F00 + 1섹터 -> $1F1F00-$1F26FF   (실데이터 671 B)
#
#   옛 자리 $1F2400 은 "renderer 가 $1F21A0 에서 끝나니 안 겹친다" 고 보고 잡았다.
#   **틀렸다.**  renderer 의 섹터는 $1F26FF 까지고, $1F2400 은 그 패딩 한복판이라
#   부팅/재적재 때마다 FF 로 지워졌다.  BIOS 가 FF 를 읽은 것은 정상이었다.
#   -> 안전 시작선은 $1F2700.  902 x 9 = 8,118 B -> $1F47F5 까지 쓴다
STRIDE = 9
MAX_PROBES = 12

ST_FOUND, ST_MISS = 0xA1, 0xA0

# ★ 버전 도장.  디스패처가 관측 슬롯 +11 에 자기 번호를 적는다.
#   BIOS 를 몇 번 다시 구워도 Lua 가 "지금 로드된 것이 무엇인지" 를 확인할 수 있다.
#   0.4.7.0  최초        (PROBE 가 T+1 과 겹쳐 전부 miss)
#   0.4.7.1  PROBE 분리 + 동적 읽기값 진단(RD)
#   0.4.7.2  + 고정주소 읽기 대조(FX)  -> AC 가 FF.  MPR0 은 $FF 로 정상이었다
#   0.4.7.3  (건너뜀)
#   0.4.7.4  ★ 정렬 시험 -- 고정주소에서 4 B 를 읽어 그대로 뱉는다.
#            슬롯의 LBA 가 맞게 찍힌다 = AC **쓰기**는 된다.  그러므로
#            "AC 가 안 닿는다" 는 틀렸다.  동적 읽기 FF 3C F7 은 첫 바이트만 FF 다.
#            -> 포인터를 세운 뒤 첫 읽기가 더미로 버려지는가를 본다.
#               4 B 가 FF 00 30 6B 로 나오면 그렇다 (한 칸 밀림).
VERSION = "0.4.6.27"
# ★ BUILD_ID 는 손으로 적지 않는다.  VERSION 의 마지막 칸에서 유도한다.
#   두 상수를 따로 두면 하나만 깜빡했을 때 **도장이 거짓말을 한다** --
#   2026-08-30 밤에 실제로 그것 때문에 헤맸다 (엉뚱한 BIOS 를 로드했는데
#   BUILD 가 $00 으로 나와 원인 판정이 한 바퀴 늦어졌다).
BUILD_ID = int(VERSION.rsplit(".", 1)[1]) & 0xFF
if not (0 <= BUILD_ID <= 0xFF):
    raise SystemExit(f"VERSION 마지막 칸이 한 바이트를 넘는다: {VERSION}")

# 스택 지역변수 배치 ($2100 + n, X)
#
# ★ PROBE 를 T+1 과 겸용했다가 실기에서 물렸다 (0.5.35 1차 주행).
#   T 는 매 바퀴 mid*9 로 덮이는데 mid=901 이면 T+1 = 31 이 된다.
#   그러면 다음 바퀴의 단계 상한(12)에 즉시 걸려 전부 miss 가 났다.
#   -> 카운터는 반드시 독립된 자리여야 한다.
LO, HI, MID, T, PROBE, RD, FX = 1, 3, 5, 7, 9, 10, 13
LOCALS = 16                                    # RD 3 B (동적) · FX 4 B (고정주소 정렬시험)


def ac_ptr_const(a, addr: int) -> None:
    """AC 포인터를 상수 주소로 세우고 자동증가를 켠다."""
    for shift, port in ((0, 0x1A02), (8, 0x1A03), (16, 0x1A04)):
        a.emit(0xA9, (addr >> shift) & 0xFF)
        a.abs_(0x8D, port)
    a.emit(0xA9, 0x01); a.abs_(0x8D, 0x1A07)
    a.abs_(0x9C, 0x1A08)
    a.emit(0xA9, 0x11); a.abs_(0x8D, 0x1A09)


def ac_ptr_from_T(a, base: int) -> None:
    """AC 포인터를 base + T 로 세운다.  T 는 지역변수 2 B."""
    a.emit(0x18)                                        # CLC
    a.abs_(0xBD, 0x2100 + T); a.emit(0x69, base & 0xFF)
    a.abs_(0x8D, 0x1A02)
    a.abs_(0xBD, 0x2100 + T + 1); a.emit(0x69, (base >> 8) & 0xFF)
    a.abs_(0x8D, 0x1A03)
    a.emit(0xA9, (base >> 16) & 0xFF); a.emit(0x69, 0x00)   # 캐리 전파
    a.abs_(0x8D, 0x1A04)
    a.emit(0xA9, 0x01); a.abs_(0x8D, 0x1A07)
    a.abs_(0x9C, 0x1A08)
    a.emit(0xA9, 0x11); a.abs_(0x8D, 0x1A09)


def build_dispatcher(origin: int, index_base: int, index_count: int,
                     labels: dict[str, int] | None = None, *,
                     extra_return: int | None = None, extra_builder=None,
                     extra_return2: int | None = None, extra_builder2=None,
                     cplay_return: int | None = None,
                     rcr_return: int | None = None, rcr_builder=None):
    a = engine_base.Asm(origin, labels)

    # ---- 호출자 판별.  스택: [P][PCL][PCH] (PHP 가 마지막) -------------
    # 복귀주소 상위 바이트가 서로 다르다 ($F5 · $F6 · $FE) -- 겹칠 자리가 없다.
    has_extra = extra_return is not None or extra_return2 is not None
    has_cplay = cplay_return is not None
    has_rcr = rcr_return is not None
    # 판별 사슬의 끝은 rcr -> extra -> bail 순이다.  rcr 은 프레임당 3 번 불리므로
    # **제일 나중에** 검사해서 다른 훅의 유휴 비용을 안 늘린다.
    tail_of_chain = "check_rcr" if has_rcr else "bail"
    after_ours = ("check_cplay" if has_cplay else
                  "check_extra" if has_extra else tail_of_chain)
    a.emit(0xBA)                                          # TSX
    a.abs_(0xBD, 0x2103); a.emit(0xC9, (HOOK_RET >> 8) & 0xFF)
    a.branch(0xD0, after_ours)
    a.abs_(0xBD, 0x2102); a.emit(0xC9, HOOK_RET & 0xFF)
    a.branch(0xF0, "ours")
    if has_cplay:
        # AD_CPLAY 는 **같은 몸통**으로 보낸다.  이분 검색을 복사하지 않는다 --
        # 한 벌만 두어야 둘이 조용히 갈라질 일이 없다.  다른 것은 꼬리에서
        # 실행할 **밀려난 명령** 하나뿐이고, 그것도 복귀주소로 다시 가른다.
        a.label("check_cplay")
        a.abs_(0xBD, 0x2103); a.emit(0xC9, (cplay_return >> 8) & 0xFF)
        a.branch(0xD0, "check_extra" if has_extra else tail_of_chain)
        a.abs_(0xBD, 0x2102); a.emit(0xC9, cplay_return & 0xFF)
        a.branch(0xF0, "ours")
    if has_extra:
        a.label("check_extra")
        if extra_return is not None:
            a.abs_(0xBD, 0x2103); a.emit(0xC9, (extra_return >> 8) & 0xFF)
            a.branch(0xD0, "check_extra2" if extra_return2 is not None else tail_of_chain)
            a.abs_(0xBD, 0x2102); a.emit(0xC9, extra_return & 0xFF)
            a.branch(0xD0, "check_extra2" if extra_return2 is not None else tail_of_chain)
            a.emit(0x4C); a.word("extra")
        if extra_return2 is not None:
            a.label("check_extra2")
            a.abs_(0xBD, 0x2103); a.emit(0xC9, (extra_return2 >> 8) & 0xFF)
            a.branch(0xD0, tail_of_chain)
            a.abs_(0xBD, 0x2102); a.emit(0xC9, extra_return2 & 0xFF)
            a.branch(0xD0, tail_of_chain)
            a.emit(0x4C); a.word("extra2")
        a.emit(0x4C); a.word(tail_of_chain)
    if has_rcr:
        # ★ 2026-09-03: BIOS 의 RCR 설정 루틴 $E424 (STA $0000).
        #   프레임당 3 번 불린다.  여기서는 **복귀주소만** 가르고, 어느 호출인지는
        #   rcr_builder 가 AC 순번으로 판정한다 (A 는 이미 덮여 있어 못 쓴다).
        a.label("check_rcr")
        a.abs_(0xBD, 0x2103); a.emit(0xC9, (rcr_return >> 8) & 0xFF)
        a.branch(0xD0, "bail")
        a.abs_(0xBD, 0x2102); a.emit(0xC9, rcr_return & 0xFF)
        a.branch(0xD0, "bail")
        a.emit(0x4C); a.word("rcr")
    a.label("bail")
    a.emit(0x4C); a.word(REPAIR)                          # 기존 사용자에게
    a.label("ours")

    # ---- 지역변수 8 B 확보 -> X 고정 -----------------------------------
    for _ in range(LOCALS):
        a.emit(0x48)                                      # PHA
    a.emit(0xBA)                                          # TSX

    # ★ 포트 관용구 자체를 시험한다 -- 색인 첫 항목을 **고정 주소**로 읽는다.
    #   00 30 6B 가 나오면 관용구는 맞고 문제는 T(mid*9) 계산이다.
    #   아니면 관용구/주소 규약이 틀렸다.
    # ★ 정렬 시험: 고정 주소에서 **4 B** 를 연달아 읽어 그대로 남긴다.
    #   표 첫 항목은 00 30 6B 00 이다.
    #     00 30 6B 00 -> 정렬 정상
    #     FF 00 30 6B -> 첫 읽기가 더미.  한 칸 밀린다
    ac_ptr_const(a, index_base)
    for i in range(4):
        a.abs_(0xAD, 0x1A00); a.abs_(0x9D, 0x2100 + FX + i)

    # lo = 0 · hi = count-1
    a.emit(0xA9, 0x00)
    a.abs_(0x9D, 0x2100 + LO); a.abs_(0x9D, 0x2100 + LO + 1)
    a.emit(0xA9, (index_count - 1) & 0xFF); a.abs_(0x9D, 0x2100 + HI)
    a.emit(0xA9, ((index_count - 1) >> 8) & 0xFF); a.abs_(0x9D, 0x2100 + HI + 1)
    # 탐색 단계 수는 T 상위에 임시로 센다 -> 나중에 관측 슬롯으로
    a.emit(0xA9, 0x00); a.abs_(0x9D, 0x2100 + PROBE)

    a.label("loop")
    # 단계 상한 (무한루프 방지)
    a.abs_(0xBD, 0x2100 + PROBE); a.emit(0x1A); a.abs_(0x9D, 0x2100 + PROBE)
    a.emit(0xC9, MAX_PROBES); a.branch(0x90, "probe_ok")
    a.emit(0x4C); a.word("miss")
    a.label("probe_ok")

    # hi < lo 이면 없음  (16-bit 비교)
    a.abs_(0xBD, 0x2100 + HI + 1); a.abs_(0xDD, 0x2100 + LO + 1)
    a.branch(0x90, "range_bad")                           # hi_hi < lo_hi
    a.branch(0xD0, "cmp_ok")                              # hi_hi > lo_hi
    a.abs_(0xBD, 0x2100 + HI); a.abs_(0xDD, 0x2100 + LO)
    a.branch(0xB0, "cmp_ok")
    a.label("range_bad")
    a.emit(0x4C); a.word("miss")
    a.label("cmp_ok")

    # mid = (lo + hi) >> 1
    a.emit(0x18)
    a.abs_(0xBD, 0x2100 + LO); a.abs_(0x7D, 0x2100 + HI); a.abs_(0x9D, 0x2100 + MID)
    a.abs_(0xBD, 0x2100 + LO + 1); a.abs_(0x7D, 0x2100 + HI + 1)
    a.abs_(0x9D, 0x2100 + MID + 1)
    a.abs_(0x5E, 0x2100 + MID + 1); a.abs_(0x7E, 0x2100 + MID)

    # T = mid * 9  =  (mid << 3) + mid
    a.abs_(0xBD, 0x2100 + MID); a.abs_(0x9D, 0x2100 + T)
    a.abs_(0xBD, 0x2100 + MID + 1); a.abs_(0x9D, 0x2100 + T + 1)
    for _ in range(3):
        a.abs_(0x1E, 0x2100 + T); a.abs_(0x3E, 0x2100 + T + 1)
    a.emit(0x18)
    a.abs_(0xBD, 0x2100 + T); a.abs_(0x7D, 0x2100 + MID); a.abs_(0x9D, 0x2100 + T)
    a.abs_(0xBD, 0x2100 + T + 1); a.abs_(0x7D, 0x2100 + MID + 1)
    a.abs_(0x9D, 0x2100 + T + 1)

    # AC 포인터 = index_base + T · 3 B 비교 (MSB first)
    ac_ptr_from_T(a, index_base)
    for i in range(3):
        a.abs_(0xAD, 0x1A00)                              # LDA AC (자동증가)
        a.abs_(0x9D, 0x2100 + RD + i)                     # ★ 읽은 값을 남긴다 (진단)
        a.abs_(0xCD, CDB_LBA + i)                         # CMP $224D+i
        a.branch(0xD0, f"neq{i}")
    a.emit(0x4C); a.word("found")

    # 세 바이트 중 한 곳에서 갈렸다.  entry < target 이면 lo = mid+1
    for i in range(3):
        a.label(f"neq{i}")
        a.branch(0x90, "go_lo")                           # BCC: entry < target
        a.branch(0x80, "go_hi")

    a.label("go_lo")                                      # lo = mid + 1
    a.emit(0x18)
    a.abs_(0xBD, 0x2100 + MID); a.emit(0x69, 0x01); a.abs_(0x9D, 0x2100 + LO)
    a.abs_(0xBD, 0x2100 + MID + 1); a.emit(0x69, 0x00); a.abs_(0x9D, 0x2100 + LO + 1)
    a.emit(0x4C); a.word("loop")

    a.label("go_hi")                                      # hi = mid - 1 (mid==0 이면 없음)
    a.abs_(0xBD, 0x2100 + MID); a.abs_(0x1D, 0x2100 + MID + 1)
    a.branch(0xD0, "hi_ok")
    a.emit(0x4C); a.word("miss")
    a.label("hi_ok")
    a.emit(0x38)                                          # SEC
    a.abs_(0xBD, 0x2100 + MID); a.emit(0xE9, 0x01); a.abs_(0x9D, 0x2100 + HI)
    a.abs_(0xBD, 0x2100 + MID + 1); a.emit(0xE9, 0x00); a.abs_(0x9D, 0x2100 + HI + 1)
    a.emit(0x4C); a.word("loop")

    # ---- 찾음: 키 6 B 를 관측 슬롯으로 --------------------------------
    a.label("found")
    # AC 포인터는 지금 entry+3 (키 첫 바이트) 을 가리킨다.  6 B 를 T 아래 스택에
    # 밀어 두고, 포인터를 슬롯으로 옮겨 다시 쓴다.
    # ★ 스택(PHA/PLA)을 쓰면 꺼낼 때 역순이 되어 키가 뒤집힌다.
    #   검색이 끝났으므로 LO/HI/MID 자리(지역변수 1..6)를 그대로 빌린다.
    for i in range(6):
        a.abs_(0xAD, 0x1A00); a.abs_(0x9D, 0x2100 + 1 + i)   # LDA AC / STA loc[1+i],X
    ac_ptr_const(a, AC_SLOT)
    a.emit(0xA9, ST_FOUND); a.abs_(0x8D, 0x1A00)          # status
    for i in range(3):
        a.abs_(0xAD, CDB_LBA + i); a.abs_(0x8D, 0x1A00)   # 읽은 LBA
    for i in range(6):
        a.abs_(0xBD, 0x2100 + 1 + i); a.abs_(0x8D, 0x1A00)   # 키 6 B (정순)
    # ★ 슬롯은 **고정 ABI** 다.  miss 경로가 +4~+10 에 7 B 를 쓰므로 found 도
    #   7 B 를 채워야 단계/도장이 같은 칸에 온다.
    #   (2026-08-30 밤: 이 한 칸 차이 때문에 found 의 도장 $75 가 "117단계" 로,
    #    안 쓴 +12 가 "BUILD $00" 으로 읽혔다.  BIOS 는 멀쩡했고 판독이 틀렸다.)
    a.emit(0xA9, 0x00); a.abs_(0x8D, 0x1A00)              # +10 채움 (배치 맞춤)
    a.abs_(0xBD, 0x2100 + PROBE); a.abs_(0x8D, 0x1A00)    # +11 단계 수
    a.emit(0xA9, BUILD_ID); a.abs_(0x8D, 0x1A00)          # +12 ★ 버전 도장
    a.emit(0x4C); a.word("done")

    a.label("miss")
    ac_ptr_const(a, AC_SLOT)
    a.emit(0xA9, ST_MISS); a.abs_(0x8D, 0x1A00)
    for i in range(3):
        a.abs_(0xAD, CDB_LBA + i); a.abs_(0x8D, 0x1A00)
    # ★ 진단: 키 자리에 [디스패처가 마지막으로 읽은 entry 3 B][00 00 00] 를 적는다
    #   세 값이 서로 같으면 -> AC 자동증가가 안 먹는다
    #   표에 없는 값이면   -> 색인 주소가 틀렸다 (Lua 가 올린 자리와 다르다)
    for i in range(3):
        a.abs_(0xBD, 0x2100 + RD + i); a.abs_(0x8D, 0x1A00)   # 동적 읽기
    for i in range(4):
        a.abs_(0xBD, 0x2100 + FX + i); a.abs_(0x8D, 0x1A00)   # 고정주소 4 B
    a.abs_(0xBD, 0x2100 + PROBE); a.abs_(0x8D, 0x1A00)       # 단계 수
    a.emit(0xA9, BUILD_ID); a.abs_(0x8D, 0x1A00)             # ★ 버전 도장
    a.label("done")
    # 지역변수 8 B 반환
    for _ in range(LOCALS):
        a.emit(0x68)                                      # PLA
    if has_cplay:
        # PLA 로 스택이 진입 시점으로 돌아왔다 -- 복귀주소가 들어올 때와 **같은
        # 자리**에 그대로 있으므로 한 번 더 갈라 밀려난 명령을 고른다.
        #   $F5F5 AD_PLAY    LDX $22A8
        #   $F687 AD_CPLAY   LDA #$60 / STA $180D   <- 여기서 재생이 시작된다
        a.emit(0xBA)                                      # TSX
        a.abs_(0xBD, 0x2103); a.emit(0xC9, (cplay_return >> 8) & 0xFF)
        a.branch(0xD0, "tail_ad_play")
        a.abs_(0xBD, 0x2102); a.emit(0xC9, cplay_return & 0xFF)
        a.branch(0xD0, "tail_ad_play")
        a.emit(0xA9, CPLAY_A)                             # LDA #$60
        a.abs_(0x8D, ADPCM_CTRL)                          # STA $180D
        a.branch(0x80, "tail_exit")                       # BRA
        a.label("tail_ad_play")
    # displaced LDX $22A8 · 규약대로 A 를 밀고 뱅크0 으로
    a.abs_(0xAE, ADPCM_ADDR)
    a.label("tail_exit")
    a.emit(0x48)                                          # PHA
    a.emit(0xA9, 0x00)
    a.emit(0x4C); a.word(EXIT_BRIDGE)

    if extra_return is not None:
        if extra_builder is None:
            raise ValueError("extra_return requires extra_builder")
        a.label("extra")
        extra_builder(a)
    if extra_return2 is not None:
        if extra_builder2 is None:
            raise ValueError("extra_return2 requires extra_builder2")
        a.label("extra2")
        extra_builder2(a)
    if has_rcr:
        if rcr_builder is None:
            raise ValueError("rcr_return requires rcr_builder")
        a.label("rcr")
        rcr_builder(a)
        # ★ 지연 arm 이 끝나면(또는 이번 호출이 우리 자리가 아니면) 여기로 온다.
        #   밀려난 명령은 `STA $0000` 하나뿐이고 그때 A 는 상수 $06 이다
        #   ($E422 에서 `STA $F7` 로 그림자를 이미 맞춰 놨다).
        a.label("rcr_tail")
        # ★★ 2026-09-03: X 를 반드시 되돌린다.
        #   $E42B 가 `STX $0003` 으로 **RCR 상위 바이트**를 쓴다.  그런데 디스패처는
        #   진입하자마자 TSX 로 X 를 덮으므로, 그대로 두면 RCR 이 $F8xx 같은 값이
        #   되어 래스터 분할이 통째로 죽는다.
        #   $E0A8 점프표(EX_SETRCR 계열)의 규약은 X = RCR 상위 바이트이고, 이 게임이
        #   쓰는 값은 71 · 199 · 212 셋뿐이라 모두 256 미만이다 -> X = 0.
        #   ⚠ 이것은 **관측(0.5.160)에 기댄 상수**다.  RCR >= 256 을 쓰는 장면이
        #     있으면 여기서 깨진다.  lua/SUB/0.5.162 로 X 를 전수 확인할 것.
        a.emit(0xA2, 0x00)                                # LDX #$00
        a.emit(0xA9, RCR_SEL_IMM)                         # LDA #$06
        a.abs_(0x8D, 0x0000)                              # STA $0000  (displaced)
        a.emit(0x48)                                      # PHA
        a.emit(0xA9, 0x00)
        a.emit(0x4C); a.word(EXIT_BRIDGE)

    return a.finish(), a.labels


def patch_image(base: Path, out: Path, code: bytes, *,
                cplay_hook: bool = False, rcr_hook: bool = False) -> None:
    """.pce 만 고친다.  디스크/Track24 는 건드리지 않는다."""
    img = bytearray(base.read_bytes())

    def off0(addr: int) -> int:      # 뱅크 0
        return addr - 0xE000

    def off1(addr: int) -> int:      # 뱅크 1
        return 0x2000 + (addr - 0xE000)

    # 1) 뱅크1 여유가 정말 비었는지(FF) 확인하고 디스패처를 넣는다
    at = off1(BANK1_FREE_LO)
    region = img[at:at + len(code)]
    if any(b != 0xFF for b in region):
        bad = next(i for i, b in enumerate(region) if b != 0xFF)
        raise SystemExit(f"거부: 뱅크1 ${BANK1_FREE_LO + bad:04X} 가 비어 있지 않다")
    img[at:at + len(code)] = code

    # 2) 뱅크1 $FFDA 재지정: JMP $F054 -> JMP <디스패처>
    at = off1(DISPATCH_AT)
    want = bytes((0x4C, REPAIR & 0xFF, REPAIR >> 8))
    if bytes(img[at:at + 3]) != want:
        got = bytes(img[at:at + 3]).hex(" ").upper()
        raise SystemExit(f"거부: 뱅크1 ${DISPATCH_AT:04X} 가 JMP ${REPAIR:04X} 가 아니다 ({got})")
    img[at:at + 3] = bytes((0x4C, BANK1_FREE_LO & 0xFF, BANK1_FREE_LO >> 8))

    # 3) 뱅크0 훅: LDX $22A8 -> JSR $FFD4
    at = off0(HOOK)
    if bytes(img[at:at + 3]) != HOOK_ORIG:
        got = bytes(img[at:at + 3]).hex(" ").upper()
        raise SystemExit(f"거부: ${HOOK:04X} 가 {HOOK_ORIG.hex(' ').upper()} 가 아니다 ({got})")
    img[at:at + 3] = bytes((0x20, 0xD4, 0xFF))

    # 4) 뱅크0 두 번째 훅: AD_CPLAY 의 STA $180D -> JSR $FFD4
    #    켜는 쪽은 0.4.6.43 이다.  이 파일의 main() 은 옛 한 훅 그대로 굽는다.
    if cplay_hook:
        at = off0(HOOK_CPLAY)
        if bytes(img[at:at + 3]) != HOOK_CPLAY_ORIG:
            got = bytes(img[at:at + 3]).hex(" ").upper()
            raise SystemExit(
                f"거부: ${HOOK_CPLAY:04X} 가 "
                f"{HOOK_CPLAY_ORIG.hex(' ').upper()} 가 아니다 ({got})")
        img[at:at + 3] = bytes((0x20, 0xD4, 0xFF))

    # 5) 뱅크0 세 번째 훅: BIOS RCR 설정 루틴의 STA $0000 -> JSR $FFD4
    #    무거운 arm 작업을 줄 148 뒤(줄 160 호출)로 옮기기 위한 갈고리다.
    if rcr_hook:
        at = off0(HOOK_RCR)
        if bytes(img[at:at + 3]) != HOOK_RCR_ORIG:
            got = bytes(img[at:at + 3]).hex(" ").upper()
            raise SystemExit(
                f"거부: ${HOOK_RCR:04X} 가 "
                f"{HOOK_RCR_ORIG.hex(' ').upper()} 가 아니다 ({got})")
        img[at:at + 3] = bytes((0x20, 0xD4, 0xFF))

    out.write_bytes(bytes(img))


TEST_NOTE = """{version}  --  네이티브 LBA 조회 **관측 전용**

이 판은 게임 동작을 바꾸지 않는다.  자막을 켜지 않고 state 도 안 건드린다.
AD_PLAY 도중 CDB 의 LBA 3 B 로 색인을 이분 검색해 결과만 AC 에 적는다.

1. Power Cycle
2. BIOS: {bios}
3. CUE : build/patch/0.4.6.22-dictionary-key-vram/...[KO].cue   (그대로 쓴다)
4. Lua : lua/SUB/0.5.45-fixed-abi.lua   (이것 하나만)
         -> 색인표를 AC ${index:06X} 에 올리고 ${slot:06X} 결과를 채점한다

관측 슬롯 AC ${slot:06X}   (고정 ABI -- found/miss 배치가 같다)
  +0      status   $A1 찾음 · $A0 못찾음
  +1~3    읽은 LBA (MSB first)
  +4~10   found: 찾은 6 B 키 + 채움 1 B   ·   miss: 동적 3 B + 고정 4 B
  +11     탐색 단계 수     (902 항목 이분검색이면 8~11 이 정상)
  +12     BUILD 도장       ${build:02X}

PASS  자막 대상 음성마다 $A1 이 뜨고 키가 Lua 의 진짜 키와 같다
      효과음에서는 $A0 (표에 없으므로 정상)
FAIL  status 가 안 바뀜 -> 훅이 안 걸렸다
      키가 다름         -> 이분 검색 또는 AC 접근이 틀렸다
      BUILD 가 ${build:02X} 가 아님 -> 다른 BIOS 를 로드했다
      크래시            -> 뱅크 다리 규약 위반.  즉시 되돌릴 것

되돌리기: BIOS 를 0.4.6.22 것으로 바꾸면 끝 (디스크는 공용이라 그대로다)

★ 자리는 2026-08-30 밤에 옮겼다.  옛 $1F2200/$1F2400 은 renderer 섹터의
  패딩(FF) 한복판이라 선적재에 지워졌다.  AC 자리는 데이터 끝이 아니라
  **섹터 끝**을 보고 고른다.
"""


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true",
                    help="어셈블만 하고 크기·분기거리를 본다")
    ap.add_argument("--index-base", default=None,
                    help="LBA 색인의 AC 주소 (기본: POC 용 $1F2400, Lua 가 올린다)")
    args = ap.parse_args()

    if not PACK_LBA.is_file():
        raise SystemExit(f"LBA 색인 팩이 없다: {PACK_LBA}\n"
                         "  python tools/build_pack_lba_index.py 를 먼저 돌릴 것")
    blob = PACK_LBA.read_bytes()
    count = struct.unpack_from("<H", blob, 0x2E)[0]
    table_off = struct.unpack_from("<I", blob, 0x30)[0]
    index_base = int(args.index_base, 0) if args.index_base else AC_INDEX

    first, labels = build_dispatcher(BANK1_FREE_LO, index_base, count)
    code, labels = build_dispatcher(BANK1_FREE_LO, index_base, count, labels)
    if len(first) != len(code):
        raise SystemExit(f"2-pass 불일치: {len(first)} vs {len(code)}")

    room = BANK1_FREE_HI - BANK1_FREE_LO + 1
    where = "   (Lua 가 올린다)" if index_base == AC_INDEX else ""
    print(f"{VERSION} LBA 조회 관측 POC · BUILD_ID ${BUILD_ID:02X}")
    print(f"  LBA 색인 {count} 항목 @ AC ${index_base:06X} · stride {STRIDE}{where}")
    print(f"  디스패처 {len(code)} B / 뱅크1 여유 {room} B "
          f"(${BANK1_FREE_LO:04X}-${BANK1_FREE_HI:04X})")
    if len(code) > room:
        raise SystemExit("뱅크1 여유 초과")
    print(f"  훅 ${HOOK:04X} {HOOK_ORIG.hex(' ').upper()} -> 20 D4 FF (JSR $FFD4)")
    print(f"  복귀주소 판별 ${HOOK_RET:04X} · 그 외는 JMP ${REPAIR:04X}")
    print(f"  관측 슬롯 AC ${AC_SLOT:06X}")

    outdir = ROOT / "build" / "cutscene_subs"
    (outdir / "lba_dispatcher.bin").write_bytes(code)
    (outdir / "lba_index.bin").write_bytes(blob[table_off:])
    print(f"  -> {outdir / 'lba_dispatcher.bin'}")
    print(f"  -> {outdir / 'lba_index.bin'}   (Lua 가 AC 로 올릴 표)")

    if args.dry_run:
        print("\n  --dry-run: 이미지는 안 건드렸다")
        return

    src = ROOT / "build" / "patch" / "0.4.6.22-dictionary-key-vram"
    base = src / "Syscard3_galmuri_0.4.6.21-reviewed-dictionary.pce"
    # ★ 버전 뒤에 설명을 붙이지 않는다 (2026-08-30 소유자 지침).  폴더는 버전 그대로.
    dst = ROOT / "build" / "patch" / VERSION
    if dst.exists():
        raise SystemExit(
            f"거부: {dst} 가 이미 있다."
            "  같은 이름으로 다시 구우면 실기에서 무엇을 로드했는지 알 수 없다."
            "  VERSION 과 BUILD_ID 를 올릴 것.")
    dst.mkdir(parents=True)
    # ★ 파일명에도 버전 뒤 설명을 붙이지 않는다 (2026-08-30 소유자 지침).
    out = dst / f"Syscard3_galmuri_{VERSION}.pce"
    patch_image(base, out, code)
    print(f"\n  ✔ BIOS 패치: {out}")
    print("  ★ 디스크(CUE/Track)는 0.4.6.22 폴더 것을 그대로 쓴다 -- 안 건드렸다")

    (dst / "TEST_IN_MESEN.txt").write_text(
        TEST_NOTE.format(version=VERSION, bios=out.name, slot=AC_SLOT,
                         index=index_base, build=BUILD_ID), encoding="utf-8")
    print(f"  -> {dst / 'TEST_IN_MESEN.txt'}")


if __name__ == "__main__":
    main()
