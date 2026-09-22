#!/usr/bin/env python3
"""CD-DA 전용 스케줄러 함수 (2026-09-03 저녁).

★ `build_snatcher_0_4_6_29_native_arm.py` 는 **1 바이트도 안 건드린다.**
  이 파일은 그 옆에 완전히 새로 만든다 -- 물리적으로 다른 파일이라
  기존 ADPCM 빌드 사슬은 이 파일의 존재를 몰라도 된다 (소유자 요청:
  "ADPCM 에는 영향 안 가도록").

무엇을 하나
-----------
`sched_due`(ADPCM, native_arm.py)를 참고해 CD-DA 전용 판을 만든다.  다른 점 셋:

    1  selector 9 B 통째 복사 대신 **record_ptr 3 B 만** 복사한다.
       (CD-DA 렌더러는 record_ptr 바로 뒤에 count/list 가 있어 9 B 복사는
        표시 레코드 헤더까지 뭉갠다 -- engine_cdda_scheduled_track17.json 실측)
    2  vram_base 즉치 3 개(hi/lo/attr)를 렌더러의 세 오프셋에 **개별** 심는다.
       (ADPCM 은 무장 시 1 회만 하는 일을, CD-DA 는 구간마다 해야 한다)
    3  count 를 다 쓰면 STATE=3 을 **즉시 쓰지 않는다.**
       native_arm.py 의 `arm_return`(2026-09-03 자 주석, "SAT 는 vblank 에
       래치되므로...")이 쓰는 것과 **같은 ready 기반 2 단 지연**을 그대로
       재사용한다.  CD-DA 는 지금 그 보호 밖에 있다 (코드가 CD-DA 를 명시적
       으로 건너뛴다) -- 스케줄러로 옮기면서 이 보호를 얹는 것이 이 판의
       핵심 목적 중 하나다.

AC_SCHED(0x1F2710, elapsed·part·count·next 7 B)는 ADPCM 과 **공유**한다.
매체가 항상 하나만 active 이므로 문제없다.

    python build_snatcher_cdda_scheduler.py       크기만 재고 끝 (검증)
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_subtitle_engine as base  # noqa: E402  (Asm 클래스 원본)
from build_snatcher_0_4_6_29_native_arm import (  # noqa: E402
    ac_ptr_const, ac_ptr_local, ac_ptr_ram, AC_SCHED, AC_HELPER_CTL_BASE,
    S_ELAPSED, S_PART, S_COUNT, S_NEXT, S_LOCALS,
    STATE, AC_ENGINE,
)

# 렌더러 즉치 attr 에 들어가는 팔레트 번호.
# ⚠ build_cdda_mini_index_all.PALETTE 와 **같아야 한다** (imm3 와 같은 식).
MOVE_PALETTE = 0x0F

# ★★ 2026-09-05: CD-DA 전용 스택 로컬 배치.  **ADPCM 과 갈라선다.**
#
#   원본(native_arm)은 지속 7 B (elapsed u16 · part · count · next u24) 에
#   S_START(8,9) 를 스크래치로 얹어 S_LOCALS = 9 다.  CD-DA 는 여기에
#   **`last` 한 바이트**를 더 지속시켜야 한다 (VBlank 시계의 직전 값).
#
#       +1,2  elapsed u16
#       +3    part
#       +4    count
#       +5,6,7 next u24
#       +8    last        ★새로 지속되는 8 번째 바이트
#       +9,10 start u16   (스크래치.  원본 8,9 에서 한 칸 밀었다)
#
#   ⚠ 상수를 native_arm 에서 고치면 **ADPCM 스케줄러까지 바뀐다.**  소유자 방침이
#     "잘되는 ADPCM 은 유지" 이므로 여기서만 따로 정의해 쓴다.
#
#   ★ 8 번째 바이트가 놓이는 자리 = AC_SCHED + 7 = **$1F2717**.
#     여기는 딱 한 바이트짜리 틈이다.  `build_snatcher_0_4_7_0_lba_probe.py`
#     :176-181 의 AC $1F27xx 지도를 실물로 확인했다:
#
#         $1F2700  관측 슬롯 (코드가 +12 까지 쓴다)
#         $1F2710  AC_SCHED 7 B                       -> $1F2710-$1F2716
#         $1F2717  ★비어 있다 (여기를 쓴다)
#         $1F2718  AC_RCR_STATE (+0 안 씀 · +1 플래그 · +2~4 LBA)
#         $1F2720  옛 CD-DA 시계 (매직 5A A5 + elapsed)
#         $1F2800  디렉터리
#
#     처음엔 "AC_SCHED 뒤로 233 B 가 비었다" 고 적었는데 **틀렸다.**  바로 다음
#     $1F2718 부터 AC_RCR_STATE 다.  한 칸만 더 컸으면 밟았다.
#     지속 바이트를 더 늘리려면 그 지도를 먼저 다시 볼 것.
S_LAST = 8
S_START = 9
S_LOCALS_CDDA = S_LOCALS + 1        # 9 -> 10
S_PERSIST = 8                       # AC_SCHED 에 오가는 바이트 수 (7 -> 8)

# VBlank 마다 오르는 RAM 시계.  0.5.180 실측: 900 프레임 동안 900 번 +1 이고,
# 같은 구간에서 스케줄러는 895 번밖에 안 불렸다 -- **놓친 프레임에도 오른다.**
# 원본 BIOS 에 `INC $1B`(zp = $201B) 가 뱅크 4·23 에 있다.  제로페이지(BIOS 변수
# 구역)라 게임 장면 전환에 덜 휘둘린다.  후보였던 $2249 는 뱅크 0 이 올린다.
FRAME_CLOCK = 0x201B

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "cutscene_subs"

# 스케줄러 기반 CD-DA 렌더러 오프셋 (engine_cdda_scheduled_track17.json 실측).
# ★ 절대 CPU 주소로 쓸 때는 base.ENGINE_LO(=$5B80)를 더한다.
RENDERER_INFO = BUILD / "engine_cdda_scheduled_track17.json"


def load_renderer_offsets() -> dict[str, int]:
    if not RENDERER_INFO.exists():
        raise SystemExit(f"렌더러 정보가 없다: {RENDERER_INFO}\n"
                         "  python build_subtitle_engine_cdda_scheduled.py --write 먼저")
    info = json.loads(RENDERER_INFO.read_text(encoding="utf-8"))
    labels = info["labels"]
    need = ("record_ptr", "ready", "stage", "vram_base_hi_imm",
            "pattern_base_lo_imm", "pattern_attr_imm")
    for n in need:
        if n not in labels:
            raise SystemExit(f"렌더러에 라벨이 없다: {n}")
    return labels


# CD_SUBQ 의 "현재 트랙" (BCD).  재생 중에만 그 트랙 번호를 들고 있다.
CD_SUBQ_TRACK = 0x20A2
# ★ 디렉터리 조회가 쓰는 트랙 (하위 7 비트).  $20A2 와 다를 수 있다 --
#   2026-09-08 실기 f87812 에서 $20A2=21 인데 $26F9=20 이었다.
#   완료 표식은 **조회와 같은 것**을 봐야 한다, 안 그러면 그 한 프레임에
#   관문이 열리고 조회는 옛 트랙을 다시 무장한다.
CD_SUBQ_RAW_TRACK = 0x26F9
TRACK17_BCD = 0x17

# 게임의 오프닝 스킵 판정 ($8011 LDA $222D / AND #$0C / BNE -> $8411).
# 출처: docs/handoff/SNATCHER_CDDA_MID_SKIP_FIX_2026-09-01.md §2
# patch_bios_cpu_cache.py 도 같은 주소를 SKIP_INPUT 으로 쓴다.
SKIP_INPUT = 0x222D
SKIP_MASK = 0x0C

# ready 의 특수값.  둘 다 bit7 이 서 있어 렌더러 entry 의 `BMI -> RTS` 를 탄다
# (= 안 그리고 push 도 안 한다).  스케줄러는 둘을 구별해야 한다:
#
#   $FF  아직 한 구간도 안 그렸다   <- 구워진 초기값.  첫 구간이 오면 STZ 로 풀린다
#   $FE  스킵됐다                   <- 정지를 기다리는 중.  다시는 안 그린다
#
# ★ 2026-09-04: 처음엔 둘 다 $FF 로 썼다가 **자막이 아예 안 나왔다.**
#   무장 직후 ready 가 $FF 라 스케줄러가 "이미 스킵됨" 으로 읽었다.
READY_IDLE = 0xFF
READY_SKIPPED = 0xFE
# mini index 안의 중간 숨김 항목.  실제 팩 주소의 상위 바이트는 $16이므로
# $FFFFFF는 충돌하지 않는다.  READY_IDLE을 쓰면 렌더러만 멈추고 스케줄러는
# 계속 돌아 다음 실제 항목에서 다시 STZ ready로 표시를 재개할 수 있다.
HIDE_RECORD_PTR = 0xFFFFFF


def build_scheduler_cdda(origin: int, known: dict[str, int], *,
                         ready_cpu: int, record_ptr_cpu: int,
                         vram_hi_cpu: int, vram_lo_cpu: int, vram_attr_cpu: int,
                         stage_cpu: int, stage_template_ac: int | None, stage_bytes: int,
                         track_bcd: int = TRACK17_BCD,
                         mini_stride: int = 13,
                         track_byte_cpu: int | None = None,
                         # ★ 렌더러 패딩 안 '이사 기록' 오프셋 (2 B: 구간 번호 · 새 base hi).
                         #   0 이면 이사 코드를 아예 안 뿜는다 -- 바이트 동일.
                         move_byte_off: int = 0,
                         # ★ 2026-09-06 신설.  기본값은 지금까지와 **바이트 동일**이다.
                         #
                         #   CD-DA 전용 설계(인계서 §47~§49)에서는 CD-DA 가 ADPCM 과
                         #   STATE($7FDF)를 **같이 쓰지 않는다** -- 무장 자리가 원래
                         #   둘인데(start_cdda $F80E · start_adpcm $FA38) 둘 다 같은
                         #   값을 써서 매체 구분을 버린 것이 §49-2 의 결함이었다.
                         #   그래서 CD-DA 는 자기 상태 바이트($5E1A · ADPCM 이미지 밖)를
                         #   쓰고, 상주부는 ADPCM 것만 보게 된다.
                         state_cpu: int = STATE,
                         # ROM 상주 CD-DA는 STATE 대신 전용 상태를 끝낸다.
                         private_state_cpu: int | None = None,
                         # ROM 상주판의 "이번 재생 건 자막 소진" AC 표식.
                         # 자막 목록을 다 쓴 자연 종료에서만 1을 쓰며, 실제 새
                         # CD-DA 요청 경로가 지운다. None이면 기존 바이트를 유지한다.
                         done_latch_ac: int | None = None,
                         done_latch_value: int = 0xA5,
                         # 표식을 찍을 때 "어느 트랙에서 찍었는지" 를 표식 바로
                         # 다음 AC 바이트에 같이 남긴다.  None 이면 바이트 동일.
                         done_latch_track_cpu: int | None = None,
                         ) -> tuple[bytes, dict[str, int]]:
    a = base.Asm(origin, known)
    a.label("scheduler_cdda")

    # channel1 문맥 저장 + 10 B stack locals + AC_SCHED 읽기
    # (ADPCM 과 같은 형태지만 `last` 한 칸이 더 있다 -- S_LAST 주석 참고)
    for i in range(8):
        a.abs_(0xAD, 0x1A12 + i); a.emit(0x48)
    for _ in range(S_LOCALS_CDDA):
        a.emit(0x48)
    a.emit(0xBA)
    ac_ptr_const(a, 1, AC_SCHED)
    for i in range(S_PERSIST):
        a.abs_(0xAD, 0x1A10); a.abs_(0x9D, 0x2100 + S_ELAPSED + i)

    # ★★ 2026-09-04 밤: 트랙이 멈췄으면 여기서 끝낸다 (스킵 대응).
    #
    #   스케줄러는 elapsed 를 프레임마다 올릴 뿐 **트랙이 멈춘 걸 몰랐다.**
    #   그래서 오프닝을 스킵하면 39 구간이 남은 만큼(최대 2 분) 계속 돌면서
    #   게임이 되찾은 RAM 에 stage 31 B 를 반복해 덮어썼다 -- 실기에서
    #   검은 화면 / 화면 파손 (0.4.7.6, 소유자 사진).
    #
    #   옛 자체 타이머 판에는 이 증상이 없었다.  정지를 감지해서가 아니라
    #   36~45 초 밖에서는 아무것도 안 하고 45 초에 스스로 끝났기 때문이다.
    #   손대는 범위가 9 초 · 2 회라 안 보였을 뿐이다.
    #
    # 신호  CD_SUBQ 의 현재 트랙 $20A2 (BCD).  0.5.172 실측:
    #
    #                   재생 중   스킵      자연 종료
    #     $20A2         $17       $00       $18        ★둘 다 잡는다
    #     $26F9         $11       $11 그대로 $12        ✘스킵을 못 잡는다
    #
    #   체류 프레임이 $26F9=$11 x8255 · $20A2=$17 x8258 로 거의 같아서 언뜻
    #   둘 다 되는 것처럼 보인다.  실제로 스킵해 보지 않았으면 $26F9 를 골라
    #   **자연 종료만 잡고 스킵은 그대로 깨졌을** 것이다.
    #
    # 여유  무장 f1349 -> 트랙 종료 f9537 = 8,188 프레임.  마지막 구간은 7,233.
    #       ★955 프레임(약 16 초) 남는다.  자연 재생에서는 스케줄러가 이미
    #       7,233 에서 스스로 끝나므로 이 검사는 **스킵 경로에서만** 걸린다.
    #
    # ⚠ 아침 문서의 "$20A0 은 트랙 시작에만 갱신된다" 는 반쪽이었다.
    #   트랙이 바뀌거나 멈출 때도 갱신된다 (0.5.172 실측).
    # ★★★ 2026-09-04 밤, 두 번째: **게임의 스킵 입력을 직접 본다.**
    #
    #   `$20A2` 만으로는 620 프레임(약 10 초) 늦다.  그 사이 자막이 5 개쯤 더
    #   뜬다 (구간 간격 평균 133 프레임).  실측:
    #
    #       f8163  스킵 누름
    #       +4     BIOS $E018 (CD_PAUSE)
    #       +620   $20A2 $17 -> $00        <- 여기서야 잡힌다
    #
    #   ★ `docs/handoff/SNATCHER_CDDA_MID_SKIP_FIX_2026-09-01.md` 가 이미
    #     같은 결론을 적어 뒀다 -- "CD 오디오 정지를 스킵 신호로 쓰는 접근은
    #     틀렸다.  실제 게임 분기보다 몇 프레임 늦게 감지된다."
    #     그 문서가 확정한 게임의 실제 스킵 판정이 이것이다:
    #
    #       $8011  AD 2D 22   LDA $222D
    #       $8014  29 0C      AND #$0C
    #       $8016  F0 03      BEQ $801B
    #       $8018  4C 11 84   JMP $8411     <- 오프닝 스킵 목적지
    #
    #   우리도 **같은 바이트를 같은 마스크로** 본다.  스케줄러는 FEC4 에서
    #   매 프레임 도니 게임의 $8011 과 같은 프레임에 잡는다 -- 지연 0.
    #
    #   0.5.174 로 독립 확인: 누른 +1 프레임에 $222D 가 바뀌고,
    #   0.5.175 로 확인: 트랙 17 재생 8,258 프레임 내내 한 번도 안 변한다.
    # ★★★★ 2026-09-04 밤, 세 번째: **그리기 중단과 정리를 나눈다.**
    #
    #   0.4.7.8 은 스킵을 감지한 그 프레임에 STATE=3 을 썼다.  그랬더니
    #   **게임이 스킵 자체를 못 했다** -- 화면도 안 넘어가고 음악도 안 멈췄다.
    #   상주부의 정리가 그 자리에서 **무장 때 떠 둔 $5B80 스냅샷**(100 초쯤 묵은
    #   것)을 되돌리는데, 게임이 아직 오프닝을 돌리는 중이라 스크립트 VM 스택이
    #   옛것으로 덮여 그다음 처리가 깨진다.
    #
    #   0.4.7.7 은 그 정리가 +620 프레임에 왔다 -- 게임이 이미 스킵을 끝낸 뒤라
    #   문제가 안 됐다.  그래서 **정리 시점은 0.4.7.7 그대로 두고**, 스킵에는
    #   "그리기만 멈추기" 를 시킨다:
    #
    #       스킵 입력 감지     ready=$FE -> entry 가 BMI -> RTS.  즉시 사라진다
    #                          ★STATE 는 2 로 유지.  게임을 안 건드린다
    #       CD 가 실제 정지    그때 STATE=3 -> 정리 (0.4.7.7 과 같은 시점)
    #
    #   ★표식은 $FE 다.  $FF 는 **구워진 초기값**(아직 한 구간도 안 그렸다)이라
    #   그걸 쓰면 무장 직후 스케줄러가 "이미 스킵됨" 으로 읽어 **자막이 아예 안
    #   나온다** (2026-09-04 실기에서 그렇게 됐다).  READY_IDLE/READY_SKIPPED 참고.
    #
    # ★ 자연 종료 경로(part 소진 -> cdda_finished)는 **한 줄도 안 바뀐다.**
    #   회귀가 통과한 그 경로 그대로다.
    a.abs_(0xAD, ready_cpu)
    a.emit(0xC9, READY_SKIPPED)
    a.branch(0xD0, "cdda_check_skip")
    a.emit(0x4C); a.word("cdda_wait_stop")      # 이미 스킵됨 -> 정지만 기다린다
    a.label("cdda_check_skip")

    # 게임의 오프닝 스킵 판정과 **같은 바이트·같은 마스크**
    # ($8011 LDA $222D / AND #$0C / BNE -> $8411).
    # 출처: docs/handoff/SNATCHER_CDDA_MID_SKIP_FIX_2026-09-01.md §2
    a.abs_(0xAD, SKIP_INPUT)
    a.emit(0x29, SKIP_MASK)
    a.branch(0xF0, "cdda_not_skipped")
    a.emit(0x4C); a.word("cdda_skip")
    a.label("cdda_not_skipped")

    # 정지·트랙 전환은 CD_SUBQ 로 잡는다 (스킵이 아닌 경로를 덮는다).
    # ★ 전 트랙판에서는 트랙 BCD 가 상수가 아니다.  무장 때 cdda_start 가
    #   렌더러 패딩(코드 뒤 · 매직 앞)에 심어 둔 값을 읽는다.
    a.abs_(0xAD, CD_SUBQ_TRACK)
    if track_byte_cpu is None:
        a.emit(0xC9, track_bcd)              # CMP #imm  (트랙 하나 고정)
    else:
        a.abs_(0xCD, track_byte_cpu)         # CMP abs   (전 트랙)
    a.branch(0xF0, "cdda_playing")
    a.emit(0x4C); a.word("cdda_finished")
    a.label("cdda_playing")

    # ★★★ 2026-09-05: elapsed 를 **호출 횟수**가 아니라 **진짜 시간**으로 센다.
    #
    #   있던 것    INC elapsed          ; 스케줄러가 불릴 때마다 +1
    #
    #   스케줄러는 게임 루프(FEC4)에서 불린다.  게임이 한 프레임을 넘기면 우리도
    #   같이 건너뛰고, 그만큼 자막 시계가 **멈춘다.**  0.5.3 실측:
    #
    #       f5400   뒤처짐  16 프레임
    #       f9000           72
    #       f11700         220  (3.67 초)  -- 계속 벌어진다
    #       ★오버클럭에서는 0 이다 = 프레임을 못 따라가서 생기는 문제다
    #
    #   VBlank IRQ 는 CPU 가 밀려도 하드웨어가 60 Hz 로 계속 때린다.  그러니
    #   VBlank 에서 오르는 RAM 카운터를 읽고 **차분**을 더하면 건너뛴 프레임까지
    #   한꺼번에 따라잡는다.  0.5.180 으로 그 카운터를 찾았다 ($201B, FRAME_CLOCK).
    #
    #   ⚠ 문서가 권하던 "CD_SUBQ 의 M:S:F 로 재동기" 는 **쓸 수 없다.**
    #     0.5.178 실측: 게임은 트랙 시작 때 한 번 뜨고 재생 내내 갱신하지 않는다
    #     ($20A0-$20A9 가 f4446 이후 f11700 까지 한 바이트도 안 변했다).
    #     스케줄러가 CD_SUBQ 를 **직접 부르면** 되지만, 결과가 제로페이지
    #     $20A0-$20A9 에 떨어지고 그건 게임도 쓰는 자리라 위험하다.
    #
    #   첫 호출은 elapsed==0 으로 가린다.  거기서 last 만 심고 elapsed=1 로 둔다
    #   -- 이렇게 하면 **무장 코드(native_arm.py, ADPCM 옆)를 안 건드려도 된다.**
    a.abs_(0xBD, 0x2100 + S_ELAPSED)          # LDA elapsed.lo,X
    a.abs_(0x1D, 0x2100 + S_ELAPSED + 1)      # ORA elapsed.hi,X
    a.branch(0xD0, "cdda_clock_run")          # 0 이 아니면 평상시 경로
    #   첫 호출: last = 시계, elapsed = 1
    a.abs_(0xAD, FRAME_CLOCK)
    a.abs_(0x9D, 0x2100 + S_LAST)
    a.emit(0xA9, 0x01); a.abs_(0x9D, 0x2100 + S_ELAPSED)
    a.emit(0x4C); a.word("cdda_no_carry")

    a.label("cdda_clock_run")
    a.abs_(0xAD, FRAME_CLOCK)                 # LDA $201B
    a.emit(0x38)                              # SEC
    a.abs_(0xFD, 0x2100 + S_LAST)             # SBC last,X      -> A = 지난 프레임 수
    a.emit(0x18)                              # CLC
    a.abs_(0x7D, 0x2100 + S_ELAPSED)          # ADC elapsed.lo,X
    a.abs_(0x9D, 0x2100 + S_ELAPSED)          # STA elapsed.lo,X
    a.branch(0x90, "cdda_clock_nc")           # BCC
    a.abs_(0xFE, 0x2100 + S_ELAPSED + 1)      # INC elapsed.hi,X
    a.label("cdda_clock_nc")
    a.abs_(0xAD, FRAME_CLOCK)                 # last = 시계
    a.abs_(0x9D, 0x2100 + S_LAST)
    a.label("cdda_no_carry")

    # part < count ?  아니면(다 썼으면) 종료 처리로
    #
    # ★ 2026-09-05: 여기에 `INC A` 가 있어서 실제로는 **part + 1 < count** 였다.
    #   주석은 처음부터 `part < count` 라고 적혀 있었다 -- 코드가 주석을 안 따랐다.
    #
    #   `part` 는 **다음에 소비할 항목의 번호**이고 (무장 때 0), `count` 는 구간
    #   수가 그대로 들어간다 (native_arm.py:470 "part u8 = 0 · count u8 = 구간 수").
    #   그러면 마지막 항목에서 이렇게 된다:
    #
    #       count=35 · part=33  ->  34 < 35  ✔  항목 33 을 소비
    #                · part=34  ->  35 < 35  ✘  "다 썼다" 로 판단
    #
    #       항목 34(= 35 번째, 마지막)는 **영원히 소비되지 않는다.**
    #
    #   즉 모든 트랙에서 마지막 한 줄이 안 나왔다.  실기 증상과 정확히 맞는다:
    #   트랙 17 의 "스내처(SNATCHER)라 불렀다." 가 끝까지 안 떴고,
    #   ★오버클럭 RetroArch 에서도 그대로였다 -- 드리프트와는 무관한 버그다.
    #
    #   ⚠ ADPCM 원본(native_arm.py:549)도 **같은 형태**다.  거기도 음성마다
    #     마지막 조각을 잃고 있을 수 있다.  다만 "잘되는 ADPCM 은 유지" 방침이라
    #     여기서는 손대지 않는다 -- 별도로 확인할 것.
    #
    # ★★ 2026-09-05, 두 번째: 다 썼다고 **바로 철거하면 안 된다.**
    #
    #   오프바이원을 고쳐 마지막 항목이 심기게 됐는데도 화면에는 여전히 안 떴다.
    #   0.5.179 로 프레임 단위로 재 보니 이랬다:
    #
    #       f12322  sched=7333  record_ptr $16F5AA  ready=00   마지막 항목 심김
    #       f12323  sched=7334  record_ptr $000000  ready=00   철거 시작
    #       f12324  sched=7334  record_ptr $FFFFFF  ready=FF   슬롯 소거
    #
    #   **마지막 레코드가 딱 1 프레임 살았다** (91 프레임 떠 있어야 한다).
    #   `cdda_due` 가 `STZ ready` 를 해 두므로, 그다음 프레임에 `cdda_finished`
    #   의 `LDA ready / BEQ cdda_state3` 가 **첫 프레임에 바로** 걸린다.
    #   2 프레임 유예로 설계된 것이 0 프레임이 된다.
    #
    #   그래서 항목이 소진되면 **아무것도 안 한다.**  elapsed 만 계속 올리고
    #   나간다.  철거는 이미 있는 경로가 한다 -- 이 함수 앞머리에서 매 프레임
    #   트랙 정지($20A2)와 스킵 입력($222D)을 보고 있고, 트랙이 실제로 끝나면
    #   그때 `cdda_finished` 로 간다.  그 시점엔 렌더러가 표시를 마친 뒤라
    #   2 프레임 유예가 제대로 돈다.
    #
    #   ⚠ §11 의 "스킵 뒤 스케줄러가 계속 돌며 게임 RAM 을 덮었다" 는 재발하지
    #     않는다.  그건 `cdda_due` 가 반복해서 stage 31 B 를 쓴 것이었는데,
    #     항목이 소진되면 `cdda_due` 자체가 안 돈다.  여기서 하는 일은
    #     elapsed++ 뿐이다.
    #
    #   여유도 넉넉하다 -- 마지막 구간 7333 뒤로 트랙이 약 570 프레임(9.5 초)
    #   더 돈다.  레코드 표시 91 프레임을 채우고도 남는다.
    a.abs_(0xBD, 0x2100 + S_PART)
    a.abs_(0xDD, 0x2100 + S_COUNT)
    a.branch(0x90, "cdda_has_next")
    a.emit(0x4C); a.word("cdda_drained")   # 다 썼다 -> 마지막 줄의 수명을 센다
    a.label("cdda_has_next")

    # ★ 자리 이사 (2026-09-05) -- 트랙 안에서 base 가 한 번 바뀌는 트랙용 (트랙 3).
    #
    #   왜 여기인가
    #   ----------
    #   `cdda_due` 안에서 하면 STATE=1 이 다음 프레임 `copy_renderer` 를 부르고,
    #   그것이 방금 설정한 ready/record_ptr 를 덮어 **그 구간 자막이 날아간다.**
    #   여기는 "다음 구간이 아직 안 됐다" 를 판정하기 **전**이라, 이사가 먼저
    #   끝난 뒤 그 구간이 평소대로 뜬다.  소유자 지시: 자막을 버리지 않는다.
    #
    #   무엇을 하나
    #   ----------
    #     1  AC 헬퍼 제어블록에 새 base 4 B      (다음 save 가 새 자리를 뜬다)
    #     2  CPU 렌더러 즉치 3 자리에 새 값       (AC 를 안 고쳐도 이 트랙 안에서는
    #                                             다시 무장하지 않으므로 안 덮인다)
    #     3  AC 렌더러 사본의 이사 번호를 0 으로   ★한 번만 돌게 하는 가드
    #     4  STATE = 1
    #
    #   다음 프레임에 상주부가 슬롯을 헬퍼로 바꿔 save 하고 렌더러를 되돌린다.
    #   디스패처는 STATE 1 을 arm_return 으로 흘려보내므로 무장도 스케줄러도
    #   안 돈다 (native_arm: CMP #0 -> arm_idle · CMP #2 -> 그 밖이면 복귀).
    #
    #   ⚠ 가드를 CPU 쪽($5B80+off)에 쓰면 안 된다.  `copy_renderer` 가 AC 에서
    #     다시 퍼오므로 되살아나 매 프레임 이사한다.
    if move_byte_off:
        # ⚠ 이사 본문은 **아래쪽에 떼어 놓고 절대 JSR 로 부른다.**
        #   인라인으로 두었더니 `cdda_move_done` 까지 136 B 라 상대분기(127)가
        #   안 닿았다.  이 파일이 트램폴린을 쓰는 것과 같은 이유다.
        a.abs_(0xAD, base.ENGINE_LO + move_byte_off)   # 이사 번호 (0 = 없음)
        a.branch(0xF0, "cdda_move_skip")
        a.abs_(0xDD, 0x2100 + S_PART)                  # part 와 같은가
        a.branch(0xD0, "cdda_move_skip")
        a.abs_(0x20, "cdda_move")                      # JSR (거리 무관)
        a.label("cdda_move_skip")

    # next entry 의 start_frame(+7) 을 unsigned 비교
    #
    # ★ cdda_due 블록이 원본 sched_due 보다 훨씬 크다 (vram_base 즉치 3 개를
    #   개별로 심느라 ac_ptr_local 을 세 번 부른다 -- 각 37 B 안팎).
    #   원본처럼 "트램폴린 하나를 cdda_due 블록 뒤에" 두면 비교 지점에서
    #   거리가 128 B 를 넘는다 (실측 256).  그래서 트램폴린 둘(not_due·is_due)을
    #   비교 로직 **바로 뒤**에 몰아 두고, 둘 다 짧은 절대 JMP(3 B, 거리 무관)로
    #   보낸다.  fall-through 는 안 쓴다 (트램폴린이 사이에 끼면 깨진다).
    # ★ start_frame 의 항목 안 위치는 형식마다 다르다 (2026-09-04 실기에서 잡힘).
    #
    #     13 B   record_ptr 0..2 · vram 3..5 · flags 6 · start_frame ★7..8
    #      5 B   record_ptr 0..2 ·                       start_frame ★3..4
    #
    #   mini_stride 로 "다음 항목 이동" 과 "vram 생략" 은 나눴는데 이 오프셋을
    #   +7 로 두는 바람에, 5 B 형식에서 **다음 항목의 record_ptr 한복판**을
    #   읽어 영원히 "아직 때가 아니다" 가 됐다 -- 자막이 한 줄도 안 나왔다.
    start_frame_off = 7 if mini_stride >= 13 else 3
    ac_ptr_local(a, 1, S_NEXT, start_frame_off)
    a.abs_(0xAD, 0x1A10); a.abs_(0x9D, 0x2100 + S_START)
    a.abs_(0xAD, 0x1A10); a.abs_(0x9D, 0x2100 + S_START + 1)
    a.abs_(0xBD, 0x2100 + S_ELAPSED + 1); a.abs_(0xDD, 0x2100 + S_START + 1)
    a.branch(0x90, "cdda_not_due_near")   # elapsed.hi < start.hi
    a.branch(0xD0, "cdda_is_due_near")    # elapsed.hi > start.hi
    a.abs_(0xBD, 0x2100 + S_ELAPSED); a.abs_(0xDD, 0x2100 + S_START)
    a.branch(0x90, "cdda_not_due_near")   # hi 같음, elapsed.lo < start.lo
    a.branch(0xB0, "cdda_is_due_near")    # hi 같음, elapsed.lo >= start.lo (BCS)

    a.label("cdda_not_due_near")
    a.emit(0x4C); a.word("cdda_store")
    a.label("cdda_is_due_near")
    a.emit(0x4C); a.word("cdda_due")

    a.label("cdda_due")
    # ★1+2: record_ptr[0:3] 과 vram_base[3:6] 이 mini 항목에서 **연속**이다.
    #   AC 포트는 접근마다 자동 증가한다 (원본 스케줄러가 start_frame 2 B 를
    #   이렇게 읽는다).  포인터를 **한 번만** [0]에 열고, TAI 로 record_ptr
    #   3 B 를 옮긴 뒤(포인터가 자동으로 +3), 곧바로 이어서 vram_base 3 개를
    #   흩뿌린다 -- ac_ptr_local 을 두 번 부르는 것보다 훨씬 짧다.
    ac_ptr_local(a, 1, S_NEXT)
    a.emit(0xF3); a.word(0x1A10); a.word(record_ptr_cpu); a.word(3)
    if mini_stride >= 13:
        # 13 B 항목: vram 즉치가 구간마다 들어 있다 (트랙 17 전용 옛 형식).
        # TAI 뒤 자동증가가 이어지므로 곧바로 세 번 읽는다 (2026-09-04 실기 확인).
        a.abs_(0xAD, 0x1A10); a.abs_(0x8D, vram_hi_cpu)
        a.abs_(0xAD, 0x1A10); a.abs_(0x8D, vram_lo_cpu)
        a.abs_(0xAD, 0x1A10); a.abs_(0x8D, vram_attr_cpu)
    # ★ 5 B 항목에서는 아무것도 안 한다.  vram 은 트랙의 성질이라
    #   cdda_start 가 무장 때 한 번만 심는다 (ADPCM 과 같은 구조).

    # ⚠⚠ 2026-09-04 실기: 여기서 헬퍼 제어블록(AC_HELPER_CTL_BASE)을 구간마다
    #   갱신해 봤다가 **되돌렸다.**  배경이 통째로 깨졌다 (화면 전체가 쓰레기 타일).
    #
    #   이유: 헬퍼는 save 로 원본 VRAM 을 백업했다가 restore 로 되돌린다.
    #   그 **save 와 restore 사이에** base 를 옮기면 $2000 에서 뜬 백업을
    #   $2700 에 쏟아붓는다.  base 는 save/restore 짝과 함께 움직여야 한다.
    #
    #   잔상의 원인 분석 자체는 맞다 -- 헬퍼가 제어블록 base 로 자기 글리프를
    #   지우는데(native_arm.py 2026-09-02 주석), ADPCM 은 음성마다 무장하며
    #   그 값을 받는 반면 CD-DA 는 한 번 무장하고 자리가 39 번 바뀌므로 첫
    #   구간 $2000 말고는 아무도 안 지운다.  다만 고치려면
    #   "옛 자리 restore -> base 이동 -> 새 자리 save" 순서를 지켜야 하고,
    #   제어블록 4 바이트를 쓰는 것만으로는 안 된다.

    # stage 31 B 복원 (glyph 전송이 stage 버퍼를 덮었을 수 있다 -- ADPCM 과 동일 이유)
    if stage_template_ac is not None:
        ac_ptr_const(a, 1, stage_template_ac)
        a.emit(0xF3); a.word(0x1A10); a.word(stage_cpu); a.word(stage_bytes)

    # ★ 2026-09-06: 중간 공백 숨김 항목(record_ptr=$FFFFFF).
    #
    # CD-DA 렌더러는 timed=False라 중간 줄의 frames를 직접 세지 않는다.
    # 따라서 다음 줄까지 긴 공백 사이에 장면이 바뀌면, 이전 스프라이트가
    # 계속 push되다가 게임이 덮은 글리프 VRAM을 가리켜 한 줄 노이즈가 된다.
    # 숨김 항목은 READY_IDLE(bit7)을 써 렌더러만 멈춘다.  READY_SKIPPED와 달리
    # 함수 앞머리의 wait_stop 경로로 가지 않으므로 다음 항목은 정상 예약된다.
    a.abs_(0xAD, record_ptr_cpu + 2)
    a.emit(0xC9, (HIDE_RECORD_PTR >> 16) & 0xFF)
    a.branch(0xF0, "cdda_due_hide")
    a.abs_(0x9C, ready_cpu)
    a.branch(0x80, "cdda_due_ready")
    a.label("cdda_due_hide")
    a.emit(0xA9, READY_IDLE); a.abs_(0x8D, ready_cpu)
    a.label("cdda_due_ready")
    a.abs_(0xFE, 0x2100 + S_PART)
    a.emit(0x18)
    for i in range(3):
        a.abs_(0xBD, 0x2100 + S_NEXT + i)
        a.emit(0x69, mini_stride if i == 0 else 0)
        a.abs_(0x9D, 0x2100 + S_NEXT + i)
    a.emit(0x4C); a.word("cdda_store")

    # ---- 다 썼다: 마지막 줄의 수명을 센다 (2026-09-05) --------------------
    #
    # ★ §21-8 의 열린 문제.  0.5.4 에서 "소진 즉시 철거" 를 빼면서, 마지막 줄을
    #   **아무도 끝내 주지 않게** 됐다.  CD-DA 렌더러는 timed=False 로 구워져
    #   레코드의 frames 를 안 세므로, 자막은 "다음 것이 오거나 ready 에 bit7 이
    #   설 때까지" 떠 있다.  그래서 음성이 끝나고도 9 초쯤 남았다.
    #
    # 왜 트랙 정지 신호로 못 하나 -- 0.5.183 실측:
    #
    #     $20A2   트랙이 끝나도 **끝내 안 변한다**  (지금 쓰는 정지 신호)
    #     $26F9   f13057 에 11 -> 12 로 바뀌지만 마지막 구간에서 560 프레임 뒤다
    #
    #   그리고 마지막 레코드의 표시 길이는 트랙마다 22~382 프레임으로 제각각이라
    #   상수 하나로는 못 맞춘다 (트랙 8 은 0.37 초, 트랙 7 은 6.37 초).
    #
    # 그래서 **레코드가 스스로 말하는 길이**를 쓴다.  렌더러의 record_ptr 은
    # 마지막으로 심은 항목을 그대로 들고 있으므로, 그 레코드의 +4(frames u16)를
    # 읽어 만료 시각을 만든다:
    #
    #     레코드 헤더  cells · width · flags · y · ★frames u16   (+0..+5)
    #     deadline = elapsed + frames
    #
    # 자리는 소진 뒤에 안 쓰는 `S_NEXT` 를 재사용하고, "이미 계산했다" 는
    # `part` 를 count+1 로 올려 표시한다 (count 최대 165 이라 안전하다).
    #
    # 만료되면 `ready = $FE` 를 쓴다.  그러면 렌더러 entry 가 BMI -> RTS 로
    # 화면에서 사라지고, 이 함수 앞머리의 `CMP #$FE -> cdda_wait_stop` 이
    # 이어받아 **트랙이 실제로 끝날 때** STATE=3 을 쓴다.  이미 실기로 검증된
    # 경로를 그대로 탄다 -- 새 정리 경로를 만들지 않는다.
    a.label("cdda_drained")
    a.abs_(0xBD, 0x2100 + S_PART)
    a.abs_(0xDD, 0x2100 + S_COUNT)
    a.branch(0xD0, "cdda_deadline_ready")     # part > count -> 이미 계산됐다
    a.abs_(0xFE, 0x2100 + S_PART)             # 표식: part = count+1
    ac_ptr_ram(a, 1, record_ptr_cpu, 4)       # 팩의 그 레코드 +4 (frames u16)
    a.emit(0x18)                              # CLC
    a.abs_(0xAD, 0x1A10)                      # frames lo
    a.abs_(0x7D, 0x2100 + S_ELAPSED)          # ADC elapsed.lo,X
    a.abs_(0x9D, 0x2100 + S_NEXT)
    a.abs_(0xAD, 0x1A10)                      # frames hi
    a.abs_(0x7D, 0x2100 + S_ELAPSED + 1)      # ADC elapsed.hi,X
    a.abs_(0x9D, 0x2100 + S_NEXT + 1)
    a.emit(0x4C); a.word("cdda_store")

    a.label("cdda_deadline_ready")
    a.abs_(0xBD, 0x2100 + S_ELAPSED + 1)
    a.abs_(0xDD, 0x2100 + S_NEXT + 1)
    a.branch(0x90, "cdda_drain_wait")         # elapsed.hi < deadline.hi
    a.branch(0xD0, "cdda_drain_erase")        # elapsed.hi > deadline.hi
    a.abs_(0xBD, 0x2100 + S_ELAPSED)
    a.abs_(0xDD, 0x2100 + S_NEXT)
    a.branch(0x90, "cdda_drain_wait")
    a.label("cdda_drain_erase")
    # 수명을 다 채웠다.  화면에서 지우고 **여기서 철거까지 한다.**
    #
    # ⚠ `cdda_wait_stop`(트랙 정지를 기다리는 길)에 맡기면 안 된다 -- §21-8
    #   실측에서 트랙이 자연히 끝나도 `$20A2` 가 **끝내 안 변했다.**  그러면
    #   STATE=3 이 영영 안 와서 $5B80 을 안 돌려준다.
    #
    # ★ 0.5.3 의 "소진 즉시 철거" 가 틀렸던 것은 **동작이 아니라 시점**이었다
    #   (레코드를 심은 다음 프레임에 철거해 1 프레임만 살았다).  지금은
    #   레코드가 frames 만큼 다 떠 있은 뒤라 그 시점이 맞다.
    #
    # ready=$FE 를 먼저 쓰므로 이 프레임 entry 는 BMI -> RTS 로 push 를 안 한다.
    # 즉 SAT 에 우리 칸이 없는 상태로 vblank 를 넘긴다 -- §5-0 이 2 단 지연으로
    # 만들려던 조건이 이미 만족돼 있어 STATE=3 을 바로 써도 안전하다
    # (`cdda_stopped` 가 같은 근거로 그렇게 한다).
    #
    # ★★ 2026-09-05 실기 정정: 여기서 STATE=3 까지 쓰면 **지워질 때 노이즈**가
    #   생긴다.  SAT 는 vblank 에 래치되므로, ready 를 내린 그 프레임에 화면에
    #   떠 있는 스프라이트는 **직전 프레임에 민 것**이다.  그 위로 정리가 돌면
    #   복원되는 배경을 글자 모양으로 그린다 (§5-0 과 같은 기전).
    #
    #   그래서 이 프레임엔 지우기만 하고, 철거는 **다음 프레임**에 한다.
    #   ready=$FE 라 다음 프레임엔 앞머리가 `cdda_wait_stop` 으로 보내고,
    #   거기서 part>=count 를 보고 바로 STATE=3 을 쓴다 (아래).
    a.emit(0xA9, READY_SKIPPED); a.abs_(0x8D, ready_cpu)
    a.label("cdda_drain_wait")
    a.emit(0x4C); a.word("cdda_store")

    # ---- 스킵 처리 (2026-09-04) -----------------------------------------
    #
    # 그리기만 멈춘다.  STATE 는 건드리지 않는다 -- 게임이 자기 스킵 절차를
    # 끝낼 때까지 우리는 아무것도 안 한다.
    a.label("cdda_skip")
    a.emit(0xA9, READY_SKIPPED); a.abs_(0x8D, ready_cpu)   # entry 가 BMI -> RTS
    a.emit(0x4C); a.word("cdda_store")

    # 스킵 뒤: CD 가 실제로 멈출 때까지 기다렸다가 그때 정리한다.
    # (0.4.7.7 이 쓰던 시점 그대로.  거기서는 게임이 정상 동작했다)
    a.label("cdda_wait_stop")
    # ★ 항목을 다 쓴 뒤(part >= count)라면 트랙 정지를 기다리지 않는다.
    #   §21-8 실측: 트랙이 자연히 끝나도 `$20A2` 가 **끝내 안 변한다.**
    #   여기까지 왔다는 것은 직전 프레임에 ready 를 내렸다는 뜻이고, 그러면
    #   이번 프레임 SAT 에는 우리 칸이 없다 -- 철거해도 안전하다.
    #   (스킵으로 온 경우는 part < count 라 아래 트랙 검사로 간다)
    a.abs_(0xBD, 0x2100 + S_PART)
    a.abs_(0xDD, 0x2100 + S_COUNT)
    if done_latch_ac is None:
        a.branch(0xB0, "cdda_stopped")
    else:
        # 목록 소진은 이 CD 재생 건의 최종 상태다. 슬롯/state는 아래에서
        # 즉시 반납하되, 게임 RAM이 아닌 CD-DA 전용 AC 틈의 1 B 표식만 남긴다.
        a.branch(0x90, "cdda_wait_track")
        a.label("cdda_mark_done")
        ac_ptr_const(a, 1, done_latch_ac)
        a.emit(0xA9, done_latch_value); a.abs_(0x8D, 0x1A10)
        if done_latch_track_cpu is not None:
            # ★ 2026-09-08 실기: 표식이 트랙을 몰라서 트랙 17 의 표식이
            #   트랙 19 를 통째로 삼켰다.  18->19 는 연속 재생이라 새 CD 요청이
            #   없고, 그래서 표식을 지우는 `cdda_done_request_clear`($F879)가
            #   영영 안 돈다.  서명 옆에 트랙을 같이 남겨 관문이 구별하게 한다.
            #   ac_ptr_const 가 자동증가 1 을 켜므로 다음 바이트로 그냥 들어간다.
            #   ⚠ 반드시 **디렉터리 조회와 같은 키**($26F9 & $7F)를 쓴다.
            a.abs_(0xAD, done_latch_track_cpu)
            a.emit(0x29, 0x7F)
            a.abs_(0x8D, 0x1A10)
        a.emit(0x4C); a.word("cdda_stopped")
        a.label("cdda_wait_track")
    a.abs_(0xAD, CD_SUBQ_TRACK)
    if track_byte_cpu is None:
        a.emit(0xC9, track_bcd)
    else:
        a.abs_(0xCD, track_byte_cpu)
    a.branch(0xD0, "cdda_stopped")
    a.emit(0x4C); a.word("cdda_store")            # 아직 재생 중 -> 그냥 나간다
    a.label("cdda_stopped")
    # ready 가 이미 $FF 라 entry 가 push 를 안 했다 = SAT 에 우리 칸이 없다.
    # 그래서 2 단 지연 없이 바로 STATE=3 을 써도 안전하다 (§5-0 의 그 조건이
    # 이미 만족돼 있다).
    a.emit(0xA9, 0x00 if private_state_cpu is not None else 0x03)
    a.abs_(0x8D, private_state_cpu if private_state_cpu is not None else state_cpu)
    a.emit(0x4C); a.word("cdda_store")

    # ★3: 트랙이 바뀌었다 -- STATE=3 을 즉시 쓰지 않는다.
    # native_arm.py 의 arm_return 과 같은 ready 기반 2 단 지연 (2026-09-03).
    #
    # ★★★ 2026-09-06 실기 정정 -- 국장실 "UI 복귀 실패" 의 원인이 여기였다.
    #
    #   있던 것    LDA ready / BEQ cdda_state3 / STZ ready / BRA
    #
    #   `STZ ready` 로 0 을 만들고 **다음 프레임에 0 을 보면** STATE=3 을 썼다.
    #   그런데 0 은 렌더러가 정상 동작 중에도 쓰는 값이다.  STATE 가 아직 2 라
    #   렌더러는 계속 돌고, 매 프레임 `ready` 를 01 로 되돌린다.  그래서 BEQ 가
    #   **영원히 안 걸린다.**
    #
    #   0.6.0 프로브 실측 (트랙 3, 국장실):
    #
    #       12113  subq 03 -> 04            트랙 3 끝, CD 가 트랙 4 로
    #       12113  ready<-00  pc=EF20       여기 STZ
    #       12114  ready<-00  pc=EF20       또
    #       12115  ready<-00  pc=EF20       또 ... 매 프레임
    #       그 사이 pc=5C95 (렌더러) 가 ready 를 01 로 1,528 회 되돌렸다
    #       -> STATE 는 02 로 굳었고 슬롯 $5B80 이 게임에 안 돌아갔다
    #
    #   ★ 왜 트랙 17 은 멀쩡했나 -- 이 경로를 **안 밟는다.**  §21-8 실측대로
    #     "트랙이 자연히 끝나도 $20A2 가 끝내 안 변한다."  그래서 17 은 소진
    #     경로(cdda_drained -> ready=$FE -> cdda_wait_stop)로 끝난다.
    #     트랙 3 은 끝나면 **트랙 4 로 넘어가서** 이 경로를 처음으로 밟았다.
    #
    #   고침: 0 대신 **$FE(READY_SKIPPED)** 를 쓴다.  이미 검증된 기전이다 --
    #     · 렌더러 entry 가 `BMI -> RTS` 라 그 프레임엔 스프라이트를 안 민다
    #       (2 단 지연이 노린 찢김 방지가 그대로 지켜진다)
    #     · 렌더러가 안 돌므로 **아무도 되돌리지 않는다**
    #     · 다음 프레임 스케줄러 앞머리가 `CMP #$FE` 로 잡아 `cdda_wait_stop`
    #       으로 보내고, 거기서 `part>=count` 또는 트랙 불일치를 보고
    #       `cdda_stopped` 가 STATE=3 을 쓴다
    #
    #   즉 소진 경로와 **같은 길**로 합류시키는 것이다.  +4 B.
    a.label("cdda_finished")
    # ⚠ 2026-09-06 밤 되돌림.  한때 `ready=$FE` 로 바꿨다가(0.5.15) 트랙 3 을
    #   폐기하면서 0.5.10 형태로 복귀했다.  그 수정의 근거와 측정은 인계서 §35-4.
    #
    # ★★★★ 2026-09-06 밤, A안 (인계서 §45-6).  **`ready` 를 안 본다.**
    #
    #   실측(2.3.0 · dump/hq_2_3_0_dispatchgate_20260906_200131.tsv):
    #
    #       매 프레임  EEE5 (cdda_drain_erase)  ready 01 -> FE   306 회
    #                  5C95 (렌더러 push)       ready FE -> 01   306 회  ★되돌린다
    #       트랙 끝    cdda_finished 10 회 전부 ready=01 -> BEQ 불성립 -> STATE=3 못 씀
    #
    #   `ready`(+326)는 **슬롯 안**이고, 그 값을 매 프레임 되돌리는 `push`(+277)도
    #   슬롯 안이다.  35.37 초에 게임이 entry(+3~+8)를 덮으면 `BMI -> RTS` 안전장치가
    #   사라져서 `$FE` 로도 못 멈춘다 -- **0.5.15 가 실패한 이유가 이것이다.**
    #
    #   그래서 판정을 **경합 없는 자리**로 옮긴다.  `part`/`count` 는 `$2100 + S_*`
    #   (스케줄러 자기 상태) 라 게임도 렌더러도 안 건드린다.
    #
    #       part <  count   아직 그리는 중인데 트랙이 바뀌었다 (스킵 등)
    #                       -> 옛 2 단 지연 그대로 둔다.  회귀를 최소화한다
    #       part == count   레코드를 다 심었다.  아직 cdda_drained 의 표식 전이다
    #                       -> 마찬가지로 옛 경로
    #       part >  count   ★cdda_drained 가 `part = count+1` 을 이미 썼다.
    #                       = 마지막 레코드가 수명을 다 채웠고 직전 프레임에
    #                         ready 를 내렸다 = SAT 에 우리 칸이 없다
    #                       -> `cdda_stopped` 와 **같은 근거**로 바로 STATE=3
    #
    #   ⚠ 이것은 진행 불가를 푸는 고침이지 자막을 살리는 고침이 아니다.
    #     35.37 초 이후 렌더러는 여전히 망가진 자리에서 돈다 (§40 재배치가 할 일).
    a.abs_(0xBD, 0x2100 + S_PART)
    a.abs_(0xDD, 0x2100 + S_COUNT)
    a.branch(0xF0, "cdda_finished_old")     # part == count -> 옛 경로
    a.branch(0xB0, "cdda_state3")           # part >  count -> ★바로 STATE=3
    a.label("cdda_finished_old")
    a.abs_(0xAD, ready_cpu)
    a.branch(0xF0, "cdda_state3")          # 이미 0 = 두 번째 프레임이다
    a.abs_(0x9C, ready_cpu)                # STZ ready -- 이번엔 state 유지
    a.branch(0x80, "cdda_store")
    a.label("cdda_state3")
    a.emit(0xA9, 0x00 if private_state_cpu is not None else 0x03)
    a.abs_(0x8D, private_state_cpu if private_state_cpu is not None else state_cpu)

    a.label("cdda_store")
    ac_ptr_const(a, 1, AC_SCHED)
    for i in range(S_PERSIST):
        a.abs_(0xBD, 0x2100 + S_ELAPSED + i); a.abs_(0x8D, 0x1A10)
    for _ in range(S_LOCALS_CDDA):
        a.emit(0x68)
    for i in reversed(range(8)):
        a.emit(0x68); a.abs_(0x8D, 0x1A12 + i)
    a.emit(0x60)   # RTS

    # ★ 이사 본문.  위 RTS 뒤라 흘러들 일이 없다 -- JSR 로만 닿는다.
    if move_byte_off:
        a.label("cdda_move")
        # ★★★ 2026-09-06 저녁.  **자리 바꾸기를 뺐다.  재무장만 남긴다.**
        #
        #   왜 -- 이사의 자리 바꾸기는 실효가 없었고 해만 있었다 (0.9.0 실측):
        #
        #       hi<-6B@EFE3     이사가 CPU 즉치에 새 값을 쓴다
        #       STATE<-01@F025  재무장 요청
        #       hi<-4B@7FC3     ★상주부의 재복사가 옛 값으로 되돌린다
        #
        #     렌더러 즉치는 CPU 에만 써서 재복사가 덮고, 헬퍼 제어블록은 AC 에
        #     써서 살아남는다.  그래서 **헬퍼는 새 자리를 지우고 렌더러는 옛
        #     자리에 그리는** 엇갈림만 남았다.  0.5.19 에서 이 두 쓰기를 빼자
        #     화면 깨짐이 사라졌다 (실기 확인).
        #
        #   그런데 0.5.19 는 **진행이 죽었다.**  0.5.18 과 비교하면 같이 사라진
        #   것이 하나 더 있다 -- `STATE=1` 이 부르는 상주부의 **ENTRY(save)**,
        #   즉 **VRAM 백업 갱신**이다:
        #
        #       상주부 STATE=1:  헬퍼 복사 -> ★ENTRY(save) -> 렌더러 복사 -> STATE=2
        #
        #     0.5.18 은 17.58 초에 백업을 새로 떴고, 0.5.19 는 무장 시점(0 초)
        #     백업 하나로 65 초를 갔다.  이미 겪은 병이다:
        #
        #       SNATCHER_ENV_A_HANDOFF_2026-08-31
        #         0.5.76  복원을 건너뜀            -> 여전히 깨짐
        #         0.5.77  ★백업 내용만 최신화      -> 정상
        #
        #   그래서 이 블록은 이제 **"중간 백업 갱신"** 이다.  자리는 안 바꾼다.
        #   디렉터리의 새 base(+14)는 무시된다 -- 자리는 트랙 내내 하나다.
        #
        #   ⚠ 이름은 cdda_move 로 둔다.  디렉터리 형식과 스케줄러 진입 조건을
        #     안 건드리려는 것이다.  하는 일이 바뀌었을 뿐이다.

        # 1) 가드 -- AC 렌더러 사본의 이사 번호를 0 으로 (한 번만 돈다)
        ac_ptr_const(a, 1, AC_ENGINE + move_byte_off)
        a.emit(0xA9, 0x00); a.abs_(0x8D, 0x1A10)

        # 2) STATE = 1 -> 다음 프레임 상주부가 헬퍼를 올리고 **백업을 다시 뜬다**
        a.emit(0xA9, 0x01); a.abs_(0x8D, state_cpu)
        a.emit(0x60)   # RTS

    return a.finish(), a.labels


# 스케줄러를 놓을 후보 자리.
#
# 2026-09-04 오전: "빌린 RAM 꼬리 537 B 에 넣는다" 로 갔다가 **같은 날 정정**했다.
#   $5B80-$5E3F 는 대사 레코드 캐시(704 B)이고 $5E40 은 선적재 루틴이다.
#   저장/복원 없이 쓸 수 있는 건 렌더러 뒤 89 B 뿐이라 467 B 가 안 들어간다.
#
# 같은 날 뱅크1 을 다시 재서 **여유가 386 B 가 아니라 1,938 B** 임을 알아냈다
#   (BANK1_FREE 는 빈 자리의 일부만 청구하고 있었다).  그래서 뱅크로 되돌아온다 --
#   단 BANK1_FREE 꼬리(386 B)가 아니라 **아직 아무도 안 쓰는 다른 구간**에.
#   자세한 것은 SNATCHER_ENV_B_20260904_CDDA_BANK_BUDGET.md §7-§8.
#
#   어느 자리도 아직 런타임으로 죽었다고 확인되지 않았다.
#   그래서 이 도구는 **재기만 한다** -- 어느 쪽이든 조립되는지, 몇 바이트인지.
ORIGINS = {
    # ★ 뱅크1 의 첫째 미청구 구간.  감사가 가장 깨끗하다
    #   (실행 0 · 데이터 0 · 직접참조 0 건).  0.4.7.1 기준.
    "bankA": (0xECF9, 0xF04D, "뱅크1 $ECF9 미청구 구간  [감사 최상]"),
    # 뱅크1 의 셋째 구간.  patch_bios_cpu_cache 가 165 B 쓰고 남은 자리.
    # 직접참조 1 건($E86B JSR $FE92)이 남아 있으나, **바로 앞 $FC7A 에 우리
    # 코드가 이미 출하돼 정상 동작 중**이라는 실전 근거가 있다.
    "bankB": (0xFD1F, 0xFFD9, "뱅크1 $FD1F 구간 (cpu_cache 뒤)  [실전 이웃]"),
    # ⚠ 빌린 RAM 꼬리.  **처음 생각보다 훨씬 좁다** (2026-09-04 정정).
    #   $5B80-$5E3F 는 대사 레코드 캐시(704 B)이고, $5E40 은 **선적재 루틴**이다
    #   (extraction/patch/static/build_ac_dynamic_0_1_14.py:17
    #    "...the $5E40 preloader ... are all untouched").
    #   lifecycle POC 가 $5B80-$5FFF 를 통째로 빌릴 때 AC 저장/복원을 한 이유가
    #   바로 이것이다.  저장/복원 없이 쓸 수 있는 건 렌더러 뒤 89 B 뿐이다.
    "ram":   (0x5DE7, 0x5E3F, "빌린 RAM 꼬리 -- ★$5E40 선적재 앞까지만"),
}


def main() -> None:
    import argparse
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--origin", choices=(*ORIGINS, "all"), default="all")
    args = ap.parse_args()

    labels = load_renderer_offsets()
    CPU = 0x5B80   # 엔진 슬롯 시작 (build_subtitle_engine.py 의 ENGINE_LO 와 동일)

    kwargs = dict(
        ready_cpu=CPU + labels["ready"],
        record_ptr_cpu=CPU + labels["record_ptr"],
        vram_hi_cpu=CPU + labels["vram_base_hi_imm"],
        vram_lo_cpu=CPU + labels["pattern_base_lo_imm"],
        vram_attr_cpu=CPU + labels["pattern_attr_imm"],
        # ★ 스케줄 연동판 렌더러가 AC_CDDA_TEMPLATE 자리에 실린다.
        #   stage 원본도 같은 이미지 안에 있으므로 이 계산이 맞다.
        stage_cpu=CPU + labels["stage"],
        stage_template_ac=0x1FE800 + labels["stage"],
        stage_bytes=31,
    )

    print("렌더러 오프셋 (CPU 절대주소)")
    for k, v in kwargs.items():
        if isinstance(v, int) and v < 0x10000:
            print(f"   {k:20s} = ${v:04X}")
        else:
            print(f"   {k:20s} = {v}")
    print()

    want = ORIGINS if args.origin == "all" else {args.origin: ORIGINS[args.origin]}
    for name, (lo, hi, note) in want.items():
        room = hi - lo + 1
        try:
            first, lb1 = build_scheduler_cdda(lo, None, **kwargs)
            code, lb2 = build_scheduler_cdda(lo, lb1, **kwargs)
        except SystemExit as exc:            # 분기 거리 초과 등
            print(f"[{name}] ${lo:04X}-${hi:04X}  {note}")
            print(f"   ★ 조립 실패: {exc}")
            print()
            continue
        if len(first) != len(code):
            raise SystemExit(f"[{name}] 2-pass 크기 불일치: {len(first)} vs {len(code)}")

        fits = len(code) <= room
        print(f"[{name}] ${lo:04X}-${hi:04X}  {room} B   {note}")
        print(f"   scheduler_cdda {len(code)} B  ->  "
              f"{'들어간다 (여유 %d B)' % (room - len(code)) if fits else '★넘친다 (%d B 초과)' % (len(code) - room)}")
        for label in ("cdda_due", "cdda_finished", "cdda_state3", "cdda_store"):
            off = lb2.get(label)
            if off is not None:
                print(f"      {label:16s} ${off:04X}  (+{off - lo})")
        print()

    print("⚠ 어느 자리도 아직 런타임으로 죽었다고 확인되지 않았다.")
    print("  감사: python tools/audit_bios_free_space.py 0.4.7.1 <lo> <hi> --bank 1")
    print("  프로브: lua/SUB/0.5.165-borrow-tail-alive.lua")


if __name__ == "__main__":
    main()
