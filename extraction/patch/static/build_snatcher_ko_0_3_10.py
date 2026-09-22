#!/usr/bin/env python3
"""Snatcher Korean patch — 0.3.9.  정식 빌드.

0.3.4 이후 0.3.8.x 로 하나씩 시험한 것을 묶어 올린 번호다.

    글자 깨짐        0.3.5 의 상수 슬롯 센티널 검사가 원인 -> 매 레코드 무조건 복사
    검수 규칙        예외처리는 아무것도 싣지 않는다.  O 만 출하
    저장/타이틀/로드  타이틀 스폰에서 캐시를 게임의 유휴 상태로 되돌린다.
                     AC 가 실린 뒤에만 ("SDR4" 가 캐시에 있을 때)
    화자 정렬        화자 이름을 UI 와 같은 줄로 올린다

두 단계다.  엔진 빌드는 스텁을 심기만 하고, 핸들러 표를 돌리는 것은 별도다.

    python build_snatcher_ko_0_3_9.py
    python patch_title_cache_wipe.py \
        --source build\patch\EXPERIMENT\0.3.9-unpatched --out build\patch\0.3.9

근거는 docs\handoff\SNATCHER_KO_0.3.8_RELEASE_2026-08-16.md 와
SNATCHER_SAVELOAD_HANDOFF_2026-08-15.md §0.11 에 있다.

--- 0.3.8.8 원문 ---

화자 이름을 UI 와 같은 줄에 맞춘 판.

0.3.8.7 로 저장/로드 건은 닫혔다 (부팅 · 복귀 · 복귀 후 새로 시작 전부 통과,
2026-08-16).  이 번호는 화면 정렬 하나만 바꾼다.

국장실 액션 메뉴에서 `국장` 만 커서 상자 아래 선에 붙고 `소파`·`모니터`·`창문`·
`그림` 은 한 픽셀 떠 있었다.  원인은 화자와 UI 가 **한 레코드로 합쳐지는 것**이다.

    ui         hangul_y_shift = -1   954개
    speaker    hangul_y_shift =  0    55개   <- 이것
    dialogue   hangul_y_shift =  0   858개   본문 기준선.  이대로가 맞다

둘 다 원문 바이트를 키로 WILDCARD_STATE 에 등록되므로 `局長` 을 화자로 부르든
메뉴 라벨로 부르든 같은 조회이고, 레코드도 비트맵도 하나다.  합칠 때 kind 가 먼저
읽은 `speaker` 로 남는데, 한 줄 올리는 처리는 `kind == "ui"` 에만 걸려 있었다.

화자 겸 UI 인 것이 22 개 -- 전부 인물 이름이라 메뉴에도 나온다.

    길리언 안내원 미카 국장 해리 메탈기어 카트리느 나폴레옹 여자 점원 마스터
    이사벨라 에일리언 Ｈ２Ｏ 걸리버 손님 리사 랜덤 앵무새 제이미 프리먼 코나미

**런타임에서 구분할 근거가 없으므로 한쪽으로만 맞출 수 있다.**  화자 이름도
대사창 UI 밴드에 그려지니 UI 를 따라 올린다.  화자 전용 33 개도 같이 올라간다.

    확인할 것   대사창 위 화자 이름이 한 픽셀 올라간다.  어색하면
                SNATCHER_SPEAKER_LIFT=0 이 0.3.8.7 과 같은 배치다

stage 1 이 바뀌므로 --stage3 로는 안 된다.  전체 빌드를 돌려야 한다.

--- 0.3.8.7 원문 ---

되돌리기를 AC 가 실린 뒤에만 한다.

0.3.8.6 은 값은 맞고 시점이 틀렸다.  `init_store` 는 **첫 한글 조회 때** 도는데
그것이 부팅 타이틀보다 뒤라, 부팅 타이틀의 되돌리기는 아직 아무도 안 실은 AC 를
긁어왔다 (2026-08-16 실측: 한 판은 `08 10 F0 52 ...`, 다음 판은 `F9 A3 A2 21 ...`
-- 매번 다른 값이 곧 미초기화 카드의 모습이다).

판정은 캐시가 답한다.

    $5B80 = 53 ("SDR4")   copy_record 가 돌았다 = AC 가 실려 있다  ->  되돌린다
    그 외                  아직이거나 이미 유휴다                   ->  안 건드린다

AC 가 없을 때는 캐시에 우리 것도 없으니, 건너뛰어도 잃는 것이 없다.

**자리는 포트 모드에서 나왔다.**  위 검사가 `copy_record` 실행을 보장하므로
$1A07/$1A08/$1A09 는 그때 세운 값 그대로다.  그 사이 포트를 바꿀 수 있는 것은
수요 팩 적재의 BIOS CD 읽기뿐인데 `preload=all` 에서는 그런 적재가 없다.
0.3.5 §6 이 이 재기록이 불필요함을 확인해놓고 바로 그 팩 경우 때문에 안 넣었던
것이고, 여기서는 그 경우가 배제된다.  11 B 가 나와 7 B 짜리 검사를 댔다.

    preload 가 all 이 아니면 모드 재기록이 그대로 붙는다 (자리는 그때 다시 본다)

--- 0.3.8.6 원문 ---

지우는 대신 유휴 상태로 되돌리는 판.

0.3.8.5 는 "언제 지우나" 를 맞혔고 "무엇을 써 넣나" 를 틀렸다.

    로드 -> 저장 -> 타이틀 -> **새로 시작**   에서 액션 메뉴가 깨졌다.

복귀에 우리 레코드를 치운 것까지는 옳다.  문제는 그 자리에 $FF 를 남긴 것이다.
$FF 는 "레코드 없음" 이라 로드는 제대로 다시 채우지만, 게임이 실제로 그 버퍼에
두는 값은 따로 있다.  새로 시작은 로드와 달리 게임의 "적재됨" 표시를 리셋하지
않아서, 그 차이가 그대로 화면에 나왔다.

`lua\PROBE 1.0.1.lua` 로 그 값을 쟀다 (2026-08-16).  샘플 7 개 -- 패치 안 한
일본 원본과 0.3.8.5, 세이브 있음과 없음, 타이틀과 로드 직후, 폐공장 세이브에서
타이틀로 나간 경우 -- 에서 **64 바이트가 한 바이트도 다르지 않았다.**  레코드가
아니라 버퍼의 유휴 상태다 (`IDLE_CACHE`).

    82 FF FF 01 3E 00 00 82 FF FF 5E 82 FF FF 5E 82
    FF FF 01 3E 00 00 82 FF FF 5E 82 FF FF 5E 82 FF
    FF 01 3F 00 00 02 08 FF 00 01 6F 00 00 10 FF 01
    70 00 00 FF FF FF FF FF FF FF FF FF FF FF FF FF

**그래서 판정이 통째로 사라졌다.**  값이 어느 상태에서나 같으므로, 부팅 타이틀에
쓰면 이미 있는 값을 다시 쓰는 무해한 동작이고 복귀 타이틀에 쓰면 우리 레코드를
치운다.  0.3.8.2-0.3.8.5 의 네 가지 판정식은 전부 **틀린 값을 언제 써도 되는지**
고르는 문제였고, 값이 맞으면 고를 것이 없다.

    0.3.8.2  gate=count    스폰을 센다        세이브가 있으면 스폰이 하나 더
    0.3.8.3  gate=used     스크래치 깃발      BIOS CD 읽기가 덮는다
    0.3.8.4  gate=header   $5B80 == $FF 인가  부팅에는 $FF 가 아니다
    0.3.8.5  gate=magic    우리 것인가        맞다.  단 치운 자리가 $FF 였다
    0.3.8.6  gate=restore  조건 없음          유휴 상태로 되돌린다

--- 0.3.8.5 원문 ---

타이틀 wipe 판정을 측정으로 정한 판.

0.3.8.2 · 0.3.8.3 · 0.3.8.4 는 "부팅이냐 복귀냐" 를 각각 스폰 수 · 스크래치 깃발 ·
캐시 헤더로 때려맞혔고 셋 다 틀렸다.  근거가 전부 관측이 아니라 추론이었다.
`lua\PROBE 1.0.0.lua` 로 타이틀 스폰마다 $5B80 을 찍었다 (2026-08-16).

    부팅   #1  82 FF FF 01 3E 00 00 82     게임 자신의 레코드
           #2  FF ...                       (우리가 #1 에서 지운 결과일 뿐)
           #3  FF ...                       세이브가 있으면 스폰이 하나 더 난다
    복귀   #5  53 44 52 34 09 0A DB 54     "SDR4" -- 우리 레코드

**부팅에 깨진 이유가 여기서 끝난다.**  선적재된 캐시가 날아간 것이 아니라
**게임 자신의 레코드를 우리가 $FF 로 밀어버린 것**이었다.

그래서 판정은 하나면 된다 -- 우리가 넣은 것일 때만 지운다.
build_direct_overlay_layout 이 MAGIC = b"SDR4" 를 모든 레코드 payload[0:4] 에
무조건 찍으므로, 캐시에서 그 넉 자로 시작하는 것은 우리 것뿐이다.

    $5B80 = 53 44 ...   우리 레코드      ->  지운다
    $5B80 = 82 ...      게임 레코드      ->  안 건드린다
    $5B80 = FF ...      이미 지웠다      ->  안 건드린다

상태를 안 두므로 BIOS CD 읽기에 날아갈 것이 없고(0.3.8.3), 부팅 스폰이 2 개든
3 개든 상관없고(0.3.8.2), 캐시가 처음에 비어 있다고 가정하지 않는다(0.3.8.4).

--- 0.3.8.4 원문 ---

타이틀 wipe 판정에서 상태를 없앤 판.

0.3.8.3 은 절반만 맞았다 (2026-08-16, 소유자 실측).

    세이브 있는 상태로 새로 시작   고쳐짐    판정을 카운트에서 상태로 바꾼 것은 옳았다
    저장 -> 타이틀 -> 로드          재발      깃발이 날아갔다

깃발 `CACHE_USED` 는 케이브 스크래치($BFE0-$BFFF)에 있는데, 스텁이 도는 MPR3=$69
상태에서 그 뱅크는 $6000-$7FFF 에 얹힌다.  즉 그 깃발은 $7FF1 이고, PROBE 0.7.0 이
$7FC0-$7FFF 전 바이트를 BIOS CD 읽기($EA9E)가 덮어쓴다고 측정한 바로 그 범위다.
타이틀로 나가는 동안 CD 를 읽으므로 깃발이 지워지고, 복귀 타이틀에서 wipe 가 안
걸린다 -- skip2 가 원래 고쳤던 버그가 그대로 돌아온다.

그래서 깃발을 없앴다.  **캐시 헤더 자신이 이미 그 정보다.**

    $5B80 == $FF   레코드 없음 = 부팅이거나 이미 지웠다   ->  지우지 않는다
    $5B80 != $FF   저장 전에 그려둔 묵은 레코드가 있다    ->  지운다

§0.2 실측이 근거다 -- "원본은 BIOS CD 읽기가 이 버퍼를 계속 갈아준다.  재로드
시점에 FF 였다."  그리고 wipe 자신이 $FF 를 쓰므로 지운 뒤 판정은 저절로 맞는다.
$5B80 은 MPR2 라 그 덮어쓰기 범위 밖이고, 스크래치를 안 쓰니 날아갈 것도 복구할
것도 없다.

--- 0.3.8.3 원문 ---

타이틀 wipe 판정을 카운트에서 상태로 바꾼 판.

0.3.8.2-skip2 는 **세이브 파일이 있을 때 새로 시작하면** 액션 메뉴 첫 줄이 쓰레기
타일로 나왔다 (2026-08-16, 소유자).  세이브가 없으면 정상이고, 세이브를 로드하면
정상이다.

원인은 카운터다.  skip2 는 전원 투입 후 타이틀 스폰 2 개를 흘리는 절대 카운트인데,
그 2 는 세이브 없는 부팅 경로에서 잰 값이다.  세이브가 있으면 타이틀에
CONTINUE/NEW GAME 이 붙어 스폰이 하나 더 나고, 3 번째가 카운터 0 을 만나 **아직
부팅인데** 갓 선적재된 캐시를 지운다 -- §0.8 이 적은 그 증상 그대로다.

`SKIP=3` 은 답이 아니다.  세이브 없는 경로에서 첫 복귀 타이틀을 건너뛰게 된다.
세이브 유무로 부팅 길이가 달라지는 한 고정 카운트로는 양쪽을 못 맞춘다.

그래서 세는 대신 묻는다 -- **이 캐시가 쓰인 적 있는가.**

    부팅   선적재로 채워졌고 한글은 한 자도 안 그렸다   ->  지우지 않는다
    복귀   대사를 그렸으니 묵은 레코드가 들어 있다      ->  지운다

`copy_record` 가 레코드를 실제로 재구성했을 때만 깃발을 세우고, 스텁은 그 깃발이
서 있을 때만 지우고 도로 눕힌다.  선적재 경로는 copy_record 를 지나지 않으므로
부팅 타이틀은 스폰이 몇 개였든 깃발이 누워 있다.

--- 0.3.8.2 원문 ---

0.3.8.1 + 타이틀 캐시 wipe 스텁 (skip2).

이 빌드 자체는 스텁을 **엔진 이미지에 넣기만 한다.**  장면 VM 핸들러 표 $7331 을
스텁으로 돌리는 것은 별도 단계다.  그래서 이 폴더는 "스텁은 있으나 불리지 않는"
대조군이고, 실제로 플레이할 디스크는 그 다음이다.

    python build_snatcher_ko_0_3_9.py
    python patch_title_cache_wipe.py --source build\patch\0.3.8.8 --tag skip2

스텁 30 B 는 EXPERIMENT\0.3.7-titlewipe-skip2 디스크에서 떠와 바이트 단위로
대조했다 (소스가 트리에서 사라져 있었다).  DEC 의 자기 오퍼랜드 주소는 케이브
배치를 따라 계산된다 -- 헬퍼 크기가 765 -> 741 B 로 바뀌어 스텁이 옮겨갔다.

**§0.10 을 먼저 읽을 것.**  §0.9 가 적은 "액션 메뉴 깨짐" 은 묵은 BRAM 세이브였을
가능성이 크다.  N(=64) 을 줄이는 작업은 착수하지 말 것.

--- 0.3.8.1 원문 ---

상수 슬롯 재작성을 0.3.4 로 되돌린 판.

0.3.8 은 0.3.4 로 되돌렸다고 했지만 되돌린 것은 환경변수 셋뿐이었고, 0.3.5 가
실제로 바꾼 헬퍼 코드는 공유 stage 3 모듈에 그대로 남아 있었다.  그래서 0.3.8
디스크도 `실례지만… 누구신가요?` 의 줄임표 칸이 깨졌다 (2026-08-16 확인).

    0.3.4     helper 713 B   상수 96 B 를 매 레코드 무조건 복사
    0.3.5-7   helper 765 B   센티널 2 바이트만 보고 건너뜀
    0.3.8     helper 755 B   ^ 그대로 물려받음.  깨짐 재현됨
    0.3.8.1   helper 741 B   SNATCHER_CONST_CHECK=0 -- 무조건 복사로 복귀

센티널은 슬롯 0 의 첫 바이트와 슬롯 2 의 마지막 바이트만 본다.  그 사이가
깨지면 검사를 통과하고 영영 복구되지 않는데, 슬롯 2 가 줄임표다.

**0.3.8 폴더는 건드리지 않는다.**  그 디스크가 깨짐을 재현한 대조군이다.
0.3.6 docstring 이 "0.3.5 를 제자리에서 덮어써 릴리스 노트와 디스크가 어긋났다"
고 남긴 경고가 있다.  변형마다 번호를 새로 딴다.

--- 0.3.8 원문 ---

0.3.5-0.3.7 에서 글자 깨짐이 나와 마지막으로 정상이던 0.3.4 로 되돌렸다.
여기에 저장 -> 타이틀 -> 로드 수정(handoff §0.6-§0.9)을 올린다.

--- 0.3.4 원문 ---

Snatcher Korean patch — 0.3.4.  THE official entry point.

Run this, not the individual stage scripts.  It pins every parameter that the
three stages used to take by hand, so a build is reproducible from the master
TSVs alone:

    python build_snatcher_ko_0_3_9.py              full build (stages 1-3)
    python build_snatcher_ko_0_3_9.py --stage3     stage 3 only, reusing stage 1/2
    python build_snatcher_ko_0_3_9.py --check      validate inputs, build nothing

0.3.4 — the abandoned-factory flicker
-------------------------------------
0.3.3 flickered whenever Korean text started drawing in the abandoned factory:
the bottom edge of the scene picture slipped down for a single frame and came
straight back.  Three separate causes, each measured and fixed independently.
See docs\\handoff\\SNATCHER_UI_FLICKER_HANDOFF_2026-08-14.md for the evidence.

    1. The 608-byte template moved in ONE `TAI`.  Block transfers are atomic on
       the HuC6280, so that instruction held interrupts off for 3,665 cycles --
       8.05 scanlines -- on every string.  Now 76 B x 8: 1.04 scanlines.
       `SNATCHER_TAI_CHUNK=608` restores the old single transfer.

    2. Packs loaded from CD on first touch, and a stray probe could pull in a
       pack nobody needed.  The game streams CD by itself in that scene on a
       13-14 frame cadence, and every one of our loads pushed its next read out
       to 22-30 frames; an untranslated line could stall for ~4 seconds.  All 25
       packs now load during init.  `SNATCHER_PRELOAD_PACKS=0` goes back to
       demand loading.

    3. That same 608-byte copy ran on every record purely to restore constants
       and blank glyph slots.  It now moves 96 + (previous record's glyph
       count) * 32 bytes, which does both jobs exactly.

           record cost   5,631 -> 3,829 cycles
           IRQ block     8.05  -> 1.04 scanlines
           CD in play    per-pack load + 2 seeks -> none

What is NOT fixed
-----------------
Flicker still appears sporadically, and much more often after a voice line
plays (roughly 3-in-10 before, 9-in-10 after, and it does not recover).  The
game appears to lose frame budget to ADPCM servicing once voice has played;
this patch cannot change that, only cost less.  It is a budget problem, not a
defect -- nothing corrupts, nothing blocks progress.

Rolling back
------------
Every stage is shared with 0.3.3, so a rollback is a one-line choice, not a
revert:

    python build_snatcher_ko_0_3_3.py              0.3.3 exactly as it shipped
    SNATCHER_PRELOAD_PACKS=0 python build_snatcher_ko_0_3_9.py
                                                  0.3.4 without the preload
    SNATCHER_TAI_CHUNK=608 ...                    0.3.4 without the TAI split

`build\\patch\\0.3.3\\` is PROTECTED and still has its payload, so the old disc
can also just be played.

Do NOT reach for the faster variants built on 2026-08-14 (`noblank`, `both`,
`lean`, `lean2`).  They drop the glyph blanking, which costs a record whose text
references a trailing blank slot: the previous line's syllable stays on screen.
It is rare enough to pass a short test and still reach players.

Version history behind this number
----------------------------------
The engine is the verified ``0.3.0-uitest`` renderer.  ``ac_0.1.1`` through
``ac_0.1.18`` were the Arcade Card backing-store development series on top of
it; ``ac_0.1.14`` was the last one.  0.3.0 promoted that combination to the
project's single version number; 0.3.1 fixed the AC layout, 0.3.2 gave each
scene pack its own address, 0.3.3 froze the pipeline, and 0.3.4 is the flicker
work above.

What is frozen
--------------
    engine            0.3.0-uitest renderer.  $66E5 hook, $5E40 preloader,
                      $7F50 font wrapper, $5B80-$5E3F 704 B cache.  Do not
                      redesign these.
    record format     128 B compact record + global glyph atlas, expanded back
                      to a byte-identical 704 B payload by the Bank 69 helper
    CHUNK_BYTES       8 KiB.  Hard ceiling — above it the BIOS loses the AC
                      auto-increment pointer at a bank boundary
    stage 1 base      ac_0.1.11-source (intermediate, not a release)
    inclusion         BODY: first unnamed review column is O (예외처리 = context
                      -only continuation).  UI: review column is O.
                      ko_text or status alone never ships a row.

Inputs — the only canonical ones
--------------------------------
    snatcher_tool/translation/snatcher_ko_master.tsv
    snatcher_tool/translation/ui_text.tsv
    snatcher_tool/translation/speaker_name_standard.tsv

Edit them through SnatcherTranslationStudio.exe.  Close Studio before touching
them from outside, or Studio will write back its stale review column on save.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

STATIC = Path(__file__).resolve().parent
ROOT = STATIC.parents[2]
sys.path.insert(0, str(STATIC))

VERSION = "0.3.10"
STAGE1_VERSION = "ac_0.1.11-source"
STAGE1_BUILD = ROOT / "build" / "patch" / STAGE1_VERSION
# 0.3.8.3 이후는 판정식을 하나씩 시험한 판들이라 EXPERIMENT 아래로 모았다.
# 최상위에는 0.3.8.2 까지만 둔다 (소유자 지정, 2026-08-16).
OUT = ROOT / "build" / "patch" / "EXPERIMENT" / f"{VERSION}-unpatched"

TRANSLATION = ROOT / "snatcher_tool" / "translation"
CANONICAL_INPUTS = (
    TRANSLATION / "snatcher_ko_master.tsv",
    TRANSLATION / "ui_text.tsv",
    TRANSLATION / "speaker_name_standard.tsv",
    # Stage 3 copies this into the build folder as a provenance record, so a
    # missing file fails the build at the very last step.
    TRANSLATION / "master_conflict_exclusions.tsv",
)

# 0.3.4's defaults, set here rather than left to whoever remembers the export.
# A build has to be reproducible from this file alone.
DEFAULTS = {
    "SNATCHER_PRELOAD_PACKS": "1",   # no CD access during play
    "SNATCHER_TAI_CHUNK": "76",      # 1.04 scanlines of IRQ block, not 8.05
    "SNATCHER_BLANK_SLOTS": "1",     # bounded blanking; 0 leaves stale glyphs
    # The flags above were never what 0.3.5 changed.  It rewrote the helper, and
    # the rewrite is in the shared stage-3 module, so 0.3.8 inherited it: helper
    # 755 B against 0.3.4's 713 B.  This is the piece that had to come back --
    # see SNATCHER_CONST_CHECK in build_ac_dynamic_0_1_14.py for the evidence.
    "SNATCHER_CONST_CHECK": "0",     # re-lay the constants every record, as 0.3.4 did
    "SNATCHER_TITLE_WIPE": "1",      # assemble the title-cache wipe stub (§0.7-§0.9)
    "SNATCHER_TITLE_WIPE_GATE": "restore", # 지우지 않고 게임의 유휴 상태로 되돌린다
    "SNATCHER_SPEAKER_LIFT": "1",          # 화자 이름도 UI 와 같은 줄에 맞춘다
    "SNATCHER_TITLE_WIPE_BYTES": "64",
}

# Names refused even when named explicitly.  0.3.3 stays playable as the
# rollback target, 0.2.26 is the BODY control build, and the other two are what
# the current build stands on.
PROTECTED = {VERSION, "0.3.9-unpatched", "0.3.8.7", "0.3.8.6", "0.3.8.5", "0.3.8.4", "0.3.8.3", "0.3.8.2", "0.3.8.1", "0.3.8", "0.3.7", "0.3.6", "0.3.5", "0.3.4", "0.3.3", STAGE1_VERSION, "ac_0.1.14", "0.2.26"}
PAYLOAD_SUFFIXES = (".bin", ".chd")


def prune(names: list[str], deep: bool = False) -> None:
    """Delete disc payloads from the named builds, keeping their records.

    Standing rule from the project owner: **no build is ever pruned unless he
    has called that build an experiment.**  The caller has to name what goes,
    so nothing goes by default.
    """
    targets = set(names) | ({STAGE1_VERSION} if deep else set())
    if not targets:
        raise SystemExit(
            "--prune needs the build folders to drop, e.g.\n"
            f"    --prune {VERSION}-base {VERSION}-experiment\n"
            "No build is pruned unless it is named an experiment.")
    guarded = targets & PROTECTED
    if guarded:
        raise SystemExit(f"refusing to prune protected build(s): "
                         f"{', '.join(sorted(guarded))}")
    root = ROOT / "build" / "patch"
    freed = unlinked = 0
    for build in sorted(p for p in root.iterdir() if p.is_dir()):
        if build.name not in targets:
            continue
        for path in sorted(build.rglob("*")):
            if not path.is_file() or path.suffix.lower() not in PAYLOAD_SUFFIXES:
                continue
            stat = path.stat()
            # A hardlinked track shares its inode with rom(japan), so removing
            # this name frees nothing.  Drop it anyway to keep the folder
            # honest, but do not claim the bytes back.
            if stat.st_nlink > 1:
                unlinked += 1
            else:
                freed += stat.st_size
            path.unlink()
    if freed or unlinked:
        print(f"pruned {freed / 1e6:,.0f} MB "
              f"({unlinked} hardlinked track names also dropped) from "
              f"{', '.join(sorted(targets))}")


def check_inputs() -> None:
    missing = [p for p in CANONICAL_INPUTS if not p.exists()]
    if missing:
        raise SystemExit(
            "missing canonical input(s):\n  "
            + "\n  ".join(str(p) for p in missing)
        )

    sys.path.insert(0, str(ROOT / "extraction" / "translation"))
    import build_full_overlay_layout as layout
    from tsv_io import read_dict_rows

    selected, exceptions = layout.reviewed_row_ids(TRANSLATION / "snatcher_ko_master.tsv")
    ui_header, ui_rows = read_dict_rows(TRANSLATION / "ui_text.tsv")
    review = layout.ui_review_column(ui_header)
    ui_ok = [r for r in ui_rows
             if r.get("ko_text", "").strip()
             and r.get("status", "") != "skip"
             and layout.is_ui_reviewed(r, review)]
    ui_translated = [r for r in ui_rows if r.get("ko_text", "").strip()]

    print(f"BODY  reviewed rows : {len(selected):,} (예외처리 {len(exceptions)})")
    print(f"UI    review column : {review!r}")
    print(f"UI    translated    : {len(ui_translated):,} / {len(ui_rows):,}")
    print(f"UI    review = O    : {len(ui_ok):,}   <- this is what ships")
    if ui_translated and not ui_ok:
        print()
        print("  NOTE: every UI row is unreviewed, so this build ships 0 UI labels.")


def stage(argv: list[str], title: str) -> None:
    print(f"\n=== {title} ===", flush=True)
    # Pin the translator workspace rather than trusting the ambient default.
    env = dict(os.environ, SNATCHER_TRANSLATION_DIR=str(TRANSLATION))
    result = subprocess.run([sys.executable, *argv], cwd=str(ROOT), env=env)
    if result.returncode != 0:
        raise SystemExit(f"{title} failed (exit {result.returncode})")


def main() -> None:
    global VERSION, OUT, STAGE1_VERSION, STAGE1_BUILD

    parser = argparse.ArgumentParser(description=f"build Snatcher KO {VERSION}")
    parser.add_argument("--stage3", action="store_true",
                        help="rebuild only stage 3, reusing the existing "
                             f"{STAGE1_VERSION} intermediate")
    parser.add_argument("--check", action="store_true",
                        help="report what would ship, then stop")
    parser.add_argument("--prune", nargs="*", metavar="BUILD",
                        help="delete the named builds' disc payload, then stop. "
                             "Name only builds the owner has called experiments "
                             "-- nothing is pruned by default")
    parser.add_argument("--deep", action="store_true",
                        help=f"with --prune, also drop the {STAGE1_VERSION} "
                             "intermediate (costs the next build its --stage3)")
    parser.add_argument("--space", choices=("8140", "F041", "20"), default="8140",
                        help="byte sequence a Korean word space compiles to. "
                             "8140 = native full cell (default, what ships). "
                             "F041 = reserved fractional space, two per cursor "
                             "unit. 20 = the renderer's single-byte space "
                             "branch. Non-default values build into a suffixed "
                             "folder and are experiments, not releases.")
    parser.add_argument("--tag", default="",
                        help="suffix the build and its stage 1/2 intermediate "
                             "with this name. Use it when the experiment is in "
                             "the translation data rather than in a flag, so "
                             "the release folder is never overwritten.")
    args = parser.parse_args()

    # Apply 0.3.4's defaults without clobbering a deliberate override, so
    # `SNATCHER_PRELOAD_PACKS=0 python build_snatcher_ko_0_3_9.py` still works
    # as the documented rollback.
    for name, value in DEFAULTS.items():
        os.environ.setdefault(name, value)
    changed = {n: os.environ[n] for n, v in DEFAULTS.items() if os.environ[n] != v}
    if changed:
        print("non-default runtime options: "
              + ", ".join(f"{n}={v}" for n, v in sorted(changed.items())))

    suffix = ""
    if args.space != "8140":
        os.environ["SNATCHER_KO_SPACE"] = args.space
        suffix += f"-space{args.space}"
        print(f"space experiment: Korean word spaces compile to {args.space}")
    if args.tag:
        suffix += f"-{args.tag}"

    if suffix:
        # Keep the release build untouched: an experiment gets its own folder
        # and its own name so a stray disc can never be mistaken for a release.
        VERSION = f"{VERSION}{suffix}"
        STAGE1_VERSION = f"{STAGE1_VERSION}{suffix}"
        OUT = ROOT / "build" / "patch" / "EXPERIMENT" / f"{VERSION}{suffix}-unpatched"
        STAGE1_BUILD = ROOT / "build" / "patch" / STAGE1_VERSION
        PROTECTED.update({VERSION, STAGE1_VERSION})
        print(f"  stage 1/2 -> {STAGE1_BUILD}")
        print(f"  output    -> {OUT}")

    if args.prune is not None:
        prune(args.prune, deep=args.deep)
        return

    check_inputs()
    if args.check:
        return

    if args.stage3:
        if not STAGE1_BUILD.exists():
            raise SystemExit(
                f"--stage3 needs {STAGE1_BUILD}, which is missing. "
                "Run without --stage3 to regenerate it.")
        print(f"\nreusing stage 1/2 intermediate: {STAGE1_BUILD}")
    else:
        stage([str(STATIC / "build_direct_overlay_patch_ui.py"),
               "--version", STAGE1_VERSION, "--review-only", "--force"],
              "stage 1  master -> 704 B SRT4 records")
        stage([str(STATIC / "build_ac_backing_store.py"),
               "--build", str(STAGE1_BUILD)],
              "stage 2  sparse slots -> dense record image")

    print("\n=== stage 3  compact 128 B + atlas + AC packs + disc ===", flush=True)
    import build_ac_dynamic_0_1_14 as stage3

    # Same wrapper pattern the AC series used: retarget the shared dynamic
    # module, then run the pinned stage 3.
    dynamic = stage3.dynamic
    dynamic.VERSION = VERSION
    dynamic.OUT = OUT
    dynamic.BASE = STAGE1_BUILD
    stage3.main()

    print(f"\n{VERSION} -> {OUT}")


if __name__ == "__main__":
    main()
