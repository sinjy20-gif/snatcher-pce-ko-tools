#!/usr/bin/env python3
"""CD-DA **전 트랙** mini index + 트랙 디렉터리를 굽는다 (2026-09-04 밤).

`build_cdda_track17_mini_index.py` 는 **안 건드린다.**  그건 트랙 17 전용이고,
결과를 대조할 기준으로 남긴다.

무엇이 다른가
-------------
```
트랙 17 판    39 구간 × 13 B = 507 B     구간마다 vram 즉치 3 B 를 들고 다닌다
이 판         715 구간 ×  5 B            vram 은 **트랙 디렉터리**로 뺐다
              15 트랙  × 16 B
```

왜 뺄 수 있나 -- **헬퍼가 무장 한 번에 저장/복원을 한 쌍만** 한다.  한 트랙
재생이 곧 무장 하나이므로, 그 안에서는 자리를 옮길 수 없다.  그러니 자리는
구간이 아니라 **트랙**의 성질이다.

이건 ADPCM 이 이미 쓰는 구조와 같다:

```
ADPCM   디렉터리 9 B/음성  = start_lba 3 + payload ptr 3 + ★vram 즉치 3
        armer 가 무장 때 그 3 B 를 렌더러 즉치 자리에 심는다
        (build_snatcher_0_4_6_29_native_arm.py:328-331, imm_offsets)
CD-DA   디렉터리 9 B/트랙  = raw 1 + BCD 1 + count 1 + mini ptr 3 + ★vram 즉치 3
        cdda_start 가 같은 일을 한다
```

자리 고르기
-----------
관찰 창고(`cdda_vram_observations.tsv`)에서 트랙의 **모든 창에 동시에 비어
있는** base 집합을 구해 그중 **가장 높은 것**을 쓴다.

★ 왜 highest 인가 -- 실측이 둘뿐인데 둘 다 높은 쪽이 좋았다:

```
$2000  ✘ 배경 파손 (2026-09-04, 트랙 17.  게임의 빈칸 타일을 덮었다)
$6600  ✔ ADPCM 이 계속 쓰는 자리
$7900  ✔ 0.4.6.25 실기 PASS + 2026-09-04 확인
```

`verify_subtitle_safe_positions.valid_base` 의 `VRAM_BODY_END = $1FFF` 가
실제보다 낮다는 뜻이다 (BAT/SATB 본체 너머에도 게임이 읽기만 하는 패턴이 있다).
그 상수를 올릴 근거가 생기기 전까지는 highest 로 우회한다.

빠지는 트랙 -- ★이유가 서로 다르다
-----------------------------------
```
트랙 1   ★게임에 안 나온다 (소유자, 2026-09-05).  다른 데 쓰는 트랙이다
         관찰이 없는 것은 "수집을 안 해서" 가 아니라 **지나갈 일이 없어서**다
         -> 관찰을 모아도 소용없다.  손실로 세지 말 것
트랙 3   관찰은 있는데 교집합이 빈다.  ★진짜 충돌이다
         창1 후보 28 · 창2 후보 16 -> 누적 16, 창3(후보 27)과 겹치는 자리가 0
         자리가 없는 게 아니라 **트랙 안에서 요구가 갈린다.**  헬퍼가 트랙당
         한 번만 무장하므로 구간마다 자리를 옮길 수 없다 (§17-1)
```
소유자 판단: 안전자리가 없으면 안 넣는다.

실제 손실은 트랙 3 의 23 줄뿐이다 (762 줄 중 3 %).  트랙 1 의 29 줄은
게임에 안 나오므로 세지 않는다.

    python build_cdda_mini_index_all.py            표만 보여준다
    python build_cdda_mini_index_all.py --write    저장
"""
from __future__ import annotations

import argparse
import csv
import json
import struct
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
BUILD = ROOT / "build" / "cutscene_subs"

import build_cdda_runtime_safe_positions as S  # noqa: E402

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

PACK = BUILD / "subtitle_pack.bin"
PACK_JSON = BUILD / "subtitle_pack.json"
SEGMENTS = BUILD / "cdda_segments.tsv"
CUE_TRACK_LBA = BUILD / "cdda_track_start_lba.json"   # 있으면 쓴다

OUT_MINI = BUILD / "cdda_mini_index_all.bin"
OUT_DIR = BUILD / "cdda_track_directory.bin"
OUT_TSV = BUILD / "cdda_mini_index_all.tsv"
OUT_JSON = BUILD / "cdda_mini_index_all.json"

AC_PACK = 0x160000
PALETTE = 0x0F
# 디렉터리가 놓이는 AC 주소.  mini 가 여기를 넘으면 안 된다.
# ⚠ build_snatcher_0_4_6_43_cdda_adpcm.AC_CDDA_DIR 와 **같아야 한다.**
AC_DIR = 0x1FFA00

MINI_STRIDE = 5      # record_ptr u24 + start_frame u16
HIDE_RECORD_PTR = 0xFFFFFF

# ★ 트랙 중간의 긴 무음에서 이전 자막 스프라이트를 내릴 지점.
#
# 트랙 3의 두 장소 전환(접수처·국장실)은 바로 앞 자막이 끝난 뒤 다음 자막까지
# 245 / 152 프레임 비어 있다. timed=False인 CD-DA 렌더러는 그동안 이전 줄을
# 계속 push하고, 장면 전환이 글리프 VRAM을 덮으면 화면에 한 줄 노이즈가 남는다.
# 팩의 rec_off는 앞선 레코드가 추가/삭제되면 함께 밀린다. 실제 장면 기준인
# start_frame으로 대상을 식별하고, 숨김 시각은 레코드의 frames를 읽어
# `start_frame + frames`로 계산한다.
INTERMEDIATE_HIDE_AFTER_FRAME: dict[int, set[int]] = {
    3: {493, 1964},      # 579f: 접수처 진입 · 2099f: 국장실 진입
}
# 9 B: raw · BCD · count · mini ptr u24 · vram hi/lo/attr
#
#   raw  $26F9 & $7F 와 비교한다.  cdda_check 의 게이트는 0.4.6.25 실기 PASS
#        detector 라 키를 바꾸지 않는다
#   BCD  $20A2 와 비교한다.  스케줄러의 정지 검사용.  cdda_start 가 렌더러
#        패딩(코드 618 ~ 매직 670 사이)에 심어 두면 스케줄러가 읽는다
# ★16 B (9 B 만 쓰고 7 B 는 패딩).
#
#   뱅크 코드가 찾은 항목을 다시 열 때 `AC_CDDA_DIR + X*stride` 를 계산해야
#   하는데, 16 이면 시프트 넷이면 끝난다 (9 면 곱셈이 필요하다).
#   15 트랙 × 16 = 240 B -- AC 는 여유가 충분하니 코드를 단순하게 사는 쪽이 낫다.
#
#   +0 raw    $26F9 & $7F 와 비교.  cdda_check 게이트 (0.4.6.25 실기 PASS detector)
#   +1 BCD    $20A2 와 비교.  스케줄러 정지 검사용.  렌더러 패딩에 심는다
#   +2 count  구간 수 (u8)
#   +3 mini   그 트랙 구간 표의 AC 주소 (u24)
#   +6 vram   hi · lo · attr  -- 무장 때 렌더러 즉치 자리에 심는다
#   +9 helper base lo · base hi · pattern hi · pattern lo
#             ★헬퍼 제어블록(AC_HELPER_CTL_BASE)에 그대로 흘려 넣는 4 B.
#             헬퍼는 이 base 로 **자기가 그린 글리프를 지운다.**  트랙마다
#             자리가 다르니 상수로 두면 안 된다 (2026-09-04 배경 파손의 원인).
#             vram 값을 두 벌 들고 가는 셈인데, 포트가 자동증가라 한 값을 두 곳에
#             쓰려면 다시 열어야 해서 그게 더 비싸다.  패딩이 남으니 복제한다.
#   +13 이사 기록 (2026-09-05) -- 트랙 안에서 base 가 **한 번** 바뀌는 경우
#       +13 구간 번호 (u8)   이 번호부터 새 자리를 쓴다.  0 이면 이사 없음
#       +14 새 base 의 hi    ★이 한 바이트에서 나머지가 전부 파생된다
#
#     lo      = (hi << 3) & 0xFF
#     attr    = 0x80 | ((hi >> 5) & 7) << 4 | PALETTE
#     pattern = hi >> 5
#     (base 0x0000~0x7F00 128 개 전수 검산 통과, 2026-09-05)
#
#     그래서 2 B 면 된다 -- 패딩 3 B 안에 들어가므로 **stride 를 안 늘린다.**
#     32 로 늘리면 X*32 가 8 비트를 넘어(16 트랙 x 32 = 512) 디렉터리 색인
#     코드(TXA + ASL x4)를 16 비트로 다시 짜야 한다.  그 값을 낼 이유가 없다.
#
#   ★왜 mini 항목(5 B)에 자리를 안 넣나
#     구간마다 base 를 들고 가면 5 -> 8 B 가 되어 710 x 8 = 5,680 B 다.  그런데
#     mini 자리는 $1FEB00~$1FF900 = 3,584 B 뿐이고 지금 3,550 B 를 쓴다 (여유 34 B).
#     디렉터리를 AC 끝까지 밀어도 부족하다.
#     반면 실제 이사는 **전 프로젝트 통틀어 1 회**다 (`plan_runs` · 시뮬레이터).
#     710 구간에 자리를 들고 다녀 1 회를 표현할 이유가 없다.  디렉터리에 기록
#     하나면 +240 B 로 끝난다.
DIR_STRIDE = 16   # 유지.  이사 기록 2 B 는 패딩에 들어간다

# 안 넣는 트랙.
#   1  게임 안에 안 나온다 (소유자 확인).  창 29 개가 전부 관측 없음이라
#      "자리가 없는" 것이 아니라 한 번도 안 지나간 것이다
#   ★3 은 2026-09-05 에 빠졌다 -- 자리가 없는 게 아니라 **한 자리로는 안 되는**
#     트랙이라, 이사 기록으로 살린다
# ★★ 2026-09-06 밤: 트랙 3 을 다시 뺀다 (0.5.10 상태로 복귀).
#   이사로 살리려 했으나 국장실에서 게임 진행이 막혔다.  인계서 §35·§36.
#   아래 BANNED_BASES / PROVEN_FIRST_BASE / MANUAL_DROPS 는 그때의 기록이며
#   트랙 3 이 SKIP 이라 지금은 아무 효과가 없다.  되살릴 때 참고할 것.
SKIP_TRACKS = {1}          # ★시험: 트랙 3 다시 켠다 (한 자리 · 이사 없음)

# ★ 손으로 빼는 자막 (2026-09-06).  LBA 범위가 겹치는 구간을 안 싣는다.
#
#   관찰로는 "자유" 로 나왔는데 **실기에서 게임 그림을 밟는** 자리가 있다.
#   안전자리표 문서가 경고한 그 함정이다:
#
#       "allocator 가 고를 때는 비어 있었고, 그 뒤에 게임이 가져갔다.
#        allocator 는 미래를 모른다."  (build_vram_key_bases.py)
#
#   프로브는 "그 음성이 도는 동안 아무도 안 가리킨 자리" 를 자유로 친다.
#   게임이 **그 뒤에** 거기에 그림을 올리면 프로브는 그것을 못 본다.
#
#   ⚠ 여기 넣기 전에 반드시 실기로 확인할 것.  추측으로 넣으면 멀쩡한 자막을
#     버리게 된다.  이유와 날짜를 같이 적는다.
#   ★ 2026-09-06: 한때 트랙 3 의 "국장실입니다."(LBA 41258~41365) 를 여기 넣었다가
#     **뺐다.**  0.5.13(그 줄 있음 + $4B00)이 정상이었으므로 "그 줄 하나만으로는
#     안 깨진다" 까지는 말할 수 있다.
#     ⚠ 그러나 **무죄가 아니라 미검증이다.**  다른 것과 겹쳐 문제를 만드는지는
#       안 쟀고, 0.5.16 은 이사 지점이 달라(seg 12 -> 5) 0.5.13 과 같은 판도 아니다.
#       자리를 먼저 의심하되, 자리를 고쳐도 깨지면 이 줄로 한 번 더 가를 것.
MANUAL_DROPS: dict[int, list[tuple[int, int, str]]] = {
    99: [   # ★시험 중 비움.  아래는 기록으로만 남긴다
        # ★★★ 2026-09-06 저녁.  seg 12 부터 끝까지 (11 줄) 를 뺀다.
        #
        #   측정 (lua/HQ/0.7.0-slot-intruder.lua, 0.5.17 실기):
        #
        #       frame  8010   STATE 01->02  cd_raw=03      트랙 3 무장
        #       frame 10132   ★게임이 $5B85~$5B88 에 쓴다   = 35.4 초 지점
        #                     pc=9C27/9C46/9C63/9C80
        #                     같은 pc 가 frame 4577(무장 전, state=00)에도
        #                     같은 자리에 썼다 -- 게임의 스크립트 VM 스택이다
        #
        #   그 자리는 헬퍼 entry 한복판이다:
        #       $5B83  AD 30 5D D0 64   LDA $5D30 / BNE
        #       $5B88  A9 00 8D 02 1A   LDA #$00 / STA $1A02
        #
        #   즉 접수처 -> 국장실 **자동 전환 스크립트**가 도는 순간이고, 우리는
        #   그때 슬롯 671 B 를 쥐고 있다.  양방향으로 망가진다 --
        #   게임은 우리 코드를 자기 데이터로 읽고, 우리 복원은 게임의 쓰기를 지운다.
        #
        #   ⚠ 전환은 **자막이 떠 있는 동안**(seg 12: 34.74~36.99) 일어난다.
        #     공백이 아니다.  그래서 "공백에 반납" 같은 우회가 안 통한다.
        #
        #   자막이 남아 있으면 스케줄러가 STATE=02 를 유지한다.  그러니 35.4 초
        #   전에 **자막을 다 써버려야** 소진 -> STATE=3 -> 슬롯 반납이 일어난다.
        #
        #       seg 11  31.94~33.78   여유 +1.62 초   ← 마지막 안전
        #       seg 12  34.74~36.99   여유 -1.59 초   ✘
        #
        #   ★ 이것은 트랙 3 만의 문제가 아니다.  **트랙 중간에 장면이 바뀌는
        #     트랙은 전부 같다.**  근본 수정은 무장을 잘게 쪼개는 것인데, 지금
        #     디스패처는 STATE=0 이 되면 CD **시작 펄스** 없이는 다시 무장하지
        #     못한다 (arm_idle -> cdda_check).  그 게이트는 0.4.6.25 실기 PASS
        #     detector 라 함부로 못 건드린다.  그래서 당장은 선을 긋는다.
        (40899, 43100, "seg 12~22 -- 국장실 전환 이후 전부"),
    ],
}

# ★ 트랙별 금지 자리 (2026-09-06).  관찰이 "자유" 라 해도 실기가 아니라면 믿는다.
#
#   실기 대조 (소유자, 트랙 3 · 국장실까지):
#
#       0.5.13   base $4B00 -> 이사 seg 12 -> $6300    ★정상
#       0.5.14   base $7B00 -> 이사 seg  5 -> $6300     총 아이콘 위에 글리프 겹침
#       0.5.15   base $7B00 -> 이사 seg  5 -> $6300     같음
#       0.5.12   base $4500                             깨짐
#
#   겹쳐 보이는 글자는 **이사 전 자리**에 그린 것이다.  $7B00 일 때만 보이고
#   $4B00 일 때는 안 보이므로, 게임의 총 아이콘 타일이 $7B00 을 가리킨다.
#
#   ⚠ 관찰 프로브는 이것을 못 잡는다.  그 음성이 도는 동안 아무도 안 가리켜도,
#     **나중에** 가리키면 우리 글자가 그 자리에 남아 있다 ("미래를 모른다").
#     그러니 실기 반례는 관찰보다 세다.
BANNED_BASES: dict[int, set[int]] = {
    3: {0x7B00, 0x4500},
}

# ★ 이사가 있는 트랙의 **첫 자리**를 실기 통과값으로 못박는다 (2026-09-06).
#
#   BANNED_BASES 만으로는 부족했다.  $7B00 을 막으니 빌더가 $7A00 을 골랐는데,
#   블록이 1216 word 라 두 자리는 960 word 가 겹친다 -- 금지어를 하나씩 빼면
#   옆으로 미끄러질 뿐이다.
#
#   0.5.13 이 이 값으로 국장실까지 정상이었다 (소유자 실기).  관찰이 더
#   깨끗해진 0.5.14 가 오히려 $7B00 을 골라 깨졌으므로, 여기서는 **관찰보다
#   실기를 우선**한다.
# ★ 이사를 아예 안 쓰는 트랙 (2026-09-06 저녁).
#
#   지금까지 **트랙 3 자막**과 **이사**를 한 번도 못 갈랐다.  트랙 3 을 켠 판이
#   곧 이사를 넣은 판이라(0.5.11), 둘이 항상 같이 다녔다.
#
#       0.5.10   자막 X · 이사 X   정상
#       0.5.13   자막 O · 이사 O(seg 12)   정상
#       0.5.17   자막 O · 이사 O(seg  5)   깨짐
#       ??       자막 O · 이사 X           ← 한 번도 안 만들어 봤다
#
#   여기 넣으면 첫 구간의 자리 하나만 쓰고, 그 뒤 구간의 자막은 안 싣는다.
#   자막 수는 줄지만 **원인을 가르는 판**이 된다.
NO_MOVE_TRACKS: set[int] = {3}     # ★시험: 첫 자리 하나만.  자막은 안 자른다
#
# ★★★ 2026-09-10 밤 -- 트랙 5·6 자리를 관찰로 고르려다 **세 번 다 실패했다.**
#
#   메탈 초상화 깨짐을 고치려고 관찰이 가리키는 자리로 옮겼는데, 옮길 때마다
#   다른 것이 깨졌다.  실기로 확인한 결과다:
#
#       0.7.2  5=$7300 6=$3B00   초상화만 깨짐          ← 셋 중 제일 낫다
#       0.7.3  5=$3B00 6=$3600   초상화 정상 · 깁슨 문서 깨짐
#       0.7.4  5=$6300 6=$7300   전반적으로 더 깨짐
#
#   그런데 관찰 점수는 정반대였다 (0.7.4 주행까지 넣은 창고 기준):
#
#       트랙 5 · 살아남은 창 50
#           $7300    0/50      실제로는 제일 멀쩡
#           $3B00    0/50
#           $6300   50/50      만점인데 실제로 제일 많이 깨졌다
#
#   **부호가 안 맞는다.**  방향이 어긋난 게 아니라 반대다.  그러니 이 모델로
#   base 를 고르면 안 된다.  짐작되는 이유는 관찰이 **음성 구간 단위로 뭉쳐서**
#   재기 때문이다 -- 같은 구간 안에서 장면이 바뀌면 프레임 단위 충돌을 못 본다.
#   (깁슨 문서는 페이지를 넘길 때마다 $3000 부터 타일을 다시 올린다.)
#
#   가르려면 렌더러가 쓰는 VRAM 과 그 장면이 쓰는 VRAM 을 **같은 프레임에서**
#   대조하는 프로브가 필요하다.  그 전까지는 실기로 확인된 값을 쓴다.
#
#   ⚠ 곁가지 결함 (아직 안 고침): NO_MOVE_TRACKS 는 커버리지를 안 보고 run0 의
#     자리를 집는다.  트랙 3 에 그대로 적용하면 $7A00 = **3/20 창**이 나온다.
#     지금 멀쩡한 건 PROVEN_FIRST_BASE 가 덮고 있어서일 뿐이다.
#     이사를 안 할 거면 run 구조가 아니라 전 구간 커버리지 최대를 골라야 한다.
#
# ★★★ 2026-09-06 저녁, 실측으로 확정.  트랙 3 의 이사는 **실효가 없다.**
#
#   lua/HQ/0.9.0-move-verify.lua · 0.5.18 실기:
#
#       2552  MOVE_EXEC#1                     경과 17.58초
#       2552  hi<-6B@EFE3     이사가 새 값을 쓴다
#       2552  attr<-BF@EFFF   "
#       2552  STATE<-01@F025  이사가 재무장을 요청한다
#       2552  hi<-4B@7FC3     ★상주부의 재복사가 옛 값으로 되돌린다
#       2552  attr<-AF@7FC3   ★
#       2553  change          hi=4B attr=AF   -- 이사 전과 같다
#
#   코드가 이유를 설명한다 (build_snatcher_cdda_scheduler.py, cdda_move):
#       1) 헬퍼 제어블록은 **AC 에** 쓴다        -> 살아남는다 ($6B00)
#       2) 렌더러 즉치는 **CPU 에만** 쓴다       -> 4) 가 덮는다 ($4B00 로 복귀)
#       4) STATE=1 -> 상주부가 AC 이미지를 CPU 로 재복사
#
#   즉 헬퍼는 새 자리를 지우고 렌더러는 옛 자리에 그린다 -- 엇갈린다.
#   이사는 아무 이득 없이 그 엇갈림만 만든다.  그래서 뺀다.
#
#   ⚠ 되살리려면 즉치를 **AC 이미지에도** 써야 하는데, 세 즉치가
#     +203/+238/+243 로 떨어져 있어 ac_ptr_const 3 회 = 84 B 다 (여유 40 B).
#     재복사 **다음 프레임**에 CPU 즉치를 쓰는 2 단 이사로 바꿔야 한다.

# 트랙 -> 이사를 뺐을 때의 마지막 안전 LBA.  plan_runs 가 채운다.
NO_MOVE_CUTOFF: dict[int, int] = {}

PROVEN_FIRST_BASE: dict[int, int] = {
    3: 0x4B00,   # 0.5.13 실기 PASS (국장실 정상 · 총 아이콘 겹침 없음)
}

# ★실기로 검증된 자리는 highest 로 덮지 않는다.
#   관찰 데이터는 트랙 17 에서 $2000 을 verified 로 내놓고 실기에서 깨진 전력이
#   있다.  실기 근거가 있으면 그쪽이 우선이다 (다른 출처 우선).
PROVEN_BASE = {
    17: 0x7900,   # 0.4.6.25 실기 PASS · 2026-09-04 재확인 (39 구간 완주)
    # ★ 2026-09-10 밤.  0.6.2 부터 0.7.2 까지 쭉 쓰던 값으로 **되돌린 것**이다.
    #   관찰을 믿고 옮긴 0.7.3(5=$3B00 6=$3600)·0.7.4(5=$6300 6=$7300)가 둘 다
    #   실기에서 더 깨져 폐기했다.  위 NO_MOVE_TRACKS 주석의 실패 기록을 볼 것.
    #   ⚠ 이 둘을 빼면 빌더가 새 관찰을 보고 다시 $6300 쪽으로 간다 -- 그러면
    #     0.7.4 가 재현된다.  프레임 단위 대조 프로브가 나오기 전엔 풀지 말 것.
    #   남은 결함: 트랙 5·6 의 메탈 초상화 깨짐 (0.6.5 부터 · 그래픽과 무관).
    5: 0x7300,
    6: 0x3B00,
}


def imm3(base: int) -> tuple[int, int, int]:
    """렌더러가 들고 있는 vram 즉치 3 개.  ADPCM 과 같은 계산이다."""
    hi = (base >> 8) & 0xFF
    lo = ((base >> 6) << 1) & 0xFF
    attr = 0x80 | ((((base >> 6) << 1) >> 8) & 7) << 4 | PALETTE
    return hi, lo, attr


def load_segments() -> list[dict]:
    return list(csv.DictReader(SEGMENTS.open(encoding="utf-8-sig", newline=""),
                               delimiter="\t"))


def cue_track_lba() -> dict[int, dict]:
    """큐시트에서 트랙마다 {index00, index01, pregap} 절대 LBA 를 계산한다.

    ★ 왜 큐시트인가 -- 2026-09-06.

      전에는 t0 를 구간표에서 `lba_from - start_sec*75` 로 역산했다.  그런데
      구간표의 `lba_from` **자체가** `원점 + start_sec*75` 로 만들어진 값이다
      (build_cdda_segments.py).  즉 같은 식을 두 번 쓴 검산이라 원점이 무엇이든
      **항상 통과한다.**  트랙 3 이 2 초 밀려 있는데도 "퍼짐 0.01 초, t0 결백"
      이라고 답했다.  큐시트는 독립된 출처라 그 함정을 벗어난다.
    """
    import re
    cue = ROOT / "rom(japan)" / "Snatcher CD-ROMantic (Japan)" \
               / "Snatcher CD-ROMantic (Japan).cue"
    if not cue.is_file():
        raise SystemExit(f"큐시트가 없다: {cue}")
    entries, current = [], None
    for line in cue.read_text(encoding="latin-1").splitlines():
        m = re.search(r'FILE "([^"]+)"', line)
        if m:
            current = {"file": m.group(1), "i0": 0, "i1": 0}
            entries.append(current)
        m = re.search(r"TRACK (\d+) (\S+)", line)
        if m and current is not None:
            current["no"] = int(m.group(1))
        m = re.search(r"INDEX (\d+) (\d+):(\d+):(\d+)", line)
        if m and current is not None:
            n, mm, ss, ff = (int(v) for v in m.groups())
            current["i0" if n == 0 else "i1"] = mm * 60 * 75 + ss * 75 + ff
    lba, out = 0, {}
    for e in entries:
        length = (cue.parent / e["file"]).stat().st_size // 2352
        out[e["no"]] = {"index00": lba + e["i0"], "index01": lba + e["i1"],
                        "pregap": e["i1"] - e["i0"], "length": length}
        lba += length
    return out


def track_start_lba(seg: list[dict]) -> dict[int, int]:
    """트랙마다 런타임 시계의 0 점 = **게임이 재생을 시작하는 LBA** = INDEX 01.

    ★★★ 2026-09-06.  전에는 구간표에서 역산했고, 그것이 트랙 3 자막을 통째로
      2.00 초 늦게 만들었다.

          구간표 lba_from = INDEX00 + start_sec*75      (파일 기준 시각)
          게임 재생 시작  = INDEX01 = INDEX00 + 프리갭

      트랙 3 은 프리갭 150 섹터 = 정확히 2.00 초다 (오디오 트랙 22 개 중 유일).
      실기 로그가 그대로 보여준다:

          CDDA START[107] sector=00962D          = 38,445 = INDEX01 + 1
          CDDA END  [107] 00962D-00A934  64.950s = 트랙 길이 66.95 초 - 프리갭 2 초

      그래서 t0 는 INDEX 01 이어야 하고, 그 값은 큐시트에서만 정직하게 나온다
      (역산은 자기 식을 두 번 쓰는 것이라 늘 통과한다 -- cue_track_lba() 주석).

    ★ 프리갭이 0 인 트랙에서는 옛 역산값과 반드시 같아야 한다.  다르면 구간표가
      다른 원점으로 만들어졌다는 뜻이므로 세운다.
    """
    cue = cue_track_lba()
    by = defaultdict(list)
    for r in seg:
        t = (r.get("track") or "").strip()
        if not t:
            continue
        try:
            base = int(r["lba_from"]) - float(r["start_sec"]) * 75
        except (TypeError, ValueError, KeyError):
            continue
        by[int(t)].append(base)

    out = {}
    for t, vals in by.items():
        vals.sort()
        derived = int(round(vals[len(vals) // 2]))         # 구간표가 쓴 원점 (= INDEX00)
        info = cue.get(t)
        if info is None:
            raise SystemExit(f"큐시트에 트랙 {t} 가 없다")
        # ★ 허용 오차 2 섹터.  `lba_from` 이 `int(start*75)` 로 **버림**이라
        #   중앙값이 1 섹터쯤 낮게 나온다 (실측: 트랙 4 가 -1).  프리갭은 최소
        #   150 섹터라 이 창으로는 절대 안 빠져나간다.
        if abs(derived - info["index00"]) > 2:
            raise SystemExit(
                f"트랙 {t}: 구간표의 원점 {derived} 이 큐시트 INDEX00 "
                f"{info['index00']} 과 다르다 ({(derived - info['index00'])/75:+.2f} 초).\n"
                "    build_cdda_segments.py 를 고친 뒤 cdda_segments.tsv 를\n"
                "    다시 만들지 않았을 가능성이 크다.  2026-09-06 항목 참고.")
        out[t] = info["index01"]
    return out


def window_bases() -> dict[int, list]:
    """트랙 -> [((lba_from, lba_to), 자유 base 집합 또는 None)] (창 순서대로).

    ★ 2026-09-05.  전에는 곧바로 교집합을 내서 `common_bases` 만 있었다.  그러면
      "한 자리로 안 되는 트랙" 이 그냥 탈락한다 (트랙 3).  창별 자유 집합을
      그대로 돌려주면 `plan_runs` 가 구간을 나눠 살릴 수 있다.
    """
    _, windows = S.parse_pack()
    stored = S.ingest(sorted(S.ROOT.glob(S.DEFAULT_GLOB)), [])
    spans, lba_of = defaultdict(list), {}
    for r in stored:
        spans[r["clip"]].append((r["source"], int(r["first"], 16), int(r["last"], 16)))
        try:
            lba_of[r["clip"]] = (int(r["lba_from"]), int(r["lba_to"]))
        except (TypeError, ValueError):
            pass
    obs = []
    for clip, sp in spans.items():
        w = lba_of.get(clip)
        if w is None:
            continue
        for group in S.split_observations(sp):
            free = set()
            for first, last in group:
                free |= S.bases_in_span(first, last)
            obs.append((w, free))

    seg = load_segments()
    def track_of(lba: int):
        for r in seg:
            try:
                if int(r["lba_from"]) <= lba <= int(r["lba_to"]):
                    return int(r["track"])
            except (TypeError, ValueError):
                pass
        return None

    per = defaultdict(list)
    for lo, hi in sorted(windows):
        t = track_of(lo)
        if t is None:
            continue
        # ★ 2026-09-06.  **안 그리는 창은 자리를 제약하지 않는다.**
        #   MANUAL_DROPS 로 뺀 자막의 창까지 교집합에 넣으면, 그리지도 않을
        #   구간 때문에 후보가 좁아진다.  창을 통째로 빼서 계획에서 제외한다.
        if any(not (mh < lo or hi < ml) for ml, mh, _ in MANUAL_DROPS.get(t, [])):
            continue
        hits = [f for (a, b), f in obs if a < hi and lo < b]
        free = None if not hits else set.intersection(*hits)
        # ★ 실기 반례로 금지된 자리는 여기서 뺀다 (BANNED_BASES 주석 참고).
        #   관찰보다 실기가 세다 -- 프로브는 "나중에 가리키는" 충돌을 못 본다.
        if free is not None and t in BANNED_BASES:
            free = free - BANNED_BASES[t]
        per[t].append(((lo, hi), free))
    return per


def common_bases() -> dict[int, set[int]]:
    """트랙별 '모든 창에서 동시에 비어 있는' base 집합.

    한 자리로 트랙 전체를 덮을 수 있는 트랙만 나온다.  트랙 3 처럼 자리가
    옮겨다니면 교집합이 비어서 여기 안 들어온다 -- 그건 `plan_runs` 가 푼다.

    ★ 2026-09-09.  '관찰 안 한 창' 과 '자리가 없는 창' 을 갈랐다.

        free = set()   관찰했고 자유자리가 0 이다   -> 그 창의 자막은 안 싣는다
        free = None    그 구간을 **본 적이 없다**    -> 판정 불가

    전에는 둘을 같이 묶어 `None` 이 하나만 있어도 트랙을 통째로 버렸다.  그래서
    구간표 꼬리를 자막 있는 데까지 늘리자 그 꼬리가 미관찰이라 트랙 9·11·13 이
    통째로 빠졌다 (690 -> 610 구간).  자막 4 줄 얻자고 93 구간을 잃는 거래였다.

    미관찰은 "자리가 없다" 가 아니라 "모른다" 다.  그래서 **관찰된 창들만으로**
    교집합을 잡고, 미관찰 창이 몇 개였는지 따로 알린다.  base 는 여전히 관찰된
    모든 창에서 검증된 값이다.

    ⚠ 미관찰 구간에서는 그 자리가 실제로 비어 있다는 보장이 없다.  그 트랙 꼬리에
      쓰레기 타일이 보이면 **이것부터 의심할 것** -- 아래 UNVERIFIED 목록에 뜬다.
      제대로 닫으려면 그 구간을 CD-DA VRAM 수집기로 한 번 관찰하면 된다.
    """
    out: dict[int, set[int]] = {}
    for t, items in window_bases().items():
        sets = [free for _, free in items]
        if not sets:
            continue
        unseen = sum(1 for s in sets if s is None)
        seen = [s for s in sets if s is not None]
        if not seen:
            continue                      # 그 트랙을 아예 안 봤다 -- 못 정한다
        c = set.intersection(*seen)
        if c:
            out[t] = c
            if unseen:
                UNVERIFIED[t] = (unseen, len(sets))
    return out


# 트랙 -> 자유자리가 하나도 없는 창들.  plan_runs 가 채우고 main 이 읽는다.
# 여기 걸린 자막은 mini index 에 안 싣는다 (어디에 그려도 게임 그림을 밟는다).
DEAD_WINDOWS: dict[int, list] = {}

# 트랙 -> (미관찰 창 수, 전체 창 수).  common_bases() 가 채운다.
# ★ 여기 오른 트랙은 base 가 **관찰된 창에서만** 검증됐다.  그 트랙 꼬리에서
#   쓰레기 타일이 보이면 이것부터 의심할 것 (2026-09-09).
UNVERIFIED: dict[int, tuple[int, int]] = {}

# 트랙 -> 첫 구간의 자유 base 집합.  PROVEN_FIRST_BASE 검증에 쓴다.
PLAN_FREE: dict[int, set[int]] = {}


def greedy_runs(items):
    """연속 구간 최소 분할.  (구간들, 관측 없는 창들) 을 돌려준다.

    ★ 2026-09-05 에 `simulate_cdda_base_moves.py` 에서 여기로 옮겼다.  시뮬레이터가
      쓰던 판단을 **빌더가 그대로 써야** 시뮬레이션과 출하물이 안 어긋난다.
      (시뮬레이터는 이제 이것을 import 한다.)
    """
    runs, blind, dead = [], [], []
    cur, inter = [], None
    for w, free in items:
        if free is None:                 # 관측이 없다 -- 자리를 못 정한다
            blind.append(w)
            continue
        if not free:
            # ★ 2026-09-06.  관측은 있는데 **자유자리가 하나도 없는 창.**
            #
            #   전에는 이것이 그대로 구간에 들어가 빈 집합이 됐고, plan_runs 의
            #   `max(free)` 가 ValueError 로 죽었다 (트랙 3, 원본 주행 관찰).
            #
            #   여기 걸린 자막은 **어디에 그려도 게임 그림을 밟는다.**  그러니
            #   싣지 않는다 -- 안 뜨는 편이 쓰레기 타일로 화면을 덮는 것보다 낫다.
            #   호출자가 `dead` 를 받아 그 창의 자막을 뺀다.
            dead.append(w)
            continue
        if inter is None:
            cur, inter = [w], set(free)
            continue
        nxt = inter & free
        if nxt:
            cur.append(w)
            inter = nxt
        else:
            runs.append((cur, inter))
            cur, inter = [w], set(free)
    if inter:
        runs.append((cur, inter))
    return runs, blind, dead


def plan_runs(pick: str = "highest") -> dict[int, list[tuple[int, int]]]:
    """트랙 -> [(base, 그 구간이 시작하는 lba)].  길이 1 이면 이사 없음.

    한 자리로 안 되는 트랙(=`common_bases` 에 없는 트랙)을 살리는 길이다.
    창을 순서대로 훑어 교집합이 빌 때마다 끊고, 끊긴 자리에서 base 를 바꾼다.
    """
    out: dict[int, list[tuple[int, int]]] = {}
    DEAD_WINDOWS.clear()
    PLAN_FREE.clear()
    NO_MOVE_CUTOFF.clear()
    for t, items in window_bases().items():
        runs, blind, dead = greedy_runs(items)
        if dead:
            # 자유자리가 하나도 없는 창.  그 창의 자막은 아래에서 뺀다.
            DEAD_WINDOWS[t] = list(dead)
        if blind or not runs:
            continue                     # 관측 구멍이 있으면 자리를 못 정한다
        if t in NO_MOVE_TRACKS and runs:
            # ★ 첫 자리 하나만 쓴다.  **자막은 안 자른다.**
            #
            #   관찰 기준으로 자르면 트랙 3 이 5 줄로 깎인다.  그런데 0.5.18
            #   실기에서 렌더러는 (이사가 실효 없어서) 내내 $4B00 에 그렸고,
            #   seg 11 "너무 마음 쓰지 말아요." 까지 멀쩡히 떴다.
            #   관찰보다 실기가 세다 -- 자르지 않는다.
            runs = runs[:1]
        plan = []
        for index, (windows_in_run, free) in enumerate(runs):
            base = max(free) if pick == "highest" else min(free)
            plan.append((base, windows_in_run[0][0]))
            if index == 0:
                PLAN_FREE[t] = set(free)     # 첫 구간의 자유자리 (못박기 검증용)
        out[t] = plan
    return out


def pack_cdda_index() -> list[tuple[int, int, int, int]]:
    meta = json.loads(PACK_JSON.read_text(encoding="utf-8"))
    blob = PACK.read_bytes()
    ci = meta["cdda_index"]
    off, stride, count = ci["offset"], ci["bytes_each"], ci["count"]
    rows = []
    for i in range(count):
        e = blob[off + i * stride: off + i * stride + stride]
        rows.append((int.from_bytes(e[0:3], "little"),
                     int.from_bytes(e[3:6], "little"),
                     int.from_bytes(e[6:9], "little"),
                     e[9]))
    return rows


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--pick", choices=("highest", "lowest"), default="highest")
    ap.add_argument("--ac-mini", default="1FEB00",
                    help="mini index 를 놓을 AC 주소 (16 진)")
    args = ap.parse_args()

    blob = PACK.read_bytes()
    if blob[:4] != b"SNSB" or struct.unpack_from("<H", blob, 4)[0] != 6:
        raise SystemExit("팩이 SNSB v6 이 아니다")
    record_off, = struct.unpack_from("<I", blob, 26)

    seg = load_segments()
    starts = track_start_lba(seg)
    bases = common_bases()
    # ★ 자리가 옮겨다니는 트랙을 살리는 계획 (트랙 3).  한 자리로 되는
    #   트랙은 길이 1 이라 지금까지와 똑같이 돈다.
    runs = plan_runs(args.pick)
    index = pack_cdda_index()

    # ★ 2026-09-05: 구간표는 **안전한 VRAM 자리를 고르려고** 있는 것이지
    #   자막을 거르는 관문이 아니다.  그런데 자막 시각이 구간 밖으로 조금만
    #   벗어나도 트랙을 못 찾아 **조용히 사라졌다.**  실기에서 6 줄이 그렇게
    #   없어졌다 (0.5.1):
    #
    #       0.37 s  트랙 17  "1991년 6월 6일 모스크바"  <- 오프닝 첫 줄
    #       4.49 s  트랙 19                            } 소유자가 "트랙 19 가
    #       1.17 s  트랙 19                            }  이상하다" 고 한 그것
    #       1.88 s  트랙  9
    #       0.15 s  트랙  3  (트랙 3 은 어차피 제외 대상)
    #       0.01 s  트랙 20  ★1 LBA · 13 ms 차이로 버려졌다
    #
    #   13 ms 로 자막이 통째로 사라지는 것은 어떤 기준으로도 옳지 않다.
    #   그래서 구간 밖이면 **가장 가까운 트랙의 전체 범위**로 한 번 더 본다.
    #   붙인 것은 전부 이름과 벗어난 양을 찍는다 -- 조용히 넘어가지 않는다.
    #
    #   ⚠ t0 는 트랙의 것이므로 구간 밖이어도 start_frame 계산은 그대로
    #     성립한다 (fr = (lba - t0) * 60/75).  음수가 되면 아래에서 걸린다.
    TOLERANCE_LBA = 10 * 75          # 10 초.  이보다 멀면 정말 그 트랙이 아니다

    span: dict[int, tuple[int, int]] = {}
    for r in seg:
        try:
            t, lo_, hi_ = int(r["track"]), int(r["lba_from"]), int(r["lba_to"])
        except (TypeError, ValueError):
            continue
        a, b = span.get(t, (lo_, hi_))
        span[t] = (min(a, lo_), max(b, hi_))

    def track_of(lba: int):
        for r in seg:
            try:
                if int(r["lba_from"]) <= lba <= int(r["lba_to"]):
                    return int(r["track"])
            except (TypeError, ValueError):
                pass
        return None

    def nearest_track(lba: int):
        """구간 밖일 때 가장 가까운 트랙.  (트랙, 벗어난 LBA) 또는 None."""
        best = None
        for t, (lo_, hi_) in span.items():
            d = 0 if lo_ <= lba <= hi_ else (lo_ - lba if lba < lo_ else lba - hi_)
            if best is None or d < best[1]:
                best = (t, d)
        if best is None or best[1] > TOLERANCE_LBA:
            return None
        return best

    by_track = defaultdict(list)
    rescued: list[tuple[int, int, int]] = []
    lost: list[int] = []
    for lo, hi, ro, fl in index:
        t = track_of(lo)
        if t is None:
            near = nearest_track(lo)
            if near is None:
                lost.append(lo)
                continue
            t, off = near
            rescued.append((t, lo, off))
        by_track[t].append((lo, hi, ro, fl))

    if rescued:
        print(f"★구간 밖이라 버려질 뻔한 자막 {len(rescued)} 줄을 트랙에 붙였다:")
        for t, lba, off in sorted(rescued):
            print(f"    트랙 {t:2d}  LBA {lba:>8}  구간에서 {off:>5} LBA "
                  f"({off / 75:.2f} s) 벗어남")
        print()
    if lost:
        print(f"⚠ 어느 트랙에도 못 붙인 자막 {len(lost)} 줄 "
              f"(가장 가까운 트랙에서 {TOLERANCE_LBA / 75:.0f} 초 넘게 벗어났다):")
        for lba in sorted(lost):
            print(f"    LBA {lba}")
        print()

    print(f"팩 cdda_index {len(index)} 항목 · 트랙 {len(by_track)} 개 · "
          f"record_off {record_off:,} B")
    print()
    print("트랙  구간  t0 LBA    base    hi/lo/attr   판정")

    mini = bytearray()
    directory = bytearray()
    rows_tsv = []
    hide_rows = []
    track_meta = {}
    ac_mini = int(args.ac_mini, 16)
    dropped = []
    dropped_lines = []          # 죽은 창(자유자리 0)에 걸려 뺀 자막

    for t in sorted(by_track):
        segs = sorted(by_track[t])
        if t in SKIP_TRACKS or (t not in bases and t not in runs):
            why = "관찰 없음" if t not in bases and t not in SKIP_TRACKS else "안전자리 없음"
            dropped.append((t, len(segs), why))
            print(f"  {t:2d}  {len(segs):4d}       -        -       -         ✘{why}")
            continue
        # ★ 이사 계획.  길이 1 이면 지금까지와 똑같이 자리 하나로 간다.
        plan = runs.get(t) or [(max(bases[t]) if args.pick == "highest"
                                else min(bases[t]), 0)]
        if len(plan) > 2:
            raise SystemExit(
                f"트랙 {t}: 이사가 {len(plan) - 1} 회 필요하다.  디렉터리 기록은"
                " 1 회까지다 -- 구조를 늘리거나 관찰을 더 모을 것")
        base = plan[0][0]
        if t in PROVEN_BASE:
            proven = PROVEN_BASE[t]
            if t in bases and proven not in bases[t]:
                raise SystemExit(
                    f"트랙 {t}: 실기 검증값 ${proven:04X} 가 공통 후보에 없다 "
                    f"-- 관찰 데이터가 바뀌었다.  확인할 것")
            # PROVEN_BASE 는 트랙 전체를 같은 자리에서 실제 완주한 값이다.
            # 관찰 표가 구간별 이사를 제안해도 현재 이사 경로는 renderer/helper
            # base를 어긋나게 하므로 출하에서 쓰지 않는다. 검증값을 유지한다.
            base = proven
        if t in PROVEN_FIRST_BASE:
            # ★ 이사가 있는 트랙의 **첫 자리만** 못박는다 (PROVEN_FIRST_BASE 주석).
            #   금지어를 하나씩 빼는 방식은 옆으로 미끄러진다 -- $7B00 을 막으니
            #   $7A00 을 골랐고, 두 블록은 960 word 가 겹친다 (2026-09-06 실측).
            forced = PROVEN_FIRST_BASE[t]
            first_free = PLAN_FREE.get(t)
            if first_free is not None and forced not in first_free:
                # ★ 세우지 않고 경고만 한다.  관찰의 "점유" 는 **심각도를 구분
                #   하지 못한다** -- $7B00 은 총 아이콘이라 계속 화면에 보이고,
                #   $4B00 은 게임이 잠깐 쓰고 마는 자리일 수 있다.  실기가 통과한
                #   값을 관찰이 부정하면, 이 트랙에서는 실기를 따른다.
                print(f"  ⚠ 트랙 {t}: 실기 통과값 ${forced:04X} 가 지금 관찰의 "
                      f"자유자리에 없다 ({len(first_free)}개 후보).  실기를 따른다")
            base = forced
        hi_i, lo_i, at_i = imm3(base)
        t0 = starts.get(t)
        if t0 is None:
            dropped.append((t, len(segs), "t0 LBA 없음"))
            print(f"  {t:2d}  {len(segs):4d}       -        -       -         ✘t0 없음")
            continue
        at = ac_mini + len(mini)
        last_fr, last_ro = None, None

        # ★ 2026-09-06.  자유자리가 하나도 없는 창에 걸린 자막은 **안 싣는다.**
        #
        #   어디에 그려도 게임 그림을 밟는다.  0.5.12 실기(소유자 스크린샷)에서
        #   그런 줄이 쓰레기 타일로 변해 그림을 덮었다 -- 안 뜨는 편이 낫다.
        #
        #   ⚠ 반드시 **이사 번호를 매기기 전에** 걸러야 한다.  이사 번호는 구간
        #     순번이라, 앞에서 한 줄이 빠지면 그만큼 밀린다.  그리고 디렉터리의
        #     count 도 실제로 실은 수여야 한다 -- 안 그러면 런타임이 레코드를 더
        #     읽어 **다음 트랙 자료를 침범한다.**
        dead_ranges = DEAD_WINDOWS.get(t, [])
        manual = MANUAL_DROPS.get(t, [])
        live_segs = []
        for row in segs:
            lo, hi = row[0], row[1]
            # ★ 자리를 못박은 트랙에는 이 규칙을 적용하지 않는다 (2026-09-06).
            #   "그 창에 후보가 없다" 는 **창별로 자리를 고를 때만** 뜻이 있다.
            #   PROVEN_FIRST_BASE 또는 PROVEN_BASE로 한 자리를 박았으면 창의
            #   후보 집합과 무관하다.
            #   게다가 그 관찰은 오늘 세 번 실기와 어긋났다 (1.1.0/1.2.0/1.3.0).
            if (t not in PROVEN_FIRST_BASE and t not in PROVEN_BASE
                    and any(not (dh < lo or hi < dl) for dl, dh in dead_ranges)):
                dropped_lines.append((t, lo, hi, "자유자리 없음"))
                continue
            why = next((w for ml, mh, w in manual if not (mh < lo or hi < ml)), None)
            if why is not None:
                dropped_lines.append((t, lo, hi, f"손으로 뺌 -- {why}"))
                continue
            live_segs.append(row)
        if not live_segs:
            dropped.append((t, len(segs), "자유자리 있는 구간이 없다"))
            print(f"  {t:2d}  {len(segs):4d}       -        -       -         ✘전부 점유")
            continue

        hide_after = INTERMEDIATE_HIDE_AFTER_FRAME.get(t, set())
        frames_in_track = {round((row[0] - t0) * 60 / 75) for row in live_segs}
        missing_hide = hide_after - frames_in_track
        if missing_hide:
            raise SystemExit(
                f"트랙 {t}: 숨김 기준 start_frame이 현재 팩에 없다: "
                + ", ".join(str(v) for v in sorted(missing_hide)))
        emitted_count = len(live_segs) + len(hide_after)
        if emitted_count > 255:
            raise SystemExit(
                f"트랙 {t} mini 항목 {emitted_count} 개 -- count 가 u8 을 넘는다")

        # ★ 이사 지점을 **구간 번호**로 환산한다.
        #
        #   시뮬레이터의 "창" 과 mini 의 "구간" 은 개수가 다르다 (2026-09-05 실측:
        #   705 vs 710.  트랙 9·17·19·20 에서 어긋난다).  그러니 창 순번을 그대로
        #   쓰면 엉뚱한 구간에서 이사한다.  LBA 로 찾아 여기서 번호를 매긴다.
        move_at, move_base = None, None
        if len(plan) > 1:
            move_base = plan[1][0]
            move_lba = plan[1][1]
            for index, (lo, _hi, _ro, _fl) in enumerate(live_segs):
                if lo >= move_lba:
                    # 앞에 숨김 항목이 있으면 실제 mini 순번도 그만큼 뒤다.
                    move_at = index + sum(
                        1 for row in live_segs[:index]
                        if round((row[0] - t0) * 60 / 75) in hide_after)
                    break
            if move_at is None:
                raise SystemExit(
                    f"트랙 {t}: 이사 시작 LBA {move_lba} 에 해당하는 구간이 없다")
            if move_at == 0:
                raise SystemExit(
                    f"트랙 {t}: 이사가 구간 0 에서 일어난다 -- 그러면 첫 자리가"
                    " 쓰이지 않는다.  계획을 다시 볼 것")
        # ★ 2026-09-06.  자유자리가 하나도 없는 창에 걸린 자막은 **안 싣는다.**
        #
        #   어디에 그려도 게임 그림을 밟는다.  0.5.12 실기(소유자 스크린샷)에서
        #   그런 줄이 쓰레기 타일로 변해 그림을 덮었다 -- 안 뜨는 편이 낫다.
        for lo, hi, ro, fl in live_segs:
            ptr = AC_PACK + record_off + ro
            fr = round((lo - t0) * 60 / 75)
            if not (0 <= fr < 0x10000):
                raise SystemExit(f"트랙 {t} start_frame u16 초과: {fr}")
            mini += bytes((ptr & 0xFF, (ptr >> 8) & 0xFF, (ptr >> 16) & 0xFF,
                           fr & 0xFF, (fr >> 8) & 0xFF))
            rows_tsv.append((t, fr, lo, hi, ro, f"{base:04X}"))
            last_fr, last_ro = fr, ro
            if fr in hide_after:
                frames = struct.unpack_from("<H", blob, record_off + ro + 4)[0]
                hide_fr = fr + frames
                if not (0 <= hide_fr < 0x10000):
                    raise SystemExit(f"트랙 {t} hide_frame u16 초과: {hide_fr}")
                mini += bytes((HIDE_RECORD_PTR & 0xFF,
                               (HIDE_RECORD_PTR >> 8) & 0xFF,
                               (HIDE_RECORD_PTR >> 16) & 0xFF,
                               hide_fr & 0xFF, (hide_fr >> 8) & 0xFF))
                rows_tsv.append((t, hide_fr, "", "", "HIDE", f"{base:04X}"))
                hide_rows.append((t, hide_fr, ro))

        # ⚠ 2026-09-05: 여기에 **종료 센티넬**(record_ptr = $000000)을 트랙마다
        #   하나씩 붙이는 판을 만들었다가 **되돌렸다.**
        #
        #   목적은 "마지막 줄을 덮을 다음" 을 만들어 주는 것이었다 (CD-DA 렌더러는
        #   `timed=False` 라 타이머가 없고, 줄은 다음 줄이 덮을 때만 사라진다).
        #   그런데 같은 문제를 **스케줄러 쪽에서** 먼저 해결했다 --
        #   `cdda_drained` / `cdda_deadline_ready` / `cdda_drain_wait` /
        #   `cdda_drain_erase` 가 소진 뒤 마지막 레코드의 `frames` 를 읽어
        #   수명을 세고 지운다 (0.5.6~0.5.7, scheduler 559 -> 664 B).
        #
        #   ★ 트랙 끝에는 여전히 넣으면 안 된다. 마지막 줄은 스케줄러의 frames
        #     만료 경로가 맡는다. 지금 쓰는 $FFFFFF 항목은 **트랙 중간**의 긴
        #     공백에서만 렌더러를 쉬게 하고, 다음 실제 항목에서 다시 켜는 별도
        #     용도다. cdda_due가 상위 바이트 $FF를 명시적으로 알아본다.
        #
        #   모든 트랙 끝에 종료 항목을 되살리면 mini가 5 B x 15 = 75 B 늘어나는
        #   문제도 그대로다. 현재 중간 숨김은 트랙 3의 두 항목(+10 B)뿐이다.
        bcd = (t // 10) * 16 + (t % 10)
        if not (0 < t < 0x80):
            raise SystemExit(f"트랙 번호 {t} 가 raw 한 바이트를 넘는다")
        # ★ count 는 **실제로 실은 수**여야 한다 (len(segs) 아님).
        #   죽은 창을 뺐는데 원래 수를 적으면 런타임이 레코드를 더 읽어
        #   다음 트랙 자료를 침범한다 (2026-09-06).
        entry = bytes((t, bcd, emitted_count,
                       at & 0xFF, (at >> 8) & 0xFF, (at >> 16) & 0xFF,
                       hi_i, lo_i, at_i,
                       # 헬퍼 제어블록 4 B: base lo · base hi · pattern hi · pattern lo
                       0x00, hi_i, (base >> 13) & 0xFF, lo_i))
        # +16 이사 기록.  구간 번호 0 = 이사 없음 (구간 0 에서의 이사는 위에서 막았다)
        if move_at is None:
            entry += bytes(2)
        else:
            entry += bytes((move_at, (move_base >> 8) & 0xFF))
        directory += entry + bytes(DIR_STRIDE - len(entry))
        track_meta[str(t)] = {
            "segments": len(live_segs),
            "mini_entries": emitted_count,
            "base": f"{base:04X}",
            "hide_frames": [frame for ht, frame, _ro in hide_rows if ht == t],
        }
        note = ("  ★실기 검증값" if t in PROVEN_BASE
                else "  (실기 PASS 대역)" if base >= 0x6000
                else "  ★낮은 대역 -- 주의")
        print(f"  {t:2d}  {emitted_count:4d}  {t0:8d}  ${base:04X}  "
              f"{hi_i:02X}/{lo_i:02X}/{at_i:02X}{note}")

    print()
    # ★ 2026-09-05: mini 가 디렉터리 자리를 침범하면 **여기서 멈춘다.**
    #   트랙 3 을 되살리자 3,550 -> 3,665 B 가 되어 옛 디렉터리 주소($1FF900)를
    #   81 B 넘겼다.  그대로 구웠으면 디렉터리 앞머리가 mini 꼬리에 덮여
    #   트랙 검색이 조용히 어긋났을 것이다.  숫자로 막는다.
    room = AC_DIR - ac_mini
    if len(mini) > room:
        raise SystemExit(
            f"mini index {len(mini):,} B 가 자리 {room:,} B 를 넘는다 "
            f"(${ac_mini:06X} ~ ${AC_DIR:06X}).\n"
            "  build_snatcher_0_4_6_43_cdda_adpcm.AC_CDDA_DIR 를 올리고 "
            "여기 AC_DIR 도 같이 고칠 것")
    print(f"mini index  {len(mini):,} B ({len(mini)//MINI_STRIDE} 구간 × {MINI_STRIDE})"
          f"  · 자리 {room:,} B 중 여유 {room - len(mini):,} B")
    print(f"디렉터리     {len(directory):,} B ({len(directory)//DIR_STRIDE} 트랙 × {DIR_STRIDE})")
    print(f"합계         {len(mini)+len(directory):,} B")
    if dropped:
        print()
    if dropped_lines:
        print()
        print(f"★ 안 실은 자막 {len(dropped_lines)} 줄:")
        for t, lo, hi, why in dropped_lines:
            print(f"    트랙 {t:2d}  LBA {lo}~{hi}   {why}")
    if dropped:
        print("빠진 트랙:")
        for t, n, why in dropped:
            print(f"  트랙 {t:2d}  구간 {n:3d}  {why}")

    if UNVERIFIED:
        print()
        print("★★ UNVERIFIED -- 미관찰 창이 섞인 트랙 "
              f"{len(UNVERIFIED)} 개 (2026-09-09 부터 버리지 않고 싣는다)")
        for t in sorted(UNVERIFIED):
            unseen, total = UNVERIFIED[t]
            print(f"    트랙 {t:2d}  창 {total:3d} 중 {unseen:3d} 개를 본 적이 없다")
        print("    base 는 **관찰된 창에서만** 검증됐다.  이 트랙들의 자막이")
        print("    쓰레기 타일로 보이면 그 미관찰 구간부터 의심할 것 --")
        print("    CD-DA VRAM 수집기로 그 구간을 한 번 지나면 닫힌다.")

    # ---- 검산: 포인터가 진짜 레코드를 가리키나 (다른 출처로 확인) ----------
    bad = 0
    for i in range(len(mini) // MINI_STRIDE):
        e = mini[i * MINI_STRIDE:(i + 1) * MINI_STRIDE]
        ptr = e[0] | (e[1] << 8) | (e[2] << 16)
        if ptr == HIDE_RECORD_PTR:
            continue
        at = ptr - AC_PACK
        if not (0 <= at < len(blob) - 6):
            bad += 1; continue
        cells, width, _f, y, frames = struct.unpack_from("<BBBBH", blob, at)
        if not (1 <= cells <= 19 and 1 <= width <= 192 and frames > 0):
            bad += 1
    print()
    if bad:
        raise SystemExit(f"★검산 실패: 레코드가 아닌 포인터 {bad} 개")
    print(f"검산 통과: 실제 레코드와 중간 숨김 {len(hide_rows)}개를 포함한 "
          f"{len(mini)//MINI_STRIDE}개 mini 항목이 유효하다")

    if not args.write:
        print("\n(보고만 했다.  저장하려면 --write)")
        return

    OUT_MINI.write_bytes(bytes(mini))
    OUT_DIR.write_bytes(bytes(directory))
    with OUT_TSV.open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, delimiter="\t")
        w.writerow(["track", "frame", "lba_from", "lba_to", "rec_off", "vram_base"])
        w.writerows(rows_tsv)
    OUT_JSON.write_text(json.dumps({
        "mini_bytes": len(mini), "mini_stride": MINI_STRIDE,
        "dir_bytes": len(directory), "dir_stride": DIR_STRIDE,
        "ac_mini": f"{ac_mini:06X}",
        "pick": args.pick,
        "intermediate_hides": [
            {"track": t, "frame": frame, "after_rec_off": ro}
            for t, frame, ro in hide_rows
        ],
        "tracks": track_meta,
        "dropped": {str(t): why for t, _n, why in dropped},
    }, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"\n-> {OUT_MINI}\n-> {OUT_DIR}\n-> {OUT_TSV}\n-> {OUT_JSON}")


if __name__ == "__main__":
    main()
