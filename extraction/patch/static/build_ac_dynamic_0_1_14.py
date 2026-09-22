#!/usr/bin/env python3
"""Build ac_0.1.14: compact 128-byte records restored from a global glyph atlas.

Problem this solves
-------------------
ac_0.1.13's first reception dialogue takes ~11.5 s.  Measurement showed the
cost is `number of BIOS CD_READ calls x ~188 ms` plus transfer time, and the
byte volume is dominated by the 608-byte local glyph area duplicated in every
704-byte record.  Only 22,944 bytes of that data is actually unique.

    1,046 records x 704 B          = 736,384 B
    unique 32-byte glyph bitmaps   =  22,944 B  (717 glyphs, 27.7x duplicated)

What changes
------------
The disc now stores a 128-byte compact record plus one global atlas.  The
helper rebuilds the byte-identical 704-byte payload into the existing
$5B80-$5E3F cache, so the verified 0.3.0-uitest BODY/UI renderer, the $5E40
preloader, the $7F50 font wrapper and the $66E5 hook are all untouched.

    compact record (128 B)
      $00-$5F  metadata + encoded Korean text   (copied verbatim to $5B80)
      $60-$7D  15 x 16-bit atlas word offsets   ($FFFF = unused slot)
      $7E-$7F  padding

    AC layout
      $00000-$0FFFF  64 KiB slot directory                 (unchanged)
      $10000-$100FF  state page: magic/flags, pack metadata at +$80
      $10100-$1035F  608-byte cache template
      $10360-...     global glyph atlas
      $16000-...     resident packs, then the scene region.  This floor is
                     max($16000, end of the chunk-padded initial load), not a
                     bare constant: an atlas past 741 glyphs pushes it up
                     instead of being overwritten by the packs.

The template is a full 19-slot image: slots 0/1/2 hold the constant
period/blank/ellipsis glyphs, slot 18 holds FRACTIONAL_SPACE_HELPER, and slots
3..17 are zero.  Writing it first therefore restores the constants, restores
the $674A helper code at $5E20, and clears every unused glyph slot in one
block transfer.  Only the slots a record actually uses are then filled.

Verified against the real data before this builder was written
--------------------------------------------------------------
    slots 0,1,2  constant across all 1,046 records
    slot 18      byte-identical to FRACTIONAL_SPACE_HELPER
    slots 3..17  filled from the front, no holes, max 15, mean 7.785
    reassembly   1,046 / 1,046 byte-exact

The atlas is keyed on the 32-byte bitmap, not on the character, because UI
glyphs are shifted up one pixel: the same syllable has a BODY bitmap and a UI
bitmap.  717 unique bitmaps come from 620 unique syllables.

Helper budget
-------------
The Bank 69 cave is a hard 814 bytes ($BCD2-$BFFF); the byte below it is real
game code (`60` = RTS) and neither Bank 69 nor Bank 6A has another 32-byte FF
run.  Three changes pay for the new expansion routine:

    pack metadata table 88 B  -> AC state page          frees 88 B
    final-chunk sector table  -> FINAL_LO holds the      frees 22 B
                                 sector count directly
    set_ac inlined 3 x 31 B   -> subroutine             frees 34 B

Not changed here
----------------
The 64 KiB directory is still loaded whole and is now the largest single item
in the initial load.  That is ac_0.1.15's job, deliberately kept separate so
this build changes one variable.
"""

from __future__ import annotations

import csv
import json
import os
import shutil
import sys
from collections import OrderedDict
from pathlib import Path


ROOT = Path(r"C:\snatcher")
STATIC = ROOT / "extraction" / "patch" / "static"
sys.path.insert(0, str(STATIC))

import build_ac_dynamic_0_1_11 as assignment  # noqa: E402
import build_disc_patch as common  # noqa: E402


dynamic = assignment.dynamic

VERSION = "ac_0.1.14"

RECORD_BYTES = 704
COMPACT_BYTES = 128        # BIOS 판에서는 TEXT_SPAN 으로 줄어든다 (아래 재정의)
TEXT_SPAN = 0x60          # metadata + encoded text copied verbatim
GLYPH_BYTES = 32
SLOT_COUNT_PER_RECORD = 19
TEMPLATE_BYTES = SLOT_COUNT_PER_RECORD * GLYPH_BYTES   # 608

# How much of the template one block transfer may move.  Block transfers are
# atomic on the HuC6280: 17 + 6 cycles per byte with interrupts held off for the
# whole instruction.  One TAI over all 608 bytes therefore blocked IRQs for
# 3,665 cycles -- about eight scanlines at 455 cycles a line -- on every single
# Hangul output.  A scene whose display is maintained by a raster interrupt
# shows that as its split boundary slipping for exactly one frame; 76 B bounds
# the block to 473 cycles, just over one line.
#
# Any divisor of 608 is byte-identical: $1A00 and $1A01 are two mirrors of the
# same AC data register, so cutting the transfer cannot reorder the stream, and
# the destination range is contiguous, so the chunks need no self-modification.
#
# SNATCHER_TAI_CHUNK=608 restores the single transfer, which is what every build
# up to 0.3.3 emitted.  That is the control disc for this experiment: one source
# tree produces both sides, so the split is provably the only difference.
# Load every pack during init instead of on first touch.
#
# Measured 2026-08-14 in the abandoned factory (dump\ui_load_v11_180102.tsv):
# the game streams CD by itself on a steady 13-14 frame cadence there.  Five of
# our demand loads landed inside a streaming run and *all five* pushed the
# game's next read out to 22-30 frames -- we take the drive away from it, seek
# to Track 24 and back, and its stream stalls for about 17 frames.  Nothing
# else in the log came close: heavy frames 0, probe misses 1 in the whole
# session, every pack loaded exactly once.  So the cost is the CD access
# itself, not the work around it.
#
# Disc image is directory + init_extra + blob and the blob's offset equals
# init_total, while common_data_base resolves to init_total as well -- disc
# offset and AC address coincide.  So one contiguous init read covers the lot,
# provided every pack is contiguous (see build_packs_compact).
#
# load_package / load_blob stay in the helper.  They simply stop firing, and
# remain as the fallback if a pack ever is not resident.
#
# "all" costs 52 chunks at boot -- roughly 9.8 s at the measured 188 ms per
# BIOS CD_READ, which owners hit on every power cycle.  "resident" reads only
# as far as the four resident packs (35 chunks, ~6.6 s) and leaves the 21 scene
# packs to the demand path.  That is safe to cut at because the resident packs
# are pack ids 0-3 and sit at the front of both the blob and AC, contiguously:
# the read simply stops earlier.  The stalls that motivated "all" came from the
# 122 KB ui pack arriving on demand; scene packs average 5.8 KB (34 KB worst).
#
#   all       every pack preloaded          52 chunks   no CD access during play
#   resident  speaker/ui/small/shared only  35 chunks   scene packs on demand
#   none      nothing preloaded             13 chunks   pre-0.3.4 behaviour
# Unset means "none", exactly as the original `== "1"` test did.  The 0.3.4
# entry point setdefault()s "1", so only a direct stage-3 run or an older entry
# point (0.3.3, which must stay reproducible) sees the unset case.
_PRELOAD_MODES = {"1": "all", "all": "all", "resident": "resident",
                  "0": "none", "none": "none", "": "none"}
_preload_raw = os.environ.get("SNATCHER_PRELOAD_PACKS", "").strip().lower()
if _preload_raw not in _PRELOAD_MODES:
    raise SystemExit(
        f"SNATCHER_PRELOAD_PACKS={_preload_raw!r} is not one of "
        f"{sorted(set(_PRELOAD_MODES.values()))}")
PRELOAD_MODE = _PRELOAD_MODES[_preload_raw]
# Kept as a bool so the existing "is anything preloaded at all?" tests read the
# same; the resident/all split is asked for explicitly where it matters.
PRELOAD_PACKS = PRELOAD_MODE != "none"

# Blank the glyph slots the previous record used.
#
# The 608-byte template copy was doing this implicitly: 480 of its bytes are
# zeros, so re-laying it cleared whatever the last record wrote.  Bounding that
# to what was actually written made a record cost depend on the *previous*
# record -- a 15-glyph dialogue line leaves the next record paying 96 + 480 B,
# barely less than the old fixed 608.  Alternating dialogue and menus therefore
# lands on the expensive side every time, which is what the abandoned-factory
# menu/dialogue ping-pong does.
#
# SNATCHER_BLANK_SLOTS=0 stops tracking, so the length stays at the constants
# and the run never grows.  That is only correct if the renderer reads no glyph
# slot the record's text does not reference.  Unverified -- this exists to find
# out: build it, put a short menu straight after a long line, and look for a
# leftover syllable.
# BIOS 폰트 경로 (SNATCHER_KO_BIOS=1).  한글이 시스템 카드 글리프로 나가므로
# 레코드에 우리 글리프가 실리지 않는다 (build_full_overlay_layout 이 안 굽는다).
# 그러면 이 단계의 아틀라스·인덱스 전송·글리프 루프가 통째로 할 일이 없다:
#
#   레코드당  텍스트 593 + 인덱스 전송 + 글리프 15 x 209 = 약 3,800 사이클
#             -> 텍스트만 남아 약 650 사이클.  8.3 스캔라인이 1.5 로 떨어진다
#   공간      압축 레코드 128 -> 96 B (아틀라스 오프셋 15 x 2 가 사라진다)
#             아틀라스 이미지도 0 B 가 된다
#
# 상수 3 칸(F040 마침표 / F041 공백 / F042 말줄임)과 반칸 도우미는 남으므로
# 608 B 템플릿과 그 상수 검사는 그대로 둔다.
BIOS_FONT = os.environ.get("SNATCHER_KO_BIOS", "0").strip() == "1"

BLANK_SLOTS = os.environ.get("SNATCHER_BLANK_SLOTS", "1") != "0"

# Re-lay the 96 B of constant glyphs (period / blank / ellipsis) every record,
# or trust two sentinel bytes and skip when they look intact?
#
# 0.3.5 added the sentinel check to save 593 cycles a record, on the reasoning
# that nothing but that transfer writes $5BE0-$5C3F any more.  Its own note
# records that this is false -- something outside the helper reaches the range --
# so it checked rather than skipping outright.  But the check only reads the
# FIRST byte of slot 0 and the LAST byte of slot 2.  Damage anywhere between
# those two bytes passes the check and is never repaired, and slot 2 is the
# ellipsis: 2026-08-16, `실례지만… 누구신가요?` rendered with the ellipsis cell
# corrupted and the corruption bleeding into the syllables after it.  0.3.4 did
# not have the check, re-laid the constants unconditionally, and repaired that
# damage on the very next record, which is why it was never visible there.
#
# 0.3.5, 0.3.6 and 0.3.7 all carry the check unchanged (helper 765 B in each),
# which is why the symptom appears in all three.
CONST_CHECK = os.environ.get("SNATCHER_CONST_CHECK", "1") != "0"

# Title-cache wipe stub (the "skip2" work -- SNATCHER_SAVELOAD_HANDOFF §0.7-§0.9).
#
# Save -> title -> reload leaves broken tiles because our record cache at $5B80
# survives the transition and the game trusts it.  Filling the header with $FF
# makes it read "no record" and refill.  The stub answers three questions in
# order, and every one of them was learned the hard way:
#
#   is this the title spawn?   the scene VM's spawn handler runs for every
#                              spawn; only $95xx is the title
#   is this a *boot* title?    booting issues the spawn TWICE ($9520 and $95C2).
#                              Wiping then destroys the just-preloaded cache and
#                              nobody refills it -- the action menu came up as
#                              garbage tiles.  So let two spawns through, using
#                              the LDA immediate itself as the counter.
#   how much to wipe?          64 B.  §0.9 wanted to shrink this; §0.10 found the
#                              symptom that motivated it was probably a stale
#                              BRAM save, and that N=64 and N=48 produced
#                              identical records.  Measure `eff` before touching.
#
# The stub lives in the Bank 69 cave; build_disc_patch's patch_title_cache_wipe.py
# diverts handler-table entry $7331 to it.  The DEC self-modifies the immediate,
# so its operand is the stub's own address in the $6000 window -- computed here,
# never copied, because the cave layout moves whenever the helper changes size.
# How the stub decides a spawn is a *return* title rather than a boot one.
#
#   count  0.3.8.2's rule: let the first SKIP title spawns through, using the
#          LDA immediate as a countdown.  Calibrated on the no-save boot path,
#          which issues two.  A BRAM save adds the CONTINUE/NEW GAME step and
#          therefore a third spawn, so the countdown ran out while still
#          booting and wiped the freshly preloaded cache -- garbage tiles on
#          the first action-menu line of a new game (2026-08-16, owner).
#          Raising it to 3 only moves the failure to the no-save path.
#
#   used   the count was a proxy for the real question, which is whether the
#          cache holds anything worth clearing.  copy_record raises a flag the
#          first time it fills the cache; the stub wipes only when the flag is
#          up and lowers it again.  Boot preloads but draws no Hangul, so the
#          flag is down and nothing is wiped, whatever route the title took.
#          Costs less than the counter it replaces.
#   header the same question as "used", asked of the cache itself so no state is
#          kept at all.  $5B80 holds $FF exactly when there is no record --
#          §0.2 measured the original's BIOS CD read leaving it $FF at reload
#          time, and the wipe writes $FF itself, so the byte is already the
#          answer.  It also sits in MPR2, outside the $7FC0-$7FFF range the BIOS
#          CD read overwrites; "used" keeps its flag inside that range, where
#          the far likelier failure is the flag being *cleared* before a return
#          title, which silently restores the original save->title->load bug.
#   magic  the one measurement chose.  Every record carries "SDR4" in its
#          first four bytes and nothing else in the cache does, so the stub
#          asks "is this ours?" directly -- no state, no spawn counting, no
#          assumption about the cache starting out empty.
TITLE_WIPE_GATE = os.environ.get("SNATCHER_TITLE_WIPE_GATE", "count")
#   restore  put the buffer back to the idle state the game itself keeps there
#            (IDLE_CACHE) instead of blanking it to $FF.  The value is the
#            same in every state that matters, so the stub needs no gate at
#            all -- the three above were each a way of deciding when it was
#            safe to write the *wrong* value.
if TITLE_WIPE_GATE not in ("count", "used", "header", "magic", "restore"):
    raise SystemExit(
        f"SNATCHER_TITLE_WIPE_GATE={TITLE_WIPE_GATE!r} is not "
        "'count', 'used', 'header', 'magic' or 'restore'")
TITLE_WIPE = os.environ.get("SNATCHER_TITLE_WIPE", "0") == "1"
TITLE_WIPE_BYTES = int(os.environ.get("SNATCHER_TITLE_WIPE_BYTES", "64"))
TITLE_WIPE_SKIP = int(os.environ.get("SNATCHER_TITLE_WIPE_SKIP", "2"))
if not 1 <= TITLE_WIPE_BYTES <= 256:
    raise SystemExit(f"SNATCHER_TITLE_WIPE_BYTES={TITLE_WIPE_BYTES} is not 1-256")
if not 0 <= TITLE_WIPE_SKIP <= 255:
    raise SystemExit(f"SNATCHER_TITLE_WIPE_SKIP={TITLE_WIPE_SKIP} is not 0-255")
SPAWN_HANDLER = 0x73BD        # the scene VM's own opcode-2 handler
TITLE_SPAWN_HIGH = 0x95       # ($FA),Y+$0A on a title spawn
WINDOW_SHIFT = 0x4000         # cave $A000-window address -> the $6000 window
CACHE_USED_MAGIC = 0x5A       # "copy_record filled the cache", gate="used"
# build_direct_overlay_layout.MAGIC -- stamped into payload[0:4] of every
# record, which is what lets gate="magic" recognise its own work.
RECORD_MAGIC = b"SDR4"

# Glyph fills: write only the AC base, not the port's control registers.
#
# set_ac writes six registers -- base $1A02-$1A04, then $1A07=1, $1A08=0,
# $1A09=$11.  In the glyph loop only the base changes; the other three carry the
# same value every iteration.  If the port keeps its mode once configured, the
# three writes and the JSR/RTS around them are ~33 cycles per glyph spent on
# nothing: 0.87 scanline on a 12-glyph record.
#
# Whether the port does keep it is not documented anywhere in this project, and
# guessing wrong reads the wrong bytes rather than failing loudly.  So this is a
# question, not a decision: build with SNATCHER_AC_FAST=1 and look at the text.
# Correct glyphs mean the control writes were redundant.
AC_FAST = os.environ.get("SNATCHER_AC_FAST", "0") == "1"

# ---- 진단 전용: 레코드 재구성이 끝난 뒤 렌더로 돌아가기 전에 일부러 멈춘다 ----
#
# 최적화가 아니다.  **모형을 깨보려고** 넣는다 (소유자 지시, 2026-08-18).
#
# SNATCHER_FLICKER_ELIMINATION_2026-08-15 §0 의 모형은 이렇다:
#
#     게임이 스캔라인 32·42·54·64... 마다 스크롤을 갈아끼운다 (Event Viewer 실측)
#     우리가 레코드 하나에 CPU 를 12.3 스캔라인 점유한다
#     겹치면 갱신이 한 줄 늦게 들어가고 경계가 밀린다
#
# 그 모형이 맞다면 여기서 더 기다리는 것은 **점유를 늘리는 것**이므로 밀림이
# 심해져야 한다.  줄거나 그대로면 모형이 틀린 것이다.  세 결과가 다 정보다.
#
# 단위: 바깥 루프 1 회 = 256 x (DEX 2 + BNE 4) ~= 1,536 cycle ~= 3.4 스캔라인.
#
#     0    조립하지 않는다 (정식 빌드는 바이트가 그대로다)
#     4    ~14 라인   -- 우리 점유와 같은 규모
#     36   ~123 라인  -- 화면 절반.  "누가 봐도 과할 정도"
#     72   ~246 라인  -- 거의 한 프레임
# 값을 바꿀 때마다 굽지 않는다.  SNATCHER_RENDER_DELAY_SLOT=1 로 한 번 구우면
# 지연 루프가 들어가되 초기값은 0(=건너뜀)이고, 횟수 바이트를 Lua 가 실시간으로
# 덮어쓴다.  주소는 helper_symbols.json 의 `render_delay_set` + 1.
RENDER_DELAY_SLOT = os.environ.get("SNATCHER_RENDER_DELAY_SLOT", "0") == "1"
RENDER_DELAY = int(os.environ.get("SNATCHER_RENDER_DELAY", "0"))
if not 0 <= RENDER_DELAY <= 255:
    raise SystemExit("SNATCHER_RENDER_DELAY 은 0~255 (바깥 루프 횟수)")
if RENDER_DELAY and not RENDER_DELAY_SLOT:
    raise SystemExit("SNATCHER_RENDER_DELAY 은 SNATCHER_RENDER_DELAY_SLOT=1 과 같이 쓴다")

TEMPLATE_CHUNK = int(os.environ.get("SNATCHER_TAI_CHUNK", "76"))
if TEMPLATE_BYTES % TEMPLATE_CHUNK:
    raise SystemExit(
        f"SNATCHER_TAI_CHUNK={TEMPLATE_CHUNK} does not divide the "
        f"{TEMPLATE_BYTES}-byte template")

# copy_record has four block transfers, and SNATCHER_TAI_CHUNK only ever split
# the first one.  The 96-byte text copy blocks 17 + 6*96 = 593 cycles = 1.30
# scanlines and was never touched, so shrinking the template to 16 B (0.27
# lines) left the *real* worst-case blocking unchanged at 1.30 lines.
#
# That invalidates the 2026-08-15 conclusion that "interrupt blocking is not the
# cause": the experiment shrank a transfer that was no longer the largest one.
# SNATCHER_TEXT_CHUNK splits this one too so the hypothesis can be tested for
# real.  Default 96 keeps every existing build byte-identical.
TEXT_CHUNK = int(os.environ.get("SNATCHER_TEXT_CHUNK", str(TEXT_SPAN)))
if TEXT_SPAN % TEXT_CHUNK:
    raise SystemExit(
        f"SNATCHER_TEXT_CHUNK={TEXT_CHUNK} does not divide the "
        f"{TEXT_SPAN}-byte text span")
HELPER_SLOT = SLOT_COUNT_PER_RECORD - 1                # 18
CONST_SLOTS = 3                                        # period / blank / ellipsis
GLYPH_SLOTS = HELPER_SLOT - CONST_SLOTS                # 15

# Helper scratch: the 14 working variables plus the bounded-blank state
# (TPL_LO/TPL_HI/FILLED).  It lives in the last $20 bytes of the cave.
SCRATCH_BYTES = 17
if TITLE_WIPE and TITLE_WIPE_GATE == "used":
    # One more variable, CACHE_USED.  It comes out of the slack already reserved
    # inside the $20 scratch block, so the block does not move -- that is the
    # part that must not change (see build_helper_compact).
    SCRATCH_BYTES += 1

CACHE_BASE = 0x5B80
FONT_CACHE = CACHE_BASE + TEXT_SPAN                    # $5BE0
INDEX_SCRATCH = FONT_CACHE + CONST_SLOTS * GLYPH_BYTES  # $5C40, glyph slot 3
GLYPH_DST_LAST = INDEX_SCRATCH + (GLYPH_SLOTS - 1) * GLYPH_BYTES  # $5E00

if BIOS_FONT:
    # 아틀라스 오프셋 15 개(30 B)를 실을 이유가 없다.  96 B 면 충분하다.
    COMPACT_BYTES = TEXT_SPAN

USER_BYTES = 2048
CHUNK_BYTES = 0x2000
DIRECTORY_BYTES = 0x4000 * 4

# ---- 컷신 자막 예약 구역 (2026-08-19) ----
#
# 자막은 아직 한 바이트도 없지만 자리는 지금 잡는다.  씬 팩은 scene_base 에서
# 위로 자라고 그 천장이 AC_BYTES 였으므로, 아무 것도 안 하면 다음에 팩이 늘어날
# 때 자막이 쓸 곳을 조용히 먹는다.  구역을 AC 꼭대기에 두고 씬 팩의 천장을
# 그 바닥으로 낮추면, 침범이 "언젠가 이상해진다" 가 아니라 빌드 실패가 된다.
#
# 왜 꼭대기인가: 초기 적재와 상주 팩은 아래에서 위로, 씬 팩도 아래에서 위로
# 자란다.  꼭대기는 커서가 하나(scene_cursor)만 접근하는 유일한 자리라 감사가
# 한 줄로 끝난다.
#
# 크기 근거 (2026-08-19 실측, snatcher_ko_master.tsv 2,279 행):
#   전체 고유 음절 761 자 -> 외곽선까지 구운 2플레인 글리프 761 x 64 B = 48 KB
#   씬별 스크립트 20 개 x 1.7 KB                                    = 34 KB
#   씬별 로컬 인덱스표 20 x 512 B                                   = 10 KB
#   엔진 코드 이미지 (AC 에 저장, 컷신 진입 때 RAM 으로 복사)        =  2 KB
#   ------------------------------------------------------------------
#   추정 94 KB.  2.7 배로 잡아 256 KB.
#
# 과예약 비용은 0 이다.  AC 2 MB 중 현재 쓰는 것은 340 KB 뿐이고, 이 구역을
# 떼도 씬 구역에 1.37 MB 가 남는다 (지금 씬 팩 사용량은 0).  반대로 과소예약은
# 이 상수를 넣는 이유 그 자체다.  숫자를 바꾸려면 아래 한 줄만 고치면 된다.
#
# 지금 이 변경은 **이미지를 한 바이트도 바꾸지 않는다.**  건드리는 것은 씬 팩의
# 용량 검사와 extent 감사뿐이고, 둘 다 방출되는 바이트가 아니다.
# 컷신 자막이 쓸 RAM.  실측 2026-08-19 (PROBE_DEAD_RAM_0.1.1, CD_PLAY 게이트).
#
#   $5C40-$5E1F   480 B   MPR2.  BIOS 전환으로 죽은 글리프 슬롯 3-17.
#                         우리 자리라 게임과 무관하고, 아래 감사가 그것을 지킨다
#   $2311-$2637   807 B   MPR1.  컷신 중 미사용 (베이스 RAM 은 코드가 안 돈다)
#   $3468-$36FF   664 B   MPR1
#
# **$4000-$5FFF 전체가 "쓰기 없음" 으로 나오지만 거기는 코드다.**  프레임 끝 PC 의
# 4.5% 가 그 창이고 $43B2 · $43BC 가 그 예다.  쓰기가 없다는 것은 빈 자리라는 뜻이
# 아니다 -- 이 프로젝트가 $5B80 · $BFCF · $7FF1 에서 세 번 데인 함정이다.
# 컷신 자막 POC.  켜면 엔진·패턴·SAT 을 초기 적재 블록의 패딩에 얹는다.
# 부팅 때 이미 AC 로 옮겨지는 구간이라 적재 경로를 새로 만들 필요가 없다.
# **$1C0000 예약 구역은 부팅 때 안 실린다** -- 본 엔진의 94 KB 는 거기에 제대로 된
# 적재 경로를 만들어야 하고, 이 지름길을 그대로 확장하면 안 된다 (패딩은 아틀라스가
# 되살아나면 사라진다).
SUBS_POC = os.environ.get("SNATCHER_SUBS_POC", "0").strip() == "1"
if SUBS_POC:
    raise SystemExit(
        "SNATCHER_SUBS_POC 는 지금 켤 수 없다.\n"
        "  자막 엔진 자리로 잡았던 $5C40-$5E1F 가 **게임 스크립트 VM 의 데이터\n"
        "  스택** 한복판임이 2026-08-20 에 밝혀졌다 ($5B80-$5E3F, 704 B).\n"
        "  켜고 빌드하면 스택을 밟아 게임이 죽는다.\n"
        "  PROBE_ARENA_0.1.3 으로 스택 최대 깊이를 재고 새 자리를 정한 뒤\n"
        "  SUBTITLE_RAM_CODE 와 함께 다시 연다.  "
        "SNATCHER_ARENA_2026-08-20 §4 참조.")
SUBS_POC_AC = 0x011000
SUBS_POC_FILES = ("poc_engine.bin", "poc_patterns.bin", "poc_sat.bin")
SUBS_VEC_IRQ1 = 0x2202          # BIOS RAM 벡터.  IRQ1(VDC) -- 2 바이트 엔트리
SUBS_POC_BLOCKS: list[tuple[int, int]] = []   # (목적지, 길이).  적재물을 읽고 채운다
SUBS_POC_SIGNATURE: bytes = b""               # 엔진 첫 바이트들.  적재 검증용


def _subs_poc_payload() -> bytes:
    """POC 적재물 세 덩어리.  AC 에서 연속이므로 베이스를 한 번만 세운다."""
    global SUBS_POC_BLOCKS
    # **엔진만 RAM 으로 간다.**  패턴·SAT 은 엔진이 AC 에서 직접 끌어와
    # 자기 480 B 안의 창을 거쳐 VRAM 으로 보낸다.  게임 RAM 은 한 바이트도 안 쓴다
    # (2026-08-19 실측: $2311 에 576 B 를 썼더니 약 1,000 프레임 뒤 게임이 멈췄다 --
    #  그 자리는 오프닝 중에만 죽은 자리였다).
    dests = (SUBTITLE_RAM_CODE[0], None, None)         # 엔진 · (패턴) · (SAT)
    blobs = [(ROOT / "build" / "cutscene_subs" / n).read_bytes() for n in SUBS_POC_FILES]
    global SUBS_POC_SIGNATURE
    SUBS_POC_BLOCKS = [(d, len(b)) for d, b in zip(dests, blobs) if d is not None]
    SUBS_POC_SIGNATURE = blobs[0][:2]              # PHA, INC -- 엔진 진입 두 바이트
    return b"".join(blobs)

# ============================================================================
# ★ 무효 (2026-08-20).  아래 두 상수는 **쓸 수 없는 자리**를 가리킨다.
#
# 2026-08-19 에 PROBE_DEAD_RAM_0.1.1 이 "오프닝 중 $5C40-$5E1F 480 B 가 한 번도
# 안 쓰인다" 고 보고했고 그것을 자막 엔진 자리로 잡았다.  **틀렸다.**
#
# 그 다음 밤에 조이 디비전 「쇼핑하기」 크래시를 파다가 정체가 밝혀졌다:
# **$5B80-$5E3F 는 게임 스크립트 VM 의 데이터 스택**이다 ($4880 이 바닥을 깔고
# 위로 자란다).  오프닝 컷신에서는 스크립트 중첩이 얕아 거기까지 안 올라왔을 뿐이다.
#
#     스택        $5B80-$5E3F   704 B   (arena_floor 패치 후)
#     자막 예약   $5C40-$5E1F   480 B
#     겹침                      480 B = 예약의 100%
#     쇼핑 화면 실측 깊이 579 B -> $5DC3 까지.  엔진 한복판을 밟는다
#
# 버퍼로 잡았던 $2311/$3468 도 같은 이유로 무효다 -- 오프닝 중에만 죽은 자리였고,
# 실제로 2026-08-19 시험에서 일반 플레이 중 게임을 멈추게 했다.
#
# 규칙 (SNATCHER_ARENA_2026-08-20 §7): **Write 를 못 봤다 != 안전.**
# Write 를 봤으면 그 자리를 쓰는 루틴을 찾아 범위를 계산해야 한다.
#
# 자막 엔진의 새 자리는 스택 최대 깊이 실측(PROBE_ARENA_0.1.3)이 끝나야 정해진다.
# 704 B 를 넘는 화면이 있으면 프리로더도 옮겨야 하므로 두 문제가 하나다.
# ============================================================================
SUBTITLE_RAM_CODE = (0x5C40, 0x5E1F)          # ★ 무효 -- 위 주석 참조
SUBTITLE_RAM_BUFFERS = ((0x2311, 0x2637),     # 807 B, 패턴 버퍼
                        (0x3468, 0x36FF))     # 664 B, SAT 버퍼

# 2026-09-02: 256 KB -> 640 KB.  팩이 192 KB 중 188 KB(95%)까지 찼다.
# 대사 이미지는 0x132880 에서 끝나므로 base $160000 까지 내려도 186 KB 남는다
# (넘치면 build_snatcher_ko_0_4_5_9 의 TRANSLATION_LIMIT 검사가 먼저 죽는다).
SUBTITLE_AC_BYTES = 0xA0000
SUBTITLE_AC_BASE = dynamic.AC_BYTES - SUBTITLE_AC_BYTES
# 매니페스트를 쓰는 것은 0_1_5 이므로 거기서 읽을 수 있게 올려둔다.
dynamic.SUBTITLE_AC_BYTES = SUBTITLE_AC_BYTES
dynamic.SUBTITLE_RAM_CODE_TEXT = f"{SUBTITLE_RAM_CODE[0]:04X}-{SUBTITLE_RAM_CODE[1]:04X}"
dynamic.SUBTITLE_RAM_CODE_BYTES = SUBTITLE_RAM_CODE[1] - SUBTITLE_RAM_CODE[0] + 1
dynamic.SUBTITLE_RAM_BUFFERS_TEXT = [f"{a:04X}-{b:04X}" for a, b in SUBTITLE_RAM_BUFFERS]
dynamic.SUBTITLE_AC_BASE = SUBTITLE_AC_BASE

STATE_AC = 0x10000
# Reachable through set_state_address, which takes a single byte offset, so the
# whole table has to live inside the 256-byte state page and the helper's
# "CLC; ADC #offset" caps the pack count at (256 - offset) / 8.  It sat at $80,
# which allowed 16 packs; the 2026-08-14 master crossed that at 25.  Moving it
# down to $20 -- just above the magic word and the per-pack loaded flags --
# raises the ceiling to 28 without touching the addressing.
#
# Past 28 packs this needs real work, not another constant: either 16-bit
# addressing in the helper or the separate metadata region the 2026-08-12
# handoff describes.  The flags below grow with the pack count too, so
# build_packs_compact asserts they stay clear of this offset.
METADATA_AC_OFFSET = 0x20
STATE_SPAN = 0x100
# --- the idle cache image, and the AC layout it shifts ---
# The cache as the game itself keeps it when no record is loaded.
#
# Measured 2026-08-16 with lua\PROBE 1.0.1.lua, seven samples: the unpatched
# Japanese disc and 0.3.8.5, with a BRAM save and without, at the title and
# again after a load.  All 64 bytes identical every time -- this is not a
# record, it is the buffer's idle state.
#
# That is what the stub has to put back.  $FF means "no record", which is close
# enough that a *load* refills correctly, but it is not what the game leaves
# there, and starting a NEW GAME after a wipe drew garbage on the first action
# menu line because of the difference (2026-08-16, owner).
#
# Because the value is the same in every state, restoring it needs no test:
# at a boot title the cache already holds it and the write is a no-op, and at a
# return title it replaces our stale record.  That is why the stub carries no
# gate -- see TITLE_WIPE_GATE="restore".
IDLE_CACHE = bytes.fromhex(
    "82FFFF013E0000 82FFFF5E 82FFFF5E 82"
    "FFFF013E0000 82FFFF5E 82FFFF5E 82FF"
    "FF013F0000 0208FF 00016F000010 FF01"
    "700000 FFFFFFFFFFFFFFFFFFFFFFFFFF".replace(" ", ""))
assert len(IDLE_CACHE) == 64, len(IDLE_CACHE)
# 256-aligned so the stub can STZ the AC low byte instead of loading it.
IDLE_SPAN = len(IDLE_CACHE) if (TITLE_WIPE and TITLE_WIPE_GATE == "restore") else 0
# It goes in its own 256-byte page directly above the state page, ahead of the
# template.  That is not cosmetic: at $10100 the address's low byte is zero and
# its middle and high bytes are both $01, so the stub can STZ one AC register
# and load $01 once for three more.  Placed after the template instead, the same
# setup costs four bytes the cave does not have.
IDLE_AC = STATE_AC + STATE_SPAN                        # $10100
IDLE_PAGE = 0x100 if IDLE_SPAN else 0
TEMPLATE_AC = STATE_AC + STATE_SPAN + IDLE_PAGE        # $10100, or $10200
ATLAS_AC = TEMPLATE_AC + TEMPLATE_BYTES
# Any 32 zero bytes will do as a blank glyph source; the template's slot 3 is
# the nearest one and is guaranteed zero (compact_and_atlas only writes the
# const slots and slot 18 into it).
BLANK_AC = TEMPLATE_AC + CONST_SLOTS * GLYPH_BYTES

METADATA_STRIDE = 8

# Optional throwaway probe used by ac_0.1.17-portpoc.  When False the emitted
# helper is byte-identical to the shipped ac_0.1.14.
PORT_POC = False
POC_PORT0_AC = 0x180000
POC_PORT1_AC = 0x180200
POC_LENGTH = 16


def _slot_view(payload: bytes, slot: int) -> bytes:
    start = TEXT_SPAN + slot * GLYPH_BYTES
    return payload[start:start + GLYPH_BYTES]


def compact_and_atlas(
    records: dict[int, bytes],
) -> tuple[dict[int, bytes], bytes, bytes, list[bytes]]:
    """Return compact records, the 608-byte template, the atlas, and its glyphs."""
    ordered = [records[slot] for slot in sorted(records)]
    blank = bytes(GLYPH_BYTES)

    constants = [_slot_view(ordered[0], slot) for slot in range(CONST_SLOTS)]
    helper_glyph = _slot_view(ordered[0], HELPER_SLOT)
    for payload in ordered:
        for slot in range(CONST_SLOTS):
            if _slot_view(payload, slot) != constants[slot]:
                raise RuntimeError(f"glyph slot {slot} is not constant across records")
        if _slot_view(payload, HELPER_SLOT) != helper_glyph:
            raise RuntimeError("glyph slot 18 (fractional-space helper) is not constant")

    atlas_index: dict[bytes, int] = {}
    atlas_order: list[bytes] = []
    compact: dict[int, bytes] = {}
    for slot, payload in records.items():
        used = [_slot_view(payload, index) for index in
                range(CONST_SLOTS, HELPER_SLOT)]
        while used and used[-1] == blank:
            used.pop()
        if blank in used:
            raise RuntimeError(f"slot {slot:04X} has a gap in its glyph run")
        if len(used) > GLYPH_SLOTS:
            raise RuntimeError(f"slot {slot:04X} needs {len(used)} glyphs (>{GLYPH_SLOTS})")
        entry = bytearray(COMPACT_BYTES)
        entry[0:TEXT_SPAN] = payload[0:TEXT_SPAN]
        if BIOS_FONT:
            # 스테이지 1 이 한글을 안 구웠으면 쓸 글리프가 있을 수 없다.
            # 있다면 스위치가 한쪽에만 걸린 것이므로 조용히 넘기지 않는다.
            if used:
                raise RuntimeError(
                    f"SNATCHER_KO_BIOS 인데 슬롯 {slot:04X} 에 글리프가 {len(used)} 개 있다 -- "
                    "스테이지 1 이 BIOS 모드로 안 돌았다")
            compact[slot] = bytes(entry)
            continue
        for position in range(GLYPH_SLOTS):
            if position < len(used):
                glyph = used[position]
                if glyph not in atlas_index:
                    atlas_index[glyph] = len(atlas_order)
                    atlas_order.append(glyph)
                # Store the 16-bit AC word offset so the helper needs no
                # multiply: ATLAS_AC's low 16 bits plus index * 32 never carries
                # out of 16 bits for any atlas this size.
                word = (ATLAS_AC + atlas_index[glyph] * GLYPH_BYTES) & 0xFFFF
                if word >> 8 == 0xFF:
                    raise RuntimeError("atlas offset collides with the $FFFF sentinel")
            else:
                word = 0xFFFF
            entry[TEXT_SPAN + position * 2] = word & 0xFF
            entry[TEXT_SPAN + position * 2 + 1] = word >> 8
        compact[slot] = bytes(entry)

    atlas = b"".join(atlas_order)
    if (ATLAS_AC & 0xFFFF) + len(atlas) > 0xFF00:
        raise RuntimeError("atlas crosses the 16-bit window the helper assumes")

    template = bytearray(TEMPLATE_BYTES)
    for slot in range(CONST_SLOTS):
        template[slot * GLYPH_BYTES:(slot + 1) * GLYPH_BYTES] = constants[slot]
    template[HELPER_SLOT * GLYPH_BYTES:] = helper_glyph

    return compact, bytes(template), atlas, atlas_order


def verify_reassembly(
    records: dict[int, bytes],
    compact: dict[int, bytes],
    template: bytes,
    atlas_order: list[bytes],
) -> None:
    """Reproduce the helper's expansion in Python and demand byte equality."""
    base = ATLAS_AC & 0xFFFF
    for slot, original in records.items():
        rebuilt = bytearray(RECORD_BYTES)
        entry = compact[slot]
        rebuilt[0:TEXT_SPAN] = entry[0:TEXT_SPAN]
        rebuilt[TEXT_SPAN:] = template
        # BIOS 판: 압축본은 텍스트뿐이고 헬퍼도 템플릿까지만 놓는다.
        # 그러니 검산도 거기서 끝나야 한다 -- 원본 레코드의 폰트 영역이 상수
        # 3 칸 + 반칸 도우미뿐이라는 것을 이 비교가 그대로 증명한다.
        for position in range(0 if BIOS_FONT else GLYPH_SLOTS):
            word = entry[TEXT_SPAN + position * 2] | (entry[TEXT_SPAN + position * 2 + 1] << 8)
            if word == 0xFFFF:
                continue
            glyph = atlas_order[(word - base) // GLYPH_BYTES]
            start = TEXT_SPAN + (CONST_SLOTS + position) * GLYPH_BYTES
            rebuilt[start:start + GLYPH_BYTES] = glyph
        if bytes(rebuilt) != original:
            offsets = [i for i in range(RECORD_BYTES) if rebuilt[i] != original[i]]
            raise RuntimeError(
                f"slot {slot:04X} reassembly differs at {offsets[:12]}"
            )


def build_packs_compact() -> tuple[bytes, list[dict[str, object]], bytes, int]:
    rows, records = dynamic.read_records()
    compact, template, atlas, atlas_order = compact_and_atlas(records)
    verify_reassembly(records, compact, template, atlas_order)

    # Diagnostic only -- docs\handoff\SNATCHER_SAVELOAD_HANDOFF_2026-08-15.md.
    #
    # After save->title->load the game walks this buffer and reads slot 18's
    # first byte as a transfer length: it copies $5E20/$5E21 into zero page
    # $2001/$2002, points $12/$13 at $5E22, and copies that many bytes into VRAM
    # pattern memory.  Our helper starts with $A5 (LDA), so the length reads as
    # 165 and the copy runs to $5EC6 -- past the cache, through the $5E40
    # preloader -- painting our code onto ~10 tiles.  Vanilla measured $10 (16)
    # there, ending at $5E32, safely inside the cache.
    #
    # A value <= $1D keeps the copy inside the cache.  This BREAKS the
    # fractional-space helper (the byte is executed), so it is a mechanism test,
    # not a fix.  It is applied after verify_reassembly on purpose: the rebuild
    # must still be byte-exact against the real records, and this deliberately
    # is not -- the check caught it at offset 672 when it ran first.
    probe_byte = os.environ.get("SNATCHER_SLOT18_FIRST")
    if probe_byte is not None:
        value = int(probe_byte, 0)
        if not 0 <= value <= 0xFF:
            raise SystemExit(f"SNATCHER_SLOT18_FIRST={probe_byte} is not a byte")
        patched = bytearray(template)
        patched[HELPER_SLOT * GLYPH_BYTES] = value
        template = bytes(patched)
        print(f"  *** DIAGNOSTIC: slot 18 first byte -> ${value:02X} "
              f"(fractional space is broken in this build) ***")

    # Diagnostic only -- the other half of the same investigation.
    #
    # Before reading slot 18 the game walks *down* through slot 17, stepping
    # $5E01 -> $04 -> $07 -> $0A -> $10 -> $19 and only then landing on $5E22
    # (PROBE 0.4.0, 2026-08-15).  Slot 17 is all zeros in our template, and a
    # run of zeros lets that walk slide straight through.  The vanilla dump had
    # $FF across the whole area at the same moment.
    #
    # So: does a non-zero slot 17 stop the walk before it ever reaches the
    # helper?  Filling only slot 17 keeps the blast radius small -- slots 3..16
    # stay zero, so the trailing-blank references described in the 08-14 handoff
    # (§4.7) still render as blanks.  Slot 17 is the last local slot and only 5
    # of 3,137 records use all 15, so it is almost always unused; when a record
    # does use it, copy_record overwrites this fill with the real glyph.
    slot17 = os.environ.get("SNATCHER_SLOT17_FILL")
    if slot17 is not None:
        value = int(slot17, 0)
        if not 0 <= value <= 0xFF:
            raise SystemExit(f"SNATCHER_SLOT17_FILL={slot17} is not a byte")
        patched = bytearray(template)
        start = (HELPER_SLOT - 1) * GLYPH_BYTES
        patched[start:start + GLYPH_BYTES] = bytes([value]) * GLYPH_BYTES
        template = bytes(patched)
        print(f"  *** DIAGNOSTIC: slot 17 filled with ${value:02X} ***")

    grouped: OrderedDict[str, list[int]] = OrderedDict()
    for resident_name in dynamic.RESIDENT_PACK_NAMES:
        grouped[resident_name] = []
    for row in rows:
        grouped.setdefault(dynamic.classify(row), []).append(int(row["final_slot"], 16))
    if dynamic.COALESCE_SMALL_SCENES_MAX_RECORDS:
        target = dynamic.COALESCE_SMALL_SCENES_TARGET
        grouped.setdefault(target, [])
        small = [name for name, slots in grouped.items()
                 if name.startswith("scene_")
                 and len(slots) <= dynamic.COALESCE_SMALL_SCENES_MAX_RECORDS]
        for name in small:
            grouped[target].extend(grouped.pop(name))
    grouped = OrderedDict((name, slots) for name, slots in grouped.items() if slots)
    if len(grouped) > 31:
        raise RuntimeError(f"pack count {len(grouped)} exceeds the compact runtime limit 31")

    # Two different questions wear the word "resident" here, and conflating them
    # is a trap: RESIDENT_PACK_NAMES chooses the *destination region*, while the
    # preload set chooses *what the init read covers*.  Settle the preload set
    # first, against the real resident list, before the layout override below
    # rewrites that list to mean "everything".
    truly_resident = [name for name in grouped
                      if name in dynamic.RESIDENT_PACK_NAMES]
    build_packs_compact.preload_pack_count = (
        len(grouped) if PRELOAD_MODE == "all"
        else len(truly_resident) if PRELOAD_MODE == "resident"
        else 0)

    # Preloading needs every pack packed contiguously from common_base, because
    # the init read is one straight run and scene packs otherwise start at a
    # 64 KiB-aligned scene_base with a hole in front of them.  Marking them all
    # resident is exactly that: "resident" only ever chose the destination
    # region, never whether a pack was loaded up front.  PRELOAD_MODE
    # "resident" needs the same contiguity: it stops the read early, and a hole
    # in front of the scene packs would put their AC addresses out of step with
    # their disc offsets for the demand loads that follow.
    if PRELOAD_PACKS:
        dynamic.RESIDENT_PACK_NAMES = tuple(grouped)

    align = dynamic.align

    # The initial load's size is fixed by the atlas, so resolve it first: the
    # resident packs have to start after whatever it covers.
    init_total = align(DIRECTORY_BYTES + STATE_SPAN + TEMPLATE_BYTES + len(atlas),
                       CHUNK_BYTES)
    init_extra_bytes = init_total - DIRECTORY_BYTES
    build_packs_compact.init_chunks = init_total // CHUNK_BYTES
    build_packs_compact.init_extra_bytes = init_extra_bytes

    # $16000 used to be a bare constant that never consulted the atlas, so a
    # bigger atlas ran straight into the resident packs.  The packs transfer
    # *after* the init run, so they overwrote the atlas tail and every glyph
    # past ($16000 - ATLAS_AC) / 32 = 741 rendered as record bytes.  0.3.0's
    # 1,089-glyph atlas ended at $18B80 and destroyed 348 of them; the init
    # run is MAGIC-guarded, so nothing repaired it until a power cycle.
    # Deriving the floor from init_total makes that unrepresentable.  max()
    # keeps the historical base whenever the atlas fits under it, so
    # ac_0.1.14 still rebuilds byte-exact.
    common_base = max(dynamic.COMMON_DATA_BASE, init_total)
    dynamic.COMMON_DATA_BASE = common_base   # so the manifest reports the truth

    # ...and when max() picks the floor instead, the init run has to grow to
    # meet it.  §127 states the invariant this file rests on: the blob's disc
    # offset is init_total and its AC address is common_base, so the two must
    # be the same number.  The floor was only ever the "atlas is too big" side
    # of that; nothing covered the atlas being *smaller*, because until the
    # BIOS font path there was always an atlas.
    #
    # 2026-08-18: the BIOS path retired the atlas (0 glyphs, 0 bytes).
    # init_total fell to $12000 for the first time, the floor won, and every
    # record address in the directory pointed $4000 past its data.  copy_record
    # read zeros, the cache magic check at $5F3B failed, and the preloader
    # handed the renderer back the Japanese source -- measured as 33 slots
    # loaded, cache "00 00 00 00", 0 signature checks, 35 search_failed.
    # 0.3.11-bios still worked because its 1,115-glyph atlas put init_total at
    # $1A000; the regression arrived with the -opt build that dropped it.
    #
    # Padding the init run keeps ac_0.1.14/0.3.9 byte-exact (there init_total
    # already wins the max) and costs AC space we are not short of.
    if init_total < common_base:
        init_total = align(common_base, CHUNK_BYTES)
        init_extra_bytes = init_total - DIRECTORY_BYTES
        build_packs_compact.init_chunks = init_total // CHUNK_BYTES
        build_packs_compact.init_extra_bytes = init_extra_bytes
        # A floor that is not chunk-aligned would round init_total back up past
        # it and reopen the same gap the other way.  Close it by definition.
        common_base = init_total
        dynamic.COMMON_DATA_BASE = common_base
    assert init_total == common_base, (
        f"blob disc offset ${init_total:05X} != AC base ${common_base:05X}")

    resident_end = align(common_base, USER_BYTES)
    for name in dynamic.RESIDENT_PACK_NAMES:
        if name in grouped:
            resident_end = align(
                resident_end + len(grouped[name]) * COMPACT_BYTES, USER_BYTES)
    scene_base = align(resident_end, 0x10000)
    if scene_base >= dynamic.AC_BYTES:
        raise RuntimeError("resident packs leave no scene region")

    directory = bytearray(b"\xFF" * DIRECTORY_BYTES)
    blob = bytearray()
    packages: list[dict[str, object]] = []
    cursor = align(common_base, USER_BYTES)
    # Scene packs used to all land on scene_base, one slot, overlaying each
    # other.  Measured 2026-08-14: scene_111800 was re-read from CD seven times
    # and scene_10F800 five times in one session, alternating, because a menu
    # and its dialogue live in different packs -- so reopening the same menu
    # paid a full CD load every time.  They total 102 KB against a 1.7 MB scene
    # region, so the overlay bought nothing.  Give each its own address and it
    # loads once.
    scene_cursor = scene_base
    for pack_id, (name, slots) in enumerate(grouped.items()):
        data = b"".join(compact[slot] for slot in slots)
        resident = name in dynamic.RESIDENT_PACK_NAMES
        transferred = align(len(data), USER_BYTES)
        capacity = ((scene_base - cursor) if resident
                    else (SUBTITLE_AC_BASE - scene_cursor))
        if transferred > capacity:
            raise RuntimeError(f"{name} needs {transferred} B but its region holds {capacity}")
        destination = cursor if resident else scene_cursor
        for offset, slot in enumerate(slots):
            entry = slot * 4
            address = destination + offset * COMPACT_BYTES
            directory[entry:entry + 3] = address.to_bytes(3, "little")
            directory[entry + 3] = pack_id
        blob.extend(bytes((-len(blob)) % USER_BYTES))
        packages.append({
            "id": pack_id, "name": name, "record_count": len(slots),
            "bytes": len(data), "transferred_bytes": transferred,
            "blob_offset": len(blob), "destination": destination,
            "resident": resident,
        })
        blob.extend(data)
        if resident:
            cursor = align(cursor + len(data), USER_BYTES)
        else:
            scene_cursor = align(scene_cursor + len(data), USER_BYTES)

    # Fatal AC extent audit.  byte_exact_verified only says the compact records
    # reassemble into their 704-byte originals; it says nothing about where they
    # land in AC, which is how 0.3.0 shipped a build that passed every existing
    # check and still corrupted 348 glyphs.  Compare *transferred* extents,
    # padding included: the init run pads to a whole 8 KiB chunk, and that
    # padding is what actually reached $16000.  Scene packs deliberately share
    # scene_base (only one is resident at a time), so only the init run, the
    # resident packs and the scene floor take part.
    extents = [("initial load", 0, init_total)]
    extents += [(str(p["name"]), int(p["destination"]),
                 int(p["destination"]) + int(p["transferred_bytes"]))
                for p in packages if p["resident"]]
    extents.append(("scene region", scene_base, SUBTITLE_AC_BASE))
    # Reserved, empty, and audited anyway: the point is that the day a scene
    # pack grows into it the build stops here instead of shipping.
    extents.append(("subtitle reserve", SUBTITLE_AC_BASE, dynamic.AC_BYTES))
    extents.sort(key=lambda item: item[1])
    for (lo_name, _, lo_end), (hi_name, hi_start, _) in zip(extents, extents[1:]):
        if lo_end > hi_start:
            raise RuntimeError(
                f"AC extent overlap: {lo_name} ends at ${lo_end:05X} but "
                f"{hi_name} starts at ${hi_start:05X} "
                f"({lo_end - hi_start} bytes).  Resident packs transfer after "
                f"the initial load, so this silently overwrites whatever "
                f"loaded first -- for the atlas that means every glyph from "
                f"index {(hi_start - ATLAS_AC) // GLYPH_BYTES} onwards.")

    # The initial CD load is one contiguous run from AC $00000 covering the
    # directory, the state page, the template and the atlas.  Padding it to a
    # whole number of 8 KiB chunks keeps FINAL_LO zero for that load, so the
    # init path needs no final-chunk handling at all.
    state_page = bytearray(b"\xFF" * STATE_SPAN)
    metadata = build_metadata(packages)
    # MAGIC plus one loaded-flag per pack sits at the bottom of the state page
    # and the metadata table starts at METADATA_AC_OFFSET.  They grow toward
    # each other, so check before they meet.
    flag_bytes = len(dynamic.MAGIC) + len(packages)
    if flag_bytes > METADATA_AC_OFFSET:
        raise RuntimeError(
            f"pack flags need {flag_bytes} B but the metadata table starts at "
            f"+${METADATA_AC_OFFSET:02X}. Lower METADATA_AC_OFFSET only if the "
            f"table still fits below $100FF.")

    metadata_room = TEMPLATE_AC - (STATE_AC + METADATA_AC_OFFSET)
    if len(metadata) > metadata_room:
        raise RuntimeError(
            f"pack metadata overflows the AC state page: {len(packages)} packs "
            f"need {len(metadata)} B but ${STATE_AC + METADATA_AC_OFFSET:05X}-"
            f"${TEMPLATE_AC - 1:05X} holds {metadata_room} B "
            f"({metadata_room // 8} packs). Raise "
            f"COALESCE_SMALL_SCENES_MAX_RECORDS to merge more small scenes, or "
            f"move the metadata table off the state page as the 2026-08-12 "
            f"handoff prescribes. Note the helper reaches it with "
            f"'CLC; ADC #${METADATA_AC_OFFSET:02X}', a single byte, so the "
            f"table cannot simply grow past $100FF without new addressing.")
    state_page[METADATA_AC_OFFSET:METADATA_AC_OFFSET + len(metadata)] = metadata
    idle_page = (IDLE_CACHE + bytes(IDLE_PAGE - IDLE_SPAN)) if IDLE_SPAN else b""
    init_extra = bytes(state_page) + idle_page + template + atlas
    init_extra += bytes((0xFF,)) * (init_extra_bytes - len(init_extra))

    if SUBS_POC:
        # 자막 POC 적재물을 패딩 안에 박는다.  init_extra[0] 의 AC 주소가
        # DIRECTORY_BYTES 이므로 오프셋은 그 차이다.
        payload = _subs_poc_payload()
        offset = SUBS_POC_AC - DIRECTORY_BYTES
        end = offset + len(payload)
        if offset < len(bytes(state_page) + idle_page + template + atlas):
            raise RuntimeError(
                f"자막 POC 적재물이 ${SUBS_POC_AC:05X} 에서 템플릿/아틀라스와 겹친다")
        if end > init_extra_bytes:
            raise RuntimeError(
                f"자막 POC 적재물 {len(payload)} B 가 초기 적재 블록을 "
                f"{end - init_extra_bytes} B 넘는다")
        blob_area = init_extra[offset:end]
        if blob_area != bytes((0xFF,)) * len(payload):
            raise RuntimeError(
                f"${SUBS_POC_AC:05X} 가 패딩이 아니다 -- 무언가 이미 들어 있다")
        init_extra = init_extra[:offset] + payload + init_extra[end:]
        print(f"자막 POC       : {len(payload)} B -> AC ${SUBS_POC_AC:05X} "
              f"(초기 적재 패딩, 여유 {init_extra_bytes - end:,} B)")

    build_packs_compact.atlas_bytes = len(atlas)
    build_packs_compact.atlas_glyphs = len(atlas_order)
    build_packs_compact.record_count = len(compact)
    # Padding included: this is what the init read has to cover past init_total,
    # not the sum of the packs' transferred_bytes.
    build_packs_compact.blob_bytes = len(blob)
    # How far the read has to reach to cover just the preloaded packs.  They
    # lead the blob (ids 0..count-1), so this is the end of the last one, padded
    # the way the next pack's leading pad would pad it.  Truncating the init
    # read here is what makes PRELOAD_MODE "resident" cheaper than "all".
    preload_count = build_packs_compact.preload_pack_count
    build_packs_compact.preload_blob_bytes = 0
    if preload_count:
        last = packages[preload_count - 1]
        assert last["id"] == preload_count - 1, "packs are not in id order"
        build_packs_compact.preload_blob_bytes = align(
            int(last["blob_offset"]) + int(last["bytes"]), USER_BYTES)
    # First and last byte of the constant slot run ($5BE0-$5C3F).  The helper
    # checks these to decide whether the constants still need laying down --
    # see copy_record.  Two bytes rather than one: a single byte that happens
    # to be zero would match uninitialised RAM.
    #
    # 2026-09-08: 오프셋 0 과 95 는 **둘 다 항상 $00 이다.**  슬롯 0 은 마침표라
    # 첫 줄(위쪽)이 비어 있고 슬롯 2 는 줄임표라 마지막 줄(아래쪽)이 비어 있다.
    # 실측 -- AC $010200 의 96 B 중 0 아닌 바이트가 6 개뿐이다.
    #
    # 그 값으로 검사를 켜면 "$00 == $00" 이라 **항상 건너뛴다.**  즉 상수를 한
    # 번도 안 놓고, 게임이 그 범위를 덮어도($FF 384 B 채우기 실측) 복구가 안 된다.
    # 주석이 경계하던 "a single byte that happens to be zero would match
    # uninitialised RAM" 이 두 바이트 모두에서 일어난 것이다.
    #
    # 그래서 자리를 **0 이 아닌 바이트**로 고른다.  앞에서 첫 번째, 뒤에서 첫
    # 번째를 잡아 서로 멀리 떨어뜨린다 -- 일부만 덮인 경우도 걸리게.
    const_block = template[:CONST_SLOTS * GLYPH_BYTES]
    nonzero = [i for i, b in enumerate(const_block) if b]
    if len(nonzero) >= 2:
        build_packs_compact.const_sentinels = (
            nonzero[0], const_block[nonzero[0]],
            nonzero[-1], const_block[nonzero[-1]])
        print("const sentinels : $%04X=%02X · $%04X=%02X  (0 아닌 바이트 %d/%d)"
              % (FONT_CACHE + nonzero[0], const_block[nonzero[0]],
                 FONT_CACHE + nonzero[-1], const_block[nonzero[-1]],
                 len(nonzero), len(const_block)))
    else:
        # 고를 자리가 없으면 검사를 포기하고 매번 복사한다 (안전한 쪽).
        build_packs_compact.const_sentinels = None
        print("const sentinels : 없음 -- 상수가 전부 0 이다.  검사 없이 매번 복사한다")

    image = bytes(directory) + init_extra + bytes(blob)
    return bytes(directory), packages, image, scene_base


def build_metadata(packages: list[dict[str, object]]) -> bytes:
    """8 bytes per pack, read from AC instead of the Bank 69 cave.

    FINAL_LO now holds the final partial chunk's *sector count* rather than a
    byte length.  That removes both the separate sector-count table and the
    lookup that read it, and it avoids repointing the AC pointer in the middle
    of a CD transfer.
    """
    sector_base = (dynamic.APPEND_RELATIVE_SECTOR
                   + (DIRECTORY_BYTES + build_packs_compact.init_extra_bytes) // USER_BYTES)
    out = bytearray()
    for package in packages:
        length = int(package["bytes"])
        full, remainder = divmod(length, CHUNK_BYTES)
        if full > 255:
            raise RuntimeError(f"pack {package['name']} needs {full} chunks")
        final_sectors = (remainder + USER_BYTES - 1) // USER_BYTES
        sector = sector_base + int(package["blob_offset"]) // USER_BYTES
        destination = int(package["destination"])
        out.extend((
            sector & 0xFF, sector >> 8, full, final_sectors, 0,
            destination & 0xFF, (destination >> 8) & 0xFF, (destination >> 16) & 0xFF,
        ))
    return bytes(out)


def build_helper_compact(
    packages: list[dict[str, object]], scene_base: int
) -> tuple[bytes, int]:
    HELPER = dynamic.HELPER
    HELPER_LIMIT = dynamic.HELPER_LIMIT
    # Do NOT reclaim the slack between SCRATCH_BYTES and this $20.  Moving the
    # block up to $BFEF to make room for the title-wipe stub corrupted dialogue
    # glyphs and the action menu -- proved by a build that carried the move but
    # never called the stub (2026-08-16).  The 15 bytes are not free.
    scratch = HELPER_LIMIT - 0x20
    # TPL_LO/TPL_HI and FILLED are the bounded-blank state -- see copy_record.
    (CUR_LO, CUR_HI, LEFT, FINAL_LO, DEST_LO, DEST_MID, DEST_HI, STATUS,
     PACK_ID, REC_LO, REC_MID, REC_HI, GDST_LO, GDST_HI,
     TPL_LO, TPL_HI, FILLED) = range(scratch, scratch + 17)
    # Appended, so every variable above keeps the address it had.
    CACHE_USED = scratch + 17
    resident_count = len(dynamic.RESIDENT_PACK_NAMES)
    MAGIC = dynamic.MAGIC

    a = common.Assembler(HELPER)

    # ---- is the directory (and therefore the atlas) already resident? ----
    a.emit(0xA9, 0); a.abs(0x20, "set_state_address")
    for expected in MAGIC:
        a.abs(0xAD, 0x1A00); a.emit(0xC9, expected); a.branch(0xD0, "init_store")
    a.abs(0x4C, "lookup")

    # ---- title-cache wipe stub, reached only through handler table $7331 ----
    if TITLE_WIPE:
        a.label("title_cache_wipe")
        a.emit(0xA0, 0x0A)                            # LDY #$0A
        a.emit(0xB1, 0xFA)                            # LDA ($FA),Y
        a.emit(0xC9, TITLE_SPAWN_HIGH)                # CMP #$95
        a.branch(0xD0, "title_wipe_done")             # not the title -> through
        if TITLE_WIPE_GATE == "count":
            a.emit(0xA9, TITLE_WIPE_SKIP)             # LDA #n  (the counter)
            countdown = a.pc - 1                      # ...this operand byte
            a.branch(0xF0, "title_wipe_go")           # counted out -> wipe
            a.abs(0xCE, countdown - WINDOW_SHIFT)     # DEC that immediate
            a.branch(0x80, "title_wipe_done")         # BRA -- boot, leave it be
        if TITLE_WIPE_GATE == "restore":
            # Only once our own system is up.
            #
            # init_store runs on the first Korean lookup, which is *after* the
            # boot title.  Copying from the AC before that reads an AC nobody
            # has loaded: measured 2026-08-16, the boot title pulled
            # `08 10 F0 52 ...` and then `F9 A3 A2 21 ...` -- different garbage
            # each run, which is what an uninitialised card looks like.
            #
            # "SDR4 is in the cache" answers it exactly.  copy_record put it
            # there, so the AC is loaded; and when it is absent there is nothing
            # of ours to take out anyway, so skipping costs nothing.
            a.abs(0xAD, CACHE_BASE)                        # LDA $5B80
            a.emit(0xC9, RECORD_MAGIC[0])                  # CMP #'S'
            a.branch(0xD0, "title_wipe_done")

            # The AC source address, and the port mode when it is not already
            # ours.  The three mode registers ($1A07/$1A08/$1A09) carry the same
            # values copy_record last wrote, and the check above proves it ran.
            # The only thing that could have reconfigured the port since is a
            # BIOS CD read from a demand pack load -- which cannot happen when
            # every pack is resident.  0.3.5 §6 verified the writes are
            # redundant and declined to drop them for exactly that pack case;
            # here the case is excluded, and the 11 bytes are what pays for the
            # check above in a cave with one byte free.
            skip_mode = PRELOAD_MODE == "all"
            acc = None
            registers = [(0x1A02, IDLE_AC & 0xFF),
                         (0x1A03, (IDLE_AC >> 8) & 0xFF),
                         (0x1A04, (IDLE_AC >> 16) & 0xFF)]
            if not skip_mode:
                registers += [(0x1A07, 1), (0x1A08, 0), (0x1A09, 0x11)]
            for port, value in registers:
                if value == 0:
                    a.abs(0x9C, port)                      # STZ port
                    continue
                if acc != value:
                    a.emit(0xA9, value)                    # LDA #value
                    acc = value
                a.abs(0x8D, port)                          # STA port
            a.emit(0xF3); a.word(0x1A00); a.word(CACHE_BASE); a.word(len(IDLE_CACHE))
        elif TITLE_WIPE_GATE == "magic":
            # Is the cache holding a record *we* put there?
            #
            # PROBE 1.0.0 (2026-08-16) settled this by measurement rather than
            # by another guess.  At every title spawn it logged $5B80:
            #
            #   boot   #1 82 FF FF 01 3E 00 00 82   the game's own record
            #          #2 FF ...                    (only because we had wiped)
            #          #3 FF ...                    a save present adds a spawn
            #   return #5 53 44 52 34 09 0A DB 54   "SDR4" -- ours
            #
            # build_direct_overlay_layout stamps MAGIC = b"SDR4" into
            # payload[0:4] of every record it builds, so anything copy_record
            # puts in the cache starts with it and nothing else does.  Wiping
            # the game's record is what broke the boot action menu; wiping ours
            # is the whole point.  Two bytes are enough to tell them apart and
            # cost 14 -- the cave has 13 free over the header gate's 7.
            #
            # No state, so nothing to lose to the BIOS CD read (gate="used"),
            # and no dependence on how many spawns a boot happens to issue
            # (gate="count") or on the cache starting out empty (gate="header").
            a.abs(0xAD, CACHE_BASE)                   # LDA $5B80
            a.emit(0xC9, RECORD_MAGIC[0])             # CMP #'S'
            a.branch(0xD0, "title_wipe_done")
            a.abs(0xAD, CACHE_BASE + 1)               # LDA $5B81
            a.emit(0xC9, RECORD_MAGIC[1])             # CMP #'D'
            a.branch(0xD0, "title_wipe_done")
        elif TITLE_WIPE_GATE == "header":
            # No state at all -- ask the cache.  $FF in the header means "no
            # record", which is true of a boot title (nothing drawn yet) and of
            # a cache this stub already wiped.  Anything else is a stale record
            # from before the save, which is exactly what has to go.
            #
            # Measured 2026-08-16: "used" fixed the save-present new game and
            # brought the original save->title->load corruption back, because
            # its flag lives in the range the BIOS CD read overwrites and going
            # to the title reads CD.  This byte is in MPR2 and cannot be lost.
            a.abs(0xAD, CACHE_BASE)                   # LDA $5B80
            a.emit(0xC9, 0xFF)                        # CMP #$FF
            a.branch(0xF0, "title_wipe_done")         # no record -> through
        else:
            # Has anything been drawn into the cache since the last wipe?  If
            # not, this is a boot title however many spawns preceded it, and
            # the preloaded cache must be left alone.
            # The stub runs with MPR3=$69, so the cave is at $6000-$7FFF here,
            # not at its $A000-window address.  Every reference the stub makes
            # into its own bank has to be shifted -- the original's DEC does the
            # same thing.  $5B80 does not: that is MPR2, mapped either way.
            # A magic value, not 0/nonzero.  The scratch block sits inside
            # $7FC0-$7FFF, and PROBE 0.7.0 measured that the BIOS CD read
            # ($EA9E) writes every byte of that range -- §0.9 lists it among the
            # places this project has already been wrong about being free.  A
            # 0/nonzero flag would read as "used" after any stray write, 255
            # times out of 256, and a spurious wipe during boot is exactly the
            # bug being fixed.  Requiring one specific byte makes that 1 in 256.
            a.abs(0xAD, CACHE_USED - WINDOW_SHIFT)    # LDA CACHE_USED
            a.emit(0xC9, CACHE_USED_MAGIC)            # CMP #$5A
            a.branch(0xD0, "title_wipe_done")         # not ours -> through
            a.abs(0x9C, CACHE_USED - WINDOW_SHIFT)    # STZ CACHE_USED
        if TITLE_WIPE_GATE != "restore":
            a.label("title_wipe_go")
            a.emit(0xA9, 0xFF)
            a.emit(0xA2, TITLE_WIPE_BYTES - 1)        # LDX #n-1
            a.label("title_wipe_loop")
            a.abs(0x9D, CACHE_BASE)                   # STA $5B80,X
            a.emit(0xCA)                              # DEX
            a.branch(0x10, "title_wipe_loop")         # BPL
        a.label("title_wipe_done")

        if SUBS_POC:
            # 자막 POC 로더.  스텁의 모든 경로가 여기를 지나므로 **폴스루로 끼운다.**
            # JMP 로 부르지 않는 이유: 케이브는 $A000 창 이름($BCxx)인데 타이틀 스폰
            # 때는 MPR3=$69 라 $6000 창($7Cxx)에서 실행된다.  라벨을 JMP 하면
            # $4000 을 빼야 하는데(WINDOW_SHIFT), 폴스루면 그 함정을 아예 통과한다.
            #
            # 로더가 참조하는 주소는 전부 창과 무관하다:
            #   $2202 벡터 · $5C40/$2311/$3468 목적지  MPR1/MPR2 -- 항상 매핑
            #   $1A02-$1A09 AC 포트                    MPR0 I/O -- 항상 매핑
            #
            # 스폰마다 돌므로(실측 52 회) 한 번만 설치해야 한다.  플래그를 따로 두지
            # 않고 **벡터가 이미 우리 것인지**를 본다 -- 상태 바이트를 아끼고,
            # 설치 전 RAM 이 쓰레기여도 판정이 성립한다.
            # 헬퍼가 init_extra 보다 먼저 조립될 수 있으므로 여기서 직접 채운다.
            # 비어 있으면 전송이 0 개로 나가고 로더가 조용히 아무것도 안 한다.
            if not SUBS_POC_BLOCKS:
                _subs_poc_payload()
            assert SUBS_POC_BLOCKS, "자막 POC 적재물 블록이 비었다"

            # 로더는 **코드 맨 뒤**에 있다.  여기 끼우면 뒤쪽 코드가 밀려
            # init_store 로 가는 상대분기가 범위를 넘는다 (실측: 133 > 127).
            # 맨 뒤에 두면 기존 배치가 한 바이트도 안 움직인다.
            #
            # 창 문제: 케이브는 $A000 창 이름($BDxx)인데 타이틀 스폰 때는 MPR3=$69 라
            # $6000 창($7Dxx)에서 실행된다.  라벨을 그냥 JMP 하면 $4000 이 틀린다.
            # 오퍼랜드 자리를 라벨로 잡아 두고 finish() 뒤에 직접 채운다.
            a.emit(0x4C)
            a.label("subs_jmp_operand")
            a.word(0)

        a.abs(0x4C, SPAWN_HANDLER)                    # JMP $73BD -- original

    # How far the one-shot init read reaches.  Without PRELOAD_PACKS it stops
    # at the atlas and every pack arrives later, on first touch, from CD.  With
    # it, the run continues straight through the pack blob -- the blob begins at
    # init_total on disc and the packs' AC addresses begin at common_base, which
    # resolves to the same number, so one contiguous read lands them correctly.
    # LEFT counts whole 8 KiB chunks and FINAL_LO the leftover 2 KiB sectors.
    init_chunks = build_packs_compact.init_chunks
    init_final_sectors = 0
    if PRELOAD_PACKS:
        extra_chunks, remainder = divmod(
            build_packs_compact.preload_blob_bytes, CHUNK_BYTES)
        init_chunks += extra_chunks
        init_final_sectors = -(-remainder // USER_BYTES)
        if init_chunks > 255:
            raise RuntimeError(
                f"preload needs {init_chunks} chunks; LEFT is one byte. Drop "
                f"PRELOAD_PACKS or shrink the record set.")

    a.label("init_store")
    for variable, value in (
        (CUR_LO, dynamic.APPEND_RELATIVE_SECTOR),
        (CUR_HI, dynamic.APPEND_RELATIVE_SECTOR >> 8),
        (LEFT, init_chunks), (FINAL_LO, init_final_sectors),
        (DEST_LO, 0), (DEST_MID, 0), (DEST_HI, 0),
    ):
        a.emit(0xA9, value); a.abs(0x8D, variable)
    a.abs(0x20, "load_blob")
    a.emit(0xC9, 0); a.branch(0xF0, "init_ok")
    a.abs(0x4C, "return_miss")
    a.label("init_ok")
    a.emit(0xA9, 0); a.abs(0x20, "set_state_address")
    for value in MAGIC:
        a.emit(0xA9, value); a.abs(0x8D, 0x1A00)
    # One flag per pack, scene packs included -- they used to share a single
    # slot.  Written through the auto-incrementing port in a loop rather than
    # unrolled: at 25 packs the unrolled form would cost 125 bytes of a cave
    # that has 69 to spare.  valid_pack reads state[3 + pack_id] and treats
    # "equals pack_id" as loaded, so the two cases differ only in the value.
    # "resident" writes both forms back to back.  The port auto-increments, so
    # the loaded run has to come first and stop exactly at resident_count -- the
    # scene packs that follow take $FF and reach CD on first touch.
    loaded = build_packs_compact.preload_pack_count
    if loaded:
        # Ascending, because the port auto-increments and flag[i] has to be i.
        a.emit(0xA2, 0)                    # LDX #0
        a.label("clear_flags")
        a.emit(0x8A)                       # TXA
        a.abs(0x8D, 0x1A00)                # STA $1A00
        a.emit(0xE8)                       # INX
        a.emit(0xE0, loaded)               # CPX #loaded
        a.branch(0xD0, "clear_flags")
    if loaded < len(packages):
        a.emit(0xA9, 0xFF)
        a.emit(0xA2, len(packages) - loaded)
        a.label("clear_unloaded_flags")
        a.abs(0x8D, 0x1A00)
        a.emit(0xCA)
        a.branch(0xD0, "clear_unloaded_flags")

    if PORT_POC:
        # Two mechanisms the sparse-directory design needs but that this
        # project has never exercised: writing a run of bytes through an AC
        # data port under auto-increment, and using a second port at $1A10.
        # Both are probed once, into AC space no pack ever occupies, and read
        # back by UI 0.1.74.  Nothing else in the build depends on them.
        for value, variable in ((POC_PORT0_AC, DEST_LO), (POC_PORT0_AC >> 8, DEST_MID),
                                (POC_PORT0_AC >> 16, DEST_HI)):
            a.emit(0xA9, value); a.abs(0x8D, variable)
        a.abs(0x20, "set_ac")
        a.emit(0xA2, 0)
        a.label("poc_port0")
        a.emit(0x8A)                       # TXA
        a.abs(0x8D, 0x1A00)                # STA $1A00   (auto-increment)
        a.emit(0xE8, 0xE0, POC_LENGTH)     # INX / CPX #len
        a.branch(0xD0, "poc_port0")
        for value, port in ((POC_PORT1_AC, 0x1A12), (POC_PORT1_AC >> 8, 0x1A13),
                            (POC_PORT1_AC >> 16, 0x1A14), (1, 0x1A17)):
            a.emit(0xA9, value); a.abs(0x8D, port)
        a.abs(0x9C, 0x1A18)
        a.emit(0xA9, 0x11); a.abs(0x8D, 0x1A19)
        a.emit(0xA2, 0)
        a.label("poc_port1")
        a.emit(0x8A)
        a.abs(0x8D, 0x1A10)                # STA $1A10   (second port)
        a.emit(0xE8, 0xE0, POC_LENGTH)
        a.branch(0xD0, "poc_port1")

    # ---- directory lookup: the preloader left direct_relative + slot ----
    a.label("lookup")
    a.emit(0x38); a.abs(0xAD, 0x7FEF)
    a.emit(0xE9, dynamic.DIRECT_RELATIVE & 0xFF, 0x85, 0xF8)
    a.abs(0xAD, 0x7FF0); a.emit(0xE9, dynamic.DIRECT_RELATIVE >> 8, 0x85, 0xF9)
    a.emit(0x06, 0xF8, 0x26, 0xF9, 0x06, 0xF8, 0x26, 0xF9)
    a.emit(0xA5, 0xF8); a.abs(0x8D, DEST_LO)
    a.emit(0xA5, 0xF9); a.abs(0x8D, DEST_MID)
    a.abs(0x9C, DEST_HI)
    a.abs(0x20, "set_ac")
    for variable in (REC_LO, REC_MID, REC_HI, PACK_ID):
        a.abs(0xAD, 0x1A00); a.abs(0x8D, variable)
    a.abs(0xAD, PACK_ID); a.emit(0xC9, 0xFF); a.branch(0xD0, "valid_pack")
    a.abs(0x4C, "return_miss")
    a.label("valid_pack")

    # Every pack now owns a flag byte at state page 3 + pack_id, scene packs
    # included.  They used to share one "current scene pack" slot, which is
    # what made a reopened menu re-read its pack from CD.
    a.emit(0x18, 0x69, 3); a.abs(0x20, "set_state_address")
    a.abs(0xAD, 0x1A00); a.abs(0xCD, PACK_ID); a.branch(0xD0, "load_package")
    a.abs(0x4C, "copy_record")

    # ---- pack metadata now lives in the AC state page ----
    a.label("load_package")
    a.abs(0xAD, PACK_ID); a.emit(0x0A, 0x0A, 0x0A)
    a.emit(0x18, 0x69, METADATA_AC_OFFSET)
    a.abs(0x20, "set_state_address")
    for variable in (CUR_LO, CUR_HI, LEFT, FINAL_LO, STATUS,
                     DEST_LO, DEST_MID, DEST_HI):
        a.abs(0xAD, 0x1A00); a.abs(0x8D, variable)
    a.abs(0x20, "load_blob")
    a.emit(0xC9, 0); a.branch(0xF0, "pack_loaded")
    a.abs(0x4C, "return_miss")
    a.label("pack_loaded")
    a.abs(0xAD, PACK_ID)
    a.emit(0x18, 0x69, 3); a.abs(0x20, "set_state_address")
    a.abs(0xAD, PACK_ID); a.abs(0x8D, 0x1A00)

    # ---- rebuild the 704-byte payload from the compact record ----
    a.label("copy_record")
    # 1. restore the constants and blank exactly the slots the previous record
    #    wrote.  One transfer does both.
    #
    # The template is const slots 0-2, then zeros for slots 3-17, then the
    # helper glyph at slot 18 -- contiguous, in that order.  So a run of
    # 96 + (previous glyph count) * 32 bytes from its start restores the
    # constants and clears the stale glyphs, and nothing else has to move.
    # The longest such run is 96 + 15*32 = 576, which stops exactly where slot
    # 18 begins: the helper glyph is written by the image's initial length of
    # 608 and is never disturbed again.
    #
    # This used to copy all 608 B on every record.  Measured 2026-08-14: that
    # was 3,784 of the 4,377-cycle floor (86%), spent re-copying constants that
    # had not changed and blanking slots that were already blank.  A five-item
    # menu redraw is 13 records, so it landed as 29-50 scanlines on the frames
    # that carried three of them.
    if BLANK_SLOTS:
        # 2026-08-15: the run used to be 96 + (previous glyph count) * 32, which
        # blanked every slot the last record wrote -- and then the glyph loop
        # immediately refilled most of them.  Two records of six glyphs meant
        # clearing six slots and overwriting the same six: 1,152 cycles, 2.5
        # scanlines, moved for nothing.
        #
        # Now the run is the constants only, and stale slots are cleared one at
        # a time inside the glyph loop, which already visits them and already
        # knows which ones this record will not refill.  Only the slots that
        # actually go stale move.
        #
        # This matters because the cost is CPU *occupancy*, not interrupt
        # latency: the game reloads its scroll every 10-12 scanlines by polling,
        # so a helper that holds the CPU for 12.3 scanlines is almost certain to
        # straddle one of those updates and push it a line late.  Shortening the
        # occupancy lowers the collision probability -- there is no threshold to
        # get under, it is linear.
        a.emit(0xA9, (CONST_SLOTS * GLYPH_BYTES) & 0xFF); a.abs(0x8D, "tpl_len_lo")
        a.emit(0xA9, (CONST_SLOTS * GLYPH_BYTES) >> 8); a.abs(0x8D, "tpl_len_hi")
        a.abs(0x9C, TPL_HI)
        # Nothing but this transfer writes $5BE0-$5C3F now -- the per-slot blank
        # starts at slot 3 ($5C40).  So check the constants instead of laying
        # them down every record: ~14 cycles when intact against 593.  The copy
        # still runs the moment they are not, which repairs the damage in the
        # same record.  (A 2026-08-14 build that copied them exactly once, with
        # no check, showed a corrupted glyph after a while -- something outside
        # this helper does reach that range.)
        if CONST_CHECK and build_packs_compact.const_sentinels:
            off_a, val_a, off_b, val_b = build_packs_compact.const_sentinels
            a.abs(0xAD, FONT_CACHE + off_a); a.emit(0xC9, val_a)
            a.branch(0xD0, "template_copy")
            a.abs(0xAD, FONT_CACHE + off_b); a.emit(0xC9, val_b)
            a.branch(0xF0, "template_done")
            a.label("template_copy")
    else:
        a.abs(0xAD, TPL_LO); a.abs(0x8D, "tpl_len_lo")
        a.abs(0xAD, TPL_HI); a.abs(0x8D, "tpl_len_hi")
        # Nothing blanks, so in principle the constants only need laying down
        # once: the text span ends at $5BDF and the glyph loop starts at $5C40,
        # leaving $5BE0-$5C3F alone.  Measured 2026-08-14: not true.  A build
        # that copied them exactly once showed a corrupted glyph after a while,
        # so something outside this helper does reach that range.
        #
        # So check instead of assume.  Two sentinel bytes cost ~14 cycles when
        # the constants are intact -- against the 593 the copy costs -- and the
        # copy still happens the moment they are not, which repairs the damage
        # in the same record rather than leaving it on screen.
        if CONST_CHECK and build_packs_compact.const_sentinels:
            off_a, val_a, off_b, val_b = build_packs_compact.const_sentinels
            a.abs(0xAD, FONT_CACHE + off_a); a.emit(0xC9, val_a)
            a.branch(0xD0, "template_copy")
            a.abs(0xAD, FONT_CACHE + off_b); a.emit(0xC9, val_b)
            a.branch(0xF0, "template_done")
            a.label("template_copy")
    for value, variable in ((TEMPLATE_AC, DEST_LO), (TEMPLATE_AC >> 8, DEST_MID),
                            (TEMPLATE_AC >> 16, DEST_HI)):
        a.emit(0xA9, value); a.abs(0x8D, variable)
    a.abs(0x20, "set_ac")
    a.emit(0xF3); a.word(0x1A00); a.word(FONT_CACHE)
    a.label("tpl_len_lo"); a.emit(0)
    a.label("tpl_len_hi"); a.emit(0)
    a.label("template_done")
    # 2. metadata + encoded text, copied verbatim
    for source, target in ((REC_LO, DEST_LO), (REC_MID, DEST_MID), (REC_HI, DEST_HI)):
        a.abs(0xAD, source); a.abs(0x8D, target)
    a.abs(0x20, "set_ac")
    # Split the same way the template is split, and for the same reason: a TAI
    # is atomic, so 96 bytes hold interrupts off for 1.30 scanlines.  $1A00 is a
    # data port that auto-increments on the AC side, so cutting the transfer and
    # advancing only the destination reads the identical byte stream -- the same
    # argument that made the template split byte-harmless.
    for offset in range(0, TEXT_SPAN, TEXT_CHUNK):
        a.emit(0xF3); a.word(0x1A00); a.word(CACHE_BASE + offset); a.word(TEXT_CHUNK)
    # 3~4 단계: 아틀라스 오프셋 전송과 글리프 루프.  BIOS 판에서는 레코드에
    #          글리프가 없으므로 통째로 내보내지 않는다.  레코드당 인덱스 전송 +
    #          15 x 209 사이클이 사라진다 -- 밀림의 실체가 이것이다.
    #
    #          $1A00 은 자동 증가 포트지만 레코드마다 set_ac 로 주소를 다시
    #          세우므로, 안 읽고 남긴 바이트가 다음 레코드를 어긋나게 하지 않는다.
    if not BIOS_FONT:
        # 3. the atlas offsets land in glyph slot 3, which slot 3 itself overwrites last
        a.emit(0xF3); a.word(0x1A00); a.word(INDEX_SCRATCH); a.word(GLYPH_SLOTS * 2)
        # 4. fill slots 17 down to 3 so the index scratch stays intact until the end
        a.emit(0xA9, GLYPH_DST_LAST & 0xFF); a.abs(0x8D, GDST_LO)
        a.emit(0xA9, GLYPH_DST_LAST >> 8); a.abs(0x8D, GDST_HI)
        a.emit(0xA0, (GLYPH_SLOTS - 1) * 2)
        a.label("glyph_loop")
        a.abs(0xB9, INDEX_SCRATCH + 1)
        a.emit(0xC9, 0xFF)
        a.branch(0xF0, "glyph_blank" if BLANK_SLOTS else "glyph_next")
        a.abs(0x8D, DEST_MID)
        a.abs(0xB9, INDEX_SCRATCH); a.abs(0x8D, DEST_LO)
        a.emit(0xA9, ATLAS_AC >> 16); a.abs(0x8D, DEST_HI)
        a.abs(0x20, "set_ac_base" if AC_FAST else "set_ac")
        a.abs(0xAD, GDST_LO); a.abs(0x8D, "glyph_dst_lo")
        a.abs(0xAD, GDST_HI); a.abs(0x8D, "glyph_dst_hi")
        a.emit(0xF3); a.word(0x1A00)
        a.label("glyph_dst_lo"); a.emit(0)
        a.label("glyph_dst_hi"); a.emit(0)
        a.word(GLYPH_BYTES)
        # Record how far up the glyph run this record reached, so the next one
        # blanks exactly that much and no more.  Only the first fill matters: the
        # loop descends from slot 17, so the first slot it writes is the highest,
        # and the run is dense (build_packs_compact rejects a gap).
        if BLANK_SLOTS:
            # The loop descends from slot 17 and the run is dense, so the first slot
            # it fills is the highest one this record uses.  Y+2 is that count
            # doubled -- exactly what the next record needs to know which slots it
            # leaves stale.
            a.abs(0xAD, TPL_HI); a.branch(0xD0, "glyph_next")
            a.emit(0x98, 0x18, 0x69, 2)              # TYA; CLC; ADC #2
            a.abs(0x8D, TPL_HI)
            a.abs(0x4C, "glyph_next")

            # Reached when this record has no glyph for the slot.  Clear it only if
            # the previous record put one there; otherwise it is already blank and
            # moving 32 bytes over it is the waste this change exists to remove.
            a.label("glyph_blank")
            a.abs(0xCC, TPL_LO)                      # CPY prev_count*2
            a.branch(0xB0, "glyph_next")             # Y >= prev -> never written
            for value, variable in ((BLANK_AC, DEST_LO), (BLANK_AC >> 8, DEST_MID),
                                    (BLANK_AC >> 16, DEST_HI)):
                a.emit(0xA9, value); a.abs(0x8D, variable)
            a.abs(0x20, "set_ac")
            a.abs(0xAD, GDST_LO); a.abs(0x8D, "blank_dst_lo")
            a.abs(0xAD, GDST_HI); a.abs(0x8D, "blank_dst_hi")
            a.emit(0xF3); a.word(0x1A00)
            a.label("blank_dst_lo"); a.emit(0)
            a.label("blank_dst_hi"); a.emit(0)
            a.word(GLYPH_BYTES)
        a.label("glyph_next")
        a.emit(0x38)
        a.abs(0xAD, GDST_LO); a.emit(0xE9, GLYPH_BYTES); a.abs(0x8D, GDST_LO)
        a.abs(0xAD, GDST_HI); a.emit(0xE9, 0); a.abs(0x8D, GDST_HI)
        a.emit(0x88, 0x88); a.branch(0x10, "glyph_loop")
        if BLANK_SLOTS:
            a.abs(0xAD, TPL_HI); a.abs(0x8D, TPL_LO)
    if TITLE_WIPE and TITLE_WIPE_GATE == "used":
        # Reached only when a record was actually rebuilt into the cache, which
        # is exactly what the title stub needs to know.  The preload path never
        # comes through here, so a boot title still sees the flag down.
        a.emit(0xA9, CACHE_USED_MAGIC); a.abs(0x8D, CACHE_USED)
    a.emit(0xA9, 0); a.abs(0x4C, "return_status")

    if BIOS_FONT:
        # $5C40-$5E1F 를 자막 엔진에 내주기로 했다.  글리프 루프가 되살아나면
        # 그 480 B 를 다시 쓰게 되므로 여기서 막는다.  라벨이 곧 증거다:
        # 루프를 방출하면 반드시 이 이름들이 생긴다.
        revived = [n for n in ("glyph_loop", "glyph_next", "glyph_blank",
                               "glyph_dst_lo", "glyph_dst_hi")
                   if n in a.labels]
        if revived:
            raise RuntimeError(
                "SNATCHER_KO_BIOS 인데 글리프 루프가 방출됐다 "
                f"({', '.join(revived)}).  그 코드는 $5C40-$5E1F 를 쓰는데 "
                "그 480 B 는 컷신 자막 엔진에 예약돼 있다 "
                "(SUBTITLE_RAM_CODE · PROBE_DEAD_RAM_0.1.1 실측). "
                "글리프 루프를 되살리려면 자막 배치를 먼저 옮길 것")

    a.label("return_miss")
    a.emit(0xA9, 1)
    a.label("return_status")
    if RENDER_DELAY_SLOT:
        # 진단용 정체.  AC 작업이 전부 끝난 자리다 -- 여기서 기다린 시간은
        # 그대로 "렌더가 시작되기 전 CPU 점유" 다.  A(상태)는 안 건드리고
        # X/Y 만 쓴다.  프리로더가 진입에서 PHX/PHY 로 이미 보존해 둔다.
        #
        # **횟수는 즉치 바이트 하나다** (`render_delay_set` + 1).  Lua 가 그것을
        # 덮어쓰면 빌드 없이 0~255 를 전부 쓸 수 있다.  값을 바꿀 때마다 디스크를
        # 굽는 것은 실험이 아니라 고행이다 (소유자 지적, 2026-08-18).
        #
        # 0 이면 LDY 가 Z 를 세워 BEQ 로 통째로 건너뛴다 -- 정식 빌드와 같은 동작.
        a.label("render_delay_set")
        a.emit(0xA0, RENDER_DELAY)          # LDY #n   <- Lua 가 덮어쓰는 바이트
        a.branch(0xF0, "render_delay_done")
        a.label("render_delay_outer")
        a.emit(0xA2, 0x00)                  # LDX #0
        a.label("render_delay_inner")
        a.emit(0xCA)                        # DEX
        a.branch(0xD0, "render_delay_inner")
        a.emit(0x88)                        # DEY
        a.branch(0xD0, "render_delay_outer")
        a.label("render_delay_done")
    a.emit(0x48)
    a.abs(0xAD, 0x3471); a.emit(0x85, 0x03)
    a.abs(0xAD, 0x3472); a.emit(0x85, 0x04)
    a.emit(0x68, 0x60)

    # ---- Track24 -> AC transfer through the BIOS's MPR4 destination mode ----
    a.label("load_blob")
    a.abs(0x20, "set_ac")
    dynamic.emit_cd_base(a, dynamic.TRACK24_INDEX1_LBA)
    a.abs(0x9C, STATUS)
    a.label("full_test")
    a.abs(0xAD, LEFT); a.branch(0xF0, "final_test")
    for zp, value in ((0xF8, CHUNK_BYTES // USER_BYTES), (0xF9, 0), (0xFA, 0x40),
                      (0xFB, 0), (0xFC, 0)):
        a.emit(0xA9, value, 0x85, zp)
    a.abs(0xAD, CUR_HI); a.emit(0x85, 0xFD)
    a.abs(0xAD, CUR_LO); a.emit(0x85, 0xFE)
    a.emit(0xA9, dynamic.BIOS_DESTINATION_MPR, 0x85, 0xFF)
    a.abs(0x20, dynamic.BIOS_CD_READ)
    a.emit(0xC9, 0); a.branch(0xD0, "blob_failed")
    # Advance by exactly what was just read.  This was a literal 4 in
    # ac_0.1.5-0.1.13, which is correct only while a chunk is 8 KiB.  Raising
    # CHUNK_BYTES without raising this made every chunk overlap the previous
    # one, so the atlas and the pack metadata landed corrupted in AC and the
    # helper then chased garbage sector numbers.
    a.emit(0x18); a.abs(0xAD, CUR_LO)
    a.emit(0x69, CHUNK_BYTES // USER_BYTES); a.abs(0x8D, CUR_LO)
    a.abs(0xAD, CUR_HI); a.emit(0x69, 0); a.abs(0x8D, CUR_HI)
    a.abs(0xCE, LEFT); a.abs(0x4C, "full_test")
    a.label("final_test")
    a.abs(0xAD, FINAL_LO); a.branch(0xF0, "blob_restore")
    a.emit(0x85, 0xF8)
    for zp, value in ((0xF9, 0), (0xFA, 0x40), (0xFB, 0), (0xFC, 0)):
        a.emit(0xA9, value, 0x85, zp)
    a.abs(0xAD, CUR_HI); a.emit(0x85, 0xFD)
    a.abs(0xAD, CUR_LO); a.emit(0x85, 0xFE)
    a.emit(0xA9, dynamic.BIOS_DESTINATION_MPR, 0x85, 0xFF)
    a.abs(0x20, dynamic.BIOS_CD_READ)
    a.emit(0xC9, 0); a.branch(0xF0, "blob_restore")
    a.label("blob_failed")
    a.emit(0xA9, 1); a.abs(0x8D, STATUS)
    a.label("blob_restore")
    dynamic.emit_cd_base(a, dynamic.TRACK02_INDEX1_LBA)
    a.abs(0xAD, STATUS); a.emit(0x60)

    # ---- shared AC pointer setter: was inlined three times at 31 bytes ----
    a.label("set_ac")
    if AC_FAST:
        # The base stores live in set_ac_base so both callers share them; set_ac
        # keeps the control tail on top.  Costs one JSR/RTS on the full path,
        # which runs 2-3 times a record, to save it 12-15 times in the loop.
        a.abs(0x20, "set_ac_base")
    else:
        for variable, port in ((DEST_LO, 0x1A02), (DEST_MID, 0x1A03),
                               (DEST_HI, 0x1A04)):
            a.abs(0xAD, variable); a.abs(0x8D, port)
    a.emit(0xA9, 1); a.abs(0x8D, 0x1A07)
    a.abs(0x9C, 0x1A08)
    a.emit(0xA9, 0x11); a.abs(0x8D, 0x1A09)
    a.emit(0x60)

    if AC_FAST:
        # Base only.  The glyph loop calls this because the port is already in
        # the mode set_ac left it in -- the experiment is whether that holds.
        a.label("set_ac_base")
        for variable, port in ((DEST_LO, 0x1A02), (DEST_MID, 0x1A03),
                               (DEST_HI, 0x1A04)):
            a.abs(0xAD, variable); a.abs(0x8D, port)
        a.emit(0x60)

    # A = low byte of an address inside the AC state page $10000.
    a.label("set_state_address")
    a.abs(0x8D, 0x1A02)
    a.abs(0x9C, 0x1A03)
    a.emit(0xA9, 1); a.abs(0x8D, 0x1A04); a.abs(0x8D, 0x1A07)
    a.abs(0x9C, 0x1A08)
    a.emit(0xA9, 0x11); a.abs(0x8D, 0x1A09)
    a.emit(0x60)

    if SUBS_POC:
        # ---- 컷신 자막 로더 ----
        # 순서가 안전장치다.  2026-08-19 실측: 검증 없이 붙였더니 **타이틀이 안 떴다.**
        # title_wipe_done 은 부팅 타이틀에서도 지나가므로 아무도 안 올린 AC 에서
        # 쓰레기를 긁어 $5C40 에 쓰고 $2202 를 거기로 걸었다 -- IRQ 가 쓰레기로 점프.
        # (같은 함정을 restore 게이트가 2026-08-16 에 이미 겪었다.)
        #
        # 첫 수정은 게임 상태($5B80 의 SDR4 매직)에 기댔는데, **타이틀에 한국어 UI 가
        # 하나도 없어서** copy_record 가 안 돌고 매직이 영영 안 선다.  그래서
        # **적재물 자체를 검증한다** -- 게임이 무엇을 하든 상관없다:
        #
        #   1  엔진을 $5C40 으로.  BIOS 판에서 항상 죽은 자리라 쓰레기가 와도 무해
        #   2  우리 코드인지 첫 두 바이트로 확인
        #   3  아니면 중단.  벡터를 안 걸므로 아무 일도 안 일어난다
        #   4  맞을 때만 벡터를 건다
        #
        # 로더가 옮기는 것은 **엔진뿐**이다.  패턴·SAT 은 엔진이 AC 에서 직접 끌어와
        # 자기 480 B 안의 창을 거쳐 VRAM 으로 보낸다.  게임 RAM 은 안 건드린다.
        if not SUBS_POC_BLOCKS:
            _subs_poc_payload()
        assert SUBS_POC_BLOCKS and SUBS_POC_SIGNATURE, "자막 POC 적재물이 비었다"

        a.label("subtitle_loader")
        a.abs(0xAD, SUBS_VEC_IRQ1 + 1)
        a.emit(0xC9, SUBTITLE_RAM_CODE[0] >> 8)
        a.branch(0xF0, "subs_done")                    # 이미 설치돼 있으면 통과

        for value, port in ((SUBS_POC_AC, 0x1A02), (SUBS_POC_AC >> 8, 0x1A03),
                            (SUBS_POC_AC >> 16, 0x1A04)):
            a.emit(0xA9, value & 0xFF); a.abs(0x8D, port)
        a.emit(0xA9, 1); a.abs(0x8D, 0x1A07)
        a.abs(0x9C, 0x1A08)
        a.emit(0xA9, 0x11); a.abs(0x8D, 0x1A09)

        engine_dest, engine_len = SUBS_POC_BLOCKS[0]
        a.emit(0xF3); a.word(0x1A00); a.word(engine_dest); a.word(engine_len)

        for offset, expected in enumerate(SUBS_POC_SIGNATURE):
            a.abs(0xAD, engine_dest + offset)
            a.emit(0xC9, expected)
            a.branch(0xD0, "subs_done")                # 우리 것이 아니다 -> 중단

        a.emit(0xA9, SUBTITLE_RAM_CODE[0] & 0xFF); a.abs(0x8D, SUBS_VEC_IRQ1)
        a.emit(0xA9, SUBTITLE_RAM_CODE[0] >> 8);   a.abs(0x8D, SUBS_VEC_IRQ1 + 1)

        a.label("subs_done")
        a.abs(0x4C, SPAWN_HANDLER)                     # 원래 스텁이 하던 체인

    code = a.finish()

    if SUBS_POC:
        # 스텁의 JMP 오퍼랜드를 $6000 창 주소로 채운다 (위 창 문제 주석 참고).
        operand = a.labels["subs_jmp_operand"] - HELPER
        target = a.labels["subtitle_loader"] - WINDOW_SHIFT
        code = (code[:operand] + bytes((target & 0xFF, target >> 8))
                + code[operand + 2:])
        print(f"자막 로더       : $%04X (실행 시 $%04X), 스텁에서 JMP"
              % (a.labels["subtitle_loader"], target))
    if HELPER + len(code) > scratch:
        raise RuntimeError(
            f"helper code ${HELPER:04X}-${HELPER + len(code):04X} overruns the "
            f"scratch block at ${scratch:04X} (cave limit ${HELPER_LIMIT:04X})"
        )
    # ---- 컷신 자막 로더 자리 (2026-08-19) ----
    #
    # 케이브는 이 사업에서 제일 귀한 자원이다.  2026-08-18 기준 631/782 B 를
    # 쓰고 있어 여유가 151 B 뿐인데, 자막이 그 중 일부를 반드시 가져간다.
    #
    # 자막 엔진 본체(약 1.5 KB)는 여기 못 들어온다 -- AC 에 두고 컷신 진입 때
    # RAM 으로 복사한다.  케이브에 남는 것은 그 복사를 시작하는 로더뿐이다:
    # $1A02-$1A04 에 베이스 3 바이트를 쓰고 포트에서 블록을 긁어오는 루프.
    # copy_record 가 이미 하는 일과 같은 모양이다.
    #
    # **2026-08-19 갱신: 64 -> 80.**  로더를 실제로 짜서 재니 69 B 였다
    # (`tools/build_subtitle_poc.py` 의 `build_loader`).  64 는 측정이 아니라
    # 어림값이었으므로 실측으로 갱신한다.  내역:
    #
    #     벡터가 이미 우리 것인지 확인      7 B   상태 바이트를 안 쓴다
    #     AC 베이스 $1C0000 + 제어 3 개    28 B
    #     TAI x 3 (엔진 · 패턴 · SAT)      21 B
    #     $2202 벡터 설치                  10 B
    #     JMP $73BD 체인                    3 B
    #
    # 80 으로 잡은 것은 11 B 여유를 두기 위해서다.  로더가 자랄 여지가 있다 --
    # 지금은 "벡터가 우리 것이면 통과" 로 한 번만 도는데, 세이브->타이틀->재진입
    # 같은 경로에서 엔진 상태(프레임 카운터·shown)를 초기화해야 할 수 있다.
    #
    # 5 B 를 아끼려고 AC 제어 레지스터($1A07/$1A08/$1A09) 설정을 생략하는 길이
    # 있는데 **가지 않는다.**  "헬퍼가 이미 세웠을 테니 괜찮겠지" 는 이 프로젝트가
    # $5B80 · $BFCF · $7FF1 에서 세 번 데인 바로 그 가정이다.
    #
    # 예약 방식은 "쓰지 않고 비워두기" 가 아니라 **한도를 낮추기** 다.  다음에
    # 누가 헬퍼를 72 B 이상 늘리면 그때 빌드가 여기서 멈춘다.  지금 조용히
    # 먹히고 자막 붙일 때 발견하는 것보다 낫다.
    #
    # 자막을 실제로 붙일 때 이 상수를 0 으로 내리고 로더를 code 에 넣으면 된다.
    # POC 를 켜면 로더가 실제 코드로 들어가므로 예약을 0 으로 내린다.
    # 예약과 실물이 이중으로 세어지면 감사가 거짓말을 한다.
    SUBTITLE_LOADER_RESERVE = 0 if SUBS_POC else 80
    free_after_reserve = scratch - (HELPER + len(code)) - SUBTITLE_LOADER_RESERVE
    if free_after_reserve < 0:
        raise RuntimeError(
            f"helper code is {-free_after_reserve} B into the "
            f"{SUBTITLE_LOADER_RESERVE}-byte cutscene subtitle loader reserve "
            f"(code {len(code)} B, cave free "
            f"{scratch - (HELPER + len(code))} B).  Either shrink the helper or "
            f"lower SUBTITLE_LOADER_RESERVE deliberately -- do not let the "
            f"subtitle loader lose its seat by accident."
        )
    print(f"    cave: {len(code)} B code, {scratch - (HELPER + len(code))} B free, "
          f"{SUBTITLE_LOADER_RESERVE} B reserved for the subtitle loader, "
          f"{free_after_reserve} B spare")
    # TPL_LO/TPL_HI start at the whole template so the first record after a load
    # restores the constants and slot 18 and clears every glyph slot.  From then
    # on the length is bounded by what was actually written.
    scratch_image = bytearray(SCRATCH_BYTES)
    if BLANK_SLOTS:
        # Slot count * 2, i.e. "the previous record used every slot", so the
        # first record after a load clears them all.  Nothing is known about
        # what is sitting in the cache at that point.
        scratch_image[TPL_LO - scratch] = GLYPH_SLOTS * 2
    else:
        scratch_image[TPL_LO - scratch] = TEMPLATE_BYTES & 0xFF
        scratch_image[TPL_HI - scratch] = TEMPLATE_BYTES >> 8
    image = (code + bytes((0xFF,)) * (scratch - (HELPER + len(code)))
             + bytes(scratch_image))
    if HELPER + len(image) > HELPER_LIMIT:
        raise RuntimeError("Bank 69 helper exceeds its 814-byte cave")
    build_helper_compact.code_bytes = len(code)
    build_helper_compact.free_bytes = scratch - (HELPER + len(code))
    # Kept so main() can write a symbol file.  A Lua probe cannot hook
    # copy_record or load_blob without knowing where the assembler put them,
    # and hand-counting bytes off a listing goes stale on the next edit.
    build_helper_compact.labels = dict(a.labels)
    build_helper_compact.init_chunks = init_chunks
    build_helper_compact.init_final_sectors = init_final_sectors
    return image, len(code)


dynamic.VERSION = VERSION
dynamic.OUT = ROOT / "build" / "patch" / VERSION
dynamic.RESIDENT_PACK_NAMES = ("speaker", "ui", "small_scenes", "shared")
# 2026-08-15: 3 stopped fitting.  Review progress pulled in new scenes and the
# scene count reached 33, over both ceilings -- the hardcoded 31 for the
# directory's pack_id field, and the real one at 28 where the AC state page's
# 8-bytes-per-pack metadata table runs into the template at $10100.
#
#   threshold 4 -> 31 packs   clears 31, still over 28
#   threshold 6 -> 27 packs   clears both, with room for a few more scenes
#
# This is a stopgap.  The scene split is far finer than the game's own text
# banks: grouping by MPR6 gives 9-11 packs, which is what the location-pack work
# will do once a full playthrough has been collected.  Revisit this constant
# then rather than raising it again.
dynamic.COALESCE_SMALL_SCENES_MAX_RECORDS = 6
dynamic.COALESCE_SMALL_SCENES_TARGET = "small_scenes"
dynamic.COMMON_DATA_BASE = 0x16000
dynamic.build_packs = build_packs_compact
dynamic.build_helper = build_helper_compact


def main() -> None:
    """Run stage 3.  Importable so a version wrapper can retarget and call it.

    The body used to live directly under ``if __name__ == "__main__"``, which
    made the module import cleanly but gave the caller nothing to run.
    """

    dynamic.main()

    manifest_path = dynamic.OUT / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["compact_records"] = {
        "record_bytes": COMPACT_BYTES,
        "original_record_bytes": RECORD_BYTES,
        "record_count": build_packs_compact.record_count,
        "atlas_glyphs": build_packs_compact.atlas_glyphs,
        "atlas_bytes": build_packs_compact.atlas_bytes,
        "template_bytes": TEMPLATE_BYTES,
        # Bytes per template block transfer, and the resulting worst-case
        # interrupt-blocked window.  A disc is unreadable as evidence without
        # this number on it.
        "template_chunk_bytes": TEMPLATE_CHUNK,
        "template_chunk_blocked_cycles": 17 + 6 * TEMPLATE_CHUNK,
        "template_ac": f"{TEMPLATE_AC:05X}",
        "atlas_ac": f"{ATLAS_AC:05X}",
        "metadata_ac": f"{STATE_AC + METADATA_AC_OFFSET:05X}",
        "initial_cd_chunks": build_helper_compact.init_chunks,
        "initial_cd_final_sectors": build_helper_compact.init_final_sectors,
        # How much CD access happens during play.  The abandoned factory streams
        # CD by itself and a demand load stalls that stream, so "all" buys quiet
        # at the cost of boot time; "resident" trades a little of that quiet back
        # for roughly a third off the boot read.  Recorded by name as well as by
        # the old bool so a disc still says which way it was built.
        "preload_packs": PRELOAD_PACKS,
        "preload_mode": PRELOAD_MODE,
        "preload_pack_count": build_packs_compact.preload_pack_count,
        "byte_exact_verified": build_packs_compact.record_count,
    }
    manifest["helper_free_bytes"] = build_helper_compact.free_bytes
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    # Helper symbols, for probes.  dynamic.HELPER is already the run-time
    # address the bank is mapped at ($BCD2), not the $9CD2 the AC series
    # started from, so these labels need no relocation.
    symbols = {
        "helper_base": f"{dynamic.HELPER:04X}",
        "helper_limit": f"{dynamic.HELPER_LIMIT:04X}",
        "bios_cd_read": f"{dynamic.BIOS_CD_READ:04X}",
        "cost_cycles": {
            # 17 + 6/byte per block transfer, for reading a frame's worth of
            # helper traffic as time rather than as a call count.
            "template": (TEMPLATE_BYTES // TEMPLATE_CHUNK) * (17 + 6 * TEMPLATE_CHUNK),
            "text_span": 17 + 6 * TEXT_SPAN,
            "glyph_slot": 0 if BIOS_FONT else 17 + 6 * GLYPH_BYTES,
            "glyph_slots_max": 0 if BIOS_FONT else GLYPH_SLOTS,
        },
        "labels": {name: f"{address:04X}"
                   for name, address in sorted(build_helper_compact.labels.items())},
    }
    (dynamic.OUT / "helper_symbols.json").write_text(
        json.dumps(symbols, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    with (dynamic.OUT / "runtime_scene_assignment.tsv").open(
            "w", encoding="utf-8-sig", newline="") as handle:
        fields = ("reference", "scene", "method", "runtime_seq", "scene_seq",
                  "sequence_distance", "catalog")
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t")
        writer.writeheader()
        writer.writerows(assignment.RUNTIME_EVIDENCE)
    shutil.copy2(
        ROOT / "snatcher_tool" / "translation" / "master_conflict_exclusions.tsv",
        dynamic.OUT / "master_conflict_exclusions.tsv")
    shutil.copy2(
        ROOT / "lua" / "UI 0.1.72.lua",
        dynamic.OUT / "UI 0.1.72.lua")

    print(f"\ncompact records : {build_packs_compact.record_count} x {COMPACT_BYTES} B")
    print(f"atlas           : {build_packs_compact.atlas_glyphs} glyphs, "
          f"{build_packs_compact.atlas_bytes} B")
    print(f"initial CD load : {build_helper_compact.init_chunks} chunks of 8 KiB"
          + (f" + {build_helper_compact.init_final_sectors} sectors"
             if PRELOAD_PACKS else "")
          + f"   preload={PRELOAD_MODE} "
            f"({build_packs_compact.preload_pack_count} packs)")
    print(f"helper code     : {build_helper_compact.code_bytes} B "
          f"({build_helper_compact.free_bytes} B free before scratch)")


if __name__ == "__main__":
    main()
