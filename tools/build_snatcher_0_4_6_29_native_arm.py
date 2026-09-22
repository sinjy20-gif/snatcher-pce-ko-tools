#!/usr/bin/env python3
"""0.4.6.39: D000 3조각 native frame scheduler POC.

Lua는 정적 AC 데이터 업로드만 담당한다. 음성 식별, 자막 route 조회,
mini index 복사, 첫 selector 설치, state=1과 90/180f selector 전환을 BIOS가 수행한다.
"""
from __future__ import annotations

import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_snatcher_0_4_7_0_lba_probe as base  # noqa: E402
import subtitle_layout as layout  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
CUT = ROOT / "build" / "cutscene_subs"
MASTER = CUT / "adpcm_lba_master_index.bin"
DIR = CUT / "adpcm_native_subtitle_dir.bin"
PAYLOAD = CUT / "adpcm_native_subtitle_payload.bin"
TABLE_INFO = CUT / "adpcm_native_subtitle_table.json"
ENGINE_INFO = CUT / "engine_ac_lua_frame_rearm.json"

VERSION = "0.4.6.39"
BUILD_ID = 39
FEC4 = 0xFEC4
FEC4_RET = 0xFEC6                         # JSR $FEC4가 스택에 미는 복귀 주소
FEC4_ORIG = bytes((0xAD, 0xDF, 0x7F))       # LDA $7FDF
STATE = 0x7FDF
AC_SLOT = 0x1F2700
AC_DIR = 0x1F2800
AC_MASTER = layout.AC_ADPCM_LBA_MASTER  # pack preload 행의 뒷부분
AC_MINI = 0x1EF000
AC_ENGINE = 0x1F1F00
AC_ENGINE_TEMPLATE = 0x1FE400   # ★ 엔진 원본이 실제로 놓이는 자리.
                                #   preload 가 여기서 읽어 간다 -- 옮길 땐 이 한 줄만 고친다.
AC_HELPER_CTL_BASE = 0x1F1C00 + 432 + 4
ST_FOUND, ST_CONSUMED = 0xA1, 0xA2
TARGET_LBA = 0x003083                 # D000 native selector/state POC
AC_SCHED = 0x1F2710                   # slot 뒤, directory 전의 persistent 7 B

# scheduler stack locals. persistent 원본은 AC_SCHED의
# elapsed u16 · part u8 · count u8 · next pointer u24 순서다.
S_ELAPSED, S_PART, S_COUNT, S_NEXT, S_START = 1, 3, 4, 5, 8
S_LOCALS = 9

# stack locals ($2100+n,X)
#
# 2026-09-02: ENTRY 가 6 -> 9 B 가 됐다 (디렉터리에 VRAM 자리 3 B 가 붙었다).
# 재생 중인 음성의 LBA 를 담을 WANT 3 B 도 새로 필요하다 -- 예전에는 이분 검색이
# 상수 TARGET_LBA 를 찾았기 때문에 담을 곳이 없었다.
#
#   ENTRY+0..2  start_lba u24 BE      ENTRY+3..5  payload ptr u24 LE
#   ENTRY+6..8  vram_hi · pat_lo · pat_attr
LO, HI, MID, T, ENTRY, PROBE, TOTAL, CH1SAVE, WANT = 1, 3, 5, 7, 9, 18, 19, 21, 29
LOCALS = 32
DIR_STRIDE = 9                # build_adpcm_native_subtitle_table.py 와 같아야 한다


def ac_ptr_const(a, port: int, addr: int) -> None:
    # Arcade Card channel stride는 $10이다: port0=$1A00, port1=$1A10.
    p = 0x1A00 + port * 0x10
    for shift, reg in ((0, p + 2), (8, p + 3), (16, p + 4)):
        a.emit(0xA9, (addr >> shift) & 0xFF); a.abs_(0x8D, reg)
    a.emit(0xA9, 0x01); a.abs_(0x8D, p + 7)
    a.abs_(0x9C, p + 8)
    a.emit(0xA9, 0x11); a.abs_(0x8D, p + 9)


def ac_ptr_local(a, port: int, local: int, add: int = 0) -> None:
    p = 0x1A00 + port * 0x10
    a.emit(0x18)
    for i, reg in enumerate((p + 2, p + 3, p + 4)):
        a.abs_(0xBD, 0x2100 + local + i)
        a.emit(0x69, add if i == 0 else 0)
        a.abs_(0x8D, reg)
    a.emit(0xA9, 0x01); a.abs_(0x8D, p + 7)
    a.abs_(0x9C, p + 8)
    a.emit(0xA9, 0x11); a.abs_(0x8D, p + 9)


def ac_ptr_ram(a, port: int, address: int, add: int = 0) -> None:
    """CPU RAM의 u24 pointer(+작은 상수)를 Arcade Card port에 건다."""
    p = 0x1A00 + port * 0x10
    a.emit(0x18)
    for i, reg in enumerate((p + 2, p + 3, p + 4)):
        a.abs_(0xAD, address + i)
        a.emit(0x69, add if i == 0 else 0)
        a.abs_(0x8D, reg)
    a.emit(0xA9, 0x01); a.abs_(0x8D, p + 7)
    a.abs_(0x9C, p + 8)
    a.emit(0xA9, 0x11); a.abs_(0x8D, p + 9)


def make_armer(index_count: int, selector_ac: int, engine_bytes: int,
               ready_cpu: int, selector_cpu: int, stage_cpu: int,
               stage_offset: int, stage_bytes: int, *,
               cdda_template_ac: int | None = None,
               cdda_engine_bytes: int = 0,
               cdda_signature_offset: int = 0,
               cdda_signature: int = 0x38,
               cdda_track_raw: int = 0x11,
               cdda_active_sentinel: int | None = None,
               # ★ 2026-09-04 신설.  기본 None/0 = 꺼짐이고, 꺼져 있으면
               #   emit 결과가 지금까지와 **바이트까지 같다**
               #   (tools/verify_adpcm_untouched.py 가 매번 증명한다).
               cdda_mini_ac: int | None = None,
               cdda_mini_count: int = 0,
               cdda_scheduler_at: int | None = None,
               # ★ 2026-09-04 밤: 전 트랙 연결.  기본 None = 꺼짐.
               #   주면 cdda_check 가 트랙 디렉터리를 선형 검색하고,
               #   cdda_start 가 그 트랙의 count/mini/vram 을 심는다.
               cdda_dir_ac: int | None = None,
               cdda_dir_count: int = 0,
               cdda_dir_stride: int = 16,
               cdda_track_byte_off: int = 0,   # 렌더러 패딩 안 BCD 자리
               # 렌더러 패딩 안 **이사 기록** 자리 (2 B: 구간 번호 · 새 base hi).
               # 0 이면 안 심는다 -- 지금까지의 경로와 바이트 동일하다.
               cdda_move_byte_off: int = 0,
               # ★ CD-DA 렌더러의 즉치 오프셋.  **ADPCM 것과 다르다.**
               #   2026-09-04: 이걸 안 나누고 imm_offsets(ADPCM)를 그대로 써서
               #   CD-DA 렌더러 코드를 엉뚱한 자리에서 뭉갰다 -- 자막이 아예
               #   안 나왔다.  ADPCM +289/+294/... vs CD-DA +203/+238/+243.
               cdda_imm_offsets: tuple[int, int, int] | None = None,
               precopy_cpu: bool = True,
               complete_decision: bool = False,
               # CD-DA ROM 상주판(2026-09-06).  모두 None이면 아래 경로는
               # 한 바이트도 방출하지 않아 기존 ADPCM/슬롯형 CD-DA 빌드와 같다.
               cdda_rom_entry: int | None = None,
               cdda_state_cpu: int | None = None,
               cdda_ready_cpu: int | None = None,
               cdda_blank_cpu: int | None = None,
               cdda_count_cpu: int | None = None,
               cdda_track_cpu: int | None = None,
               # ★ 2026-09-07 신설: **같은 트랙 재무장 걸쇠**
               #   (CD_SUBQ 트랙 $20A2, 무장된 트랙 $5E1B).  둘 다 BCD 다.
               #   None = 꺼짐이고, 꺼져 있으면 emit 결과가 지금까지와 바이트까지
               #   같다 (verify_adpcm_untouched.py 가 증명한다).
               #
               #   왜 필요한가 -- 2026-09-07 Mednafen 디버거 실측:
               #   ```
               #   t= 0.00  F9DC  무장 (state=2)
               #   t=25.64  FF59  철거 (state=0)   자막 6줄을 다 썼다
               #   t=25.65  F9DC  ★재무장          0.014 초 뒤.  한 프레임도 안 된다
               #   ```
               #   `state==2` 인 동안만 무장 관문이 닫혀 있다 ($F399 의 프레임
               #   분기).  철거가 state=0 을 쓰는 순간 관문이 도로 열리는데,
               #   **트랙은 아직 재생 중이다** (트랙 20: 자막 25.5 초 / 음악 29.7 초).
               #   그래서 다음 프레임에 같은 트랙을 다시 문다.  두 번째 자막
               #   묶음은 12.9 초 뒤에 그려지므로 이미 다음 장면 위다 -- 남의
               #   VRAM 자리에 글자를 쓴다.
               #
               #   걸쇠는 `patch_bios_cdda_rom_resident.py` 가 이미 세워 두는 두
               #   바이트를 읽기만 한다.  시간을 안 재므로 $201B 가 8 비트라
               #   4.27 초에 한 바퀴 도는 문제와 무관하다.
               cdda_replay_latch: tuple[int, int] | None = None,
               # ★ 같은 "재생 건"의 자연 소진 뒤 재무장만 막는 전용 AC 1 B.
               # 실제 CD-DA 요청 상태(1)의 초기화 경로가 먼저 0으로 지우므로
               # 정상적인 새 재생은 같은 트랙이어도 통과한다. None이면 바이트 동일.
               cdda_done_latch_ac: int | None = None,
               cdda_done_latch_value: int = 0xA5,
               # 표식 서명 바로 뒤 1 B 에 실린 "표식을 찍은 트랙" 을 지금
               # 트랙과 비교할 주소 (CD_SUBQ $20A2).  주면 다른 트랙은 통과한다.
               # None 이면 바이트 동일 -- rc12 와 같은 동작.
               cdda_done_latch_track: int | None = None,
               cdda_imm_cpus: tuple[int, int, int] | None = None,
               imm_offsets: tuple[int, int, int] | None = None,
               # ADPCM 활성 슬롯의 꼬리 지문. 정확히 일치하면 직전 슬롯도
               # 같은 ADPCM template이라고 확정하고 671 B AC->AC 복사를
               # 건너뛴다. 기본 None은 기존 바이트를 그대로 보존한다.
               adpcm_reuse_signature_offset: int | None = None,
               adpcm_reuse_signature: bytes | None = None,
               adpcm_initial_delay: bool = False,
               adpcm_force_release_after_frames: int | None = None):
    # imm_offsets = 엔진 이미지 안 (vram_base_hi_imm, pattern_base_lo_imm,
    # pattern_attr_imm) 오프셋.  주면 음성마다 그 3 B 를 디렉터리 값으로 덮어
    # **전체 키를 무장**한다.  안 주면 예전처럼 D000 하나만 연다.
    def emit(a) -> None:
        # 안전 기준선 0.4.6.31과 동일하다. native가 state=0에서만 arming한 뒤
        # FEC7의 기존 BIOS 판정 루틴으로 복귀한다. 0.4.6.32/33의 RTS 우회는 없다.
        # CD-DA ROM 상주판은 STATE를 전혀 쓰지 않는다.  ADPCM이 활성화돼 있으면
        # 원래 STATE 경로가 우선이며, 끝난 뒤 CD-DA가 다시 렌더링을 이어 간다.
        if cdda_rom_entry is not None:
            if None in (cdda_state_cpu, cdda_ready_cpu, cdda_blank_cpu,
                        cdda_count_cpu, cdda_track_cpu, cdda_imm_cpus):
                raise ValueError("ROM CD-DA에 필요한 RAM 주소가 빠졌다")
            a.abs_(0xAD, STATE)
            a.branch(0xD0, "rom_cdda_normal_state")
            a.abs_(0xAD, cdda_state_cpu)
            a.emit(0xC9, 0x01); a.branch(0xD0, "rom_cdda_not_init")
            a.label("rom_cdda_init_near")
            a.emit(0x4C); a.word("rom_cdda_init")
            a.label("rom_cdda_not_init")
            a.emit(0xC9, 0x02); a.branch(0xF0, "cdda_sched_near")
            # 전원 직후와 게임의 공유 RAM 쓰기 때문에 private state가 FF 등
            # 0/1/2 밖의 값일 수 있다. 그것을 idle로 정규화할 때 전용 AC
            # 완료 표식도 지운다. 자연 소진 뒤 state=0은 이 길을 안 밟는다.
            a.emit(0xC9, 0x00); a.branch(0xF0, "rom_cdda_normal_state")
            a.abs_(0x9C, cdda_state_cpu)
            if cdda_done_latch_ac is not None:
                a.label("cdda_done_boot_clear")
                ac_ptr_const(a, 0, cdda_done_latch_ac)
                a.abs_(0x9C, 0x1A00)
            a.label("rom_cdda_normal_state")
        a.abs_(0xAD, STATE)
        if complete_decision:
            # FEC4 뒤의 legacy BIOS 판정을 실행하지 않는 완결형 경로다.
            # preload/reset의 $FF/$FE 의미도 기존 decision과 동일하게 보존한다.
            a.emit(0xC9, 0xFF); a.branch(0xD0, "decision_check_fe")
            a.abs_(0x9C, STATE)
            a.emit(0xA9, 0x00, 0x48, 0xA9, 0x00, 0x4C); a.word(base.EXIT_BRIDGE)
            a.label("decision_check_fe")
            a.emit(0xC9, 0xFE); a.branch(0xD0, "decision_check_idle")
            a.emit(0xA9, 0x00, 0x48, 0xA9, 0x00, 0x4C); a.word(base.EXIT_BRIDGE)
            a.label("decision_check_idle")
        a.emit(0xC9, 0x00); a.branch(0xF0, "arm_idle")
        # state 1은 같은 resident 호출 안에서 engine copy 뒤 state 2가 된다.
        # 다음 프레임 FEC4가 실제로 보는 active 값은 2다 (0.5.57 실기).
        a.emit(0xC9, 0x02); a.branch(0xD0, "arm_return_near")
        if cdda_template_ac is not None:
            # 통합판의 active slot은 둘 중 하나다. 성공판 CD-DA 엔진의 timer
            # 첫 opcode(SEC=$38)를 직접 확인해 CD-DA에는 ADPCM scheduler를
            # 적용하지 않는다. ADPCM template은 이 자리까지 FF로 덮는다.
            a.abs_(0xAD, 0x5B80 + cdda_signature_offset)
            a.emit(0xC9, cdda_signature)
            # ★ 2026-09-04: CD-DA 도 스케줄러를 갖게 됐다.
            #   지금까지는 CD-DA 면 스케줄러를 통째로 건너뛰었다 (엔진이 자기
            #   타이머로 문턱 3 개를 직접 셌기 때문).  스케줄 연동판은 타이머가
            #   없고 39 구간을 표로 걷는다 -- 그래서 전용 스케줄러로 보낸다.
            #   cdda_scheduler_at 을 안 주면 예전처럼 건너뛴다 (바이트 동일).
            if cdda_scheduler_at is not None:
                target = "cdda_sched_near"
            elif cdda_active_sentinel is not None:
                target = "cdda_active_near"
            else:
                target = "arm_return_near"
            a.branch(0xF0, target)
        a.emit(0x4C); a.word("scheduler")
        a.label("arm_return_near"); a.emit(0x4C); a.word("arm_return")
        if cdda_template_ac is not None and cdda_scheduler_at is not None:
            # 스케줄러는 BANK1_FREE 밖(예: $ECF9)에 따로 심긴다 -- 디스패처
            # 블롭에 안 들어간다.  그래서 절대 JSR 로 부르고 돌아온다.
            # 심는 쪽은 tools/patch_bios_cdda_scheduler.py 다.
            a.label("cdda_sched_near")
            a.abs_(0x20, cdda_scheduler_at)          # JSR scheduler_cdda
            if cdda_rom_entry is not None:
                # 스케줄러가 종료하면 상태를 0으로 내린다. 그 프레임에는 ROM
                # 렌더러를 부르지 않아, 끝난 CD-DA가 SAT에 다시 밀리지 않는다.
                a.abs_(0xAD, cdda_state_cpu)
                a.emit(0xC9, 0x02); a.branch(0xD0, "arm_return_near")
                a.abs_(0x20, cdda_rom_entry)
            a.emit(0x4C); a.word("arm_return")
        if cdda_active_sentinel is not None:
            # FEC7의 legacy active 분기는 $180D ADPCM playing bit가 없으면
            # state 3을 쓴다. CD-DA만 odd=0 sentinel로 그 분기를 건너뛰고,
            # resident의 BIT #$01 active 판정으로 직접 보낸다.
            a.label("cdda_active_near")
            a.emit(0xA9, cdda_active_sentinel, 0x48, 0xA9, 0x00)
            a.emit(0x4C); a.word(base.EXIT_BRIDGE)
        a.label("arm_idle")
        ac_ptr_const(a, 0, AC_SLOT)
        a.abs_(0xAD, 0x1A00); a.emit(0xC9, ST_FOUND)
        a.branch(0xF0, "arm_new_hit")
        a.emit(0x4C); a.word("cdda_check" if cdda_template_ac is not None else "arm_return")
        a.label("arm_new_hit")

        # 이 음성은 한 번만 처리한다. miss여도 매 프레임 재검색하지 않는다.
        ac_ptr_const(a, 0, AC_SLOT)
        a.emit(0xA9, ST_CONSUMED); a.abs_(0x8D, 0x1A00)

        # 2026-09-02: D000 관문을 뺐다.  디렉터리가 음성마다 VRAM 자리를 실어
        # 오므로 더 이상 검증된 한 키에 묶일 이유가 없다.
        #   옛 코드: 감지 LBA 를 TARGET_LBA 와 3 B 비교하고 다르면 arm_return
        #   새 코드: 감지 LBA 를 WANT 에 담아 이분 검색이 그것을 찾는다
        # arm_target_ok0 라벨은 남긴다 -- build_subtitle_isolated_test_variants.py
        # 가 consume 시퀀스를 찾는 경계로 쓴다.
        a.label("arm_target_ok0")

        for _ in range(LOCALS): a.emit(0x48)
        a.emit(0xBA)  # TSX

        # 지금 재생 중인 음성의 시작 LBA 3 B (SCSI CDB 순서 그대로)
        a.label("arm_target_ok1")
        ac_ptr_const(a, 0, AC_SLOT + 1)
        for i in range(3):
            a.abs_(0xAD, 0x1A00); a.abs_(0x9D, 0x2100 + WANT + i)
        a.label("arm_target_ok2")
        # lo=0, hi=count-1, probes=0
        a.emit(0xA9, 0); a.abs_(0x9D, 0x2100 + LO); a.abs_(0x9D, 0x2100 + LO + 1)
        a.emit(0xA9, (index_count - 1) & 0xFF); a.abs_(0x9D, 0x2100 + HI)
        a.emit(0xA9, (index_count - 1) >> 8); a.abs_(0x9D, 0x2100 + HI + 1)
        a.emit(0xA9, 0); a.abs_(0x9D, 0x2100 + PROBE)

        a.label("arm_loop")
        a.abs_(0xBD, 0x2100 + PROBE); a.emit(0x1A); a.abs_(0x9D, 0x2100 + PROBE)
        a.emit(0xC9, 12); a.branch(0x90, "arm_range")
        a.emit(0x4C); a.word("arm_miss")
        a.label("arm_range")
        # hi < lo
        a.abs_(0xBD, 0x2100 + HI + 1); a.abs_(0xDD, 0x2100 + LO + 1)
        a.branch(0x90, "arm_miss_near"); a.branch(0xD0, "arm_mid")
        a.abs_(0xBD, 0x2100 + HI); a.abs_(0xDD, 0x2100 + LO)
        a.branch(0xB0, "arm_mid")
        a.label("arm_miss_near"); a.emit(0x4C); a.word("arm_miss")

        a.label("arm_mid")
        # mid=(lo+hi)>>1
        a.emit(0x18)
        a.abs_(0xBD, 0x2100 + LO); a.abs_(0x7D, 0x2100 + HI); a.abs_(0x9D, 0x2100 + MID)
        a.abs_(0xBD, 0x2100 + LO + 1); a.abs_(0x7D, 0x2100 + HI + 1); a.abs_(0x9D, 0x2100 + MID + 1)
        a.abs_(0x5E, 0x2100 + MID + 1); a.abs_(0x7E, 0x2100 + MID)
        # T=mid*9: mid -> *2 -> *2 -> *2 (=*8) -> +mid
        a.abs_(0xBD, 0x2100 + MID); a.abs_(0x9D, 0x2100 + T)
        a.abs_(0xBD, 0x2100 + MID + 1); a.abs_(0x9D, 0x2100 + T + 1)
        for _ in range(3):
            a.abs_(0x1E, 0x2100 + T); a.abs_(0x3E, 0x2100 + T + 1)
        a.emit(0x18)
        a.abs_(0xBD, 0x2100 + T); a.abs_(0x7D, 0x2100 + MID); a.abs_(0x9D, 0x2100 + T)
        a.abs_(0xBD, 0x2100 + T + 1); a.abs_(0x7D, 0x2100 + MID + 1); a.abs_(0x9D, 0x2100 + T + 1)

        # AC_DIR+T에서 9 B 읽기 (LBA 3 + payload ptr 3 + VRAM 즉치값 3)
        base.ac_ptr_from_T(a, AC_DIR)
        for i in range(DIR_STRIDE):
            a.abs_(0xAD, 0x1A00); a.abs_(0x9D, 0x2100 + ENTRY + i)
        # 상수가 아니라 **지금 재생 중인 LBA**(WANT)와 비교한다
        for i in range(3):
            a.abs_(0xBD, 0x2100 + ENTRY + i); a.abs_(0xDD, 0x2100 + WANT + i)
            a.branch(0xD0, f"arm_neq{i}")
        a.emit(0x4C); a.word("arm_found")
        for i in range(3):
            a.label(f"arm_neq{i}")
            a.branch(0x90, "arm_go_lo")
            a.branch(0x80, "arm_go_hi")

        a.label("arm_go_lo")
        a.emit(0x18)
        a.abs_(0xBD, 0x2100 + MID); a.emit(0x69, 1); a.abs_(0x9D, 0x2100 + LO)
        a.abs_(0xBD, 0x2100 + MID + 1); a.emit(0x69, 0); a.abs_(0x9D, 0x2100 + LO + 1)
        a.emit(0x4C); a.word("arm_loop")

        a.label("arm_go_hi")
        a.abs_(0xBD, 0x2100 + MID); a.abs_(0x1D, 0x2100 + MID + 1)
        a.branch(0xD0, "arm_hi_ok"); a.emit(0x4C); a.word("arm_miss")
        a.label("arm_hi_ok")
        a.emit(0x38)
        a.abs_(0xBD, 0x2100 + MID); a.emit(0xE9, 1); a.abs_(0x9D, 0x2100 + HI)
        a.abs_(0xBD, 0x2100 + MID + 1); a.emit(0xE9, 0); a.abs_(0x9D, 0x2100 + HI + 1)
        a.emit(0x4C); a.word("arm_loop")

        a.label("arm_found")
        # 게임이 쓰던 AC channel1 문맥($1A12-$1A19)을 보존한다.
        for i in range(8):
            a.abs_(0xAD, 0x1A12 + i); a.abs_(0x9D, 0x2100 + CH1SAVE + i)

        # ENTRY+3..5 = payload absolute AC pointer. port0 source.
        ac_ptr_local(a, 0, ENTRY + 3)
        a.abs_(0xAD, 0x1A00); a.abs_(0x9D, 0x2100 + TOTAL)  # count
        # total bytes=count*13 = count*16-count*3
        # 최대 143이라 8-bit. 반복 덧셈으로 코드보다 상태를 단순하게 유지한다.
        a.emit(0xA9, 0); a.abs_(0x9D, 0x2100 + TOTAL + 1)
        a.abs_(0xBD, 0x2100 + TOTAL); a.abs_(0x9D, 0x2100 + PROBE)
        a.label("arm_mul13")
        a.abs_(0xBD, 0x2100 + TOTAL + 1); a.emit(0x18, 0x69, 13); a.abs_(0x9D, 0x2100 + TOTAL + 1)
        a.abs_(0xDE, 0x2100 + PROBE); a.branch(0xD0, "arm_mul13")
        ac_ptr_const(a, 1, AC_MINI)
        a.label("arm_copy_mini")
        a.abs_(0xAD, 0x1A00); a.abs_(0x8D, 0x1A10)
        a.abs_(0xDE, 0x2100 + TOTAL + 1); a.branch(0xD0, "arm_copy_mini")

        # 디스크 선적재가 $1F1F00을 옛 renderer로 덮으므로 안전한 template에서
        # 현재 653 B 엔진을 매 음성 시작에 active 슬롯으로 복원한다.
        # 통합판에서는 CD-DA signature가 남지 않도록 더 긴 671 B 슬롯 전체를
        # ADPCM template(653 B + FF padding)로 복원한다.
        copy_engine_bytes = max(engine_bytes, cdda_engine_bytes)
        reuse_sig = bytes(adpcm_reuse_signature or b"")
        if adpcm_reuse_signature_offset is not None:
            sig_end = adpcm_reuse_signature_offset + len(reuse_sig)
            if not reuse_sig:
                raise ValueError("ADPCM reuse signature가 비었다")
            if adpcm_reuse_signature_offset < engine_bytes:
                raise ValueError("ADPCM reuse signature가 엔진 본문과 겹친다")
            if sig_end > copy_engine_bytes:
                raise ValueError("ADPCM reuse signature가 복사 슬롯을 넘는다")
            # ★ CPU 한 바이트만 본다.  두 바이트째부터는 LDA abs 가 또 필요해
            #   (+5 B) 뱅크1 여유 10 B 를 넘긴다.  콜드부트 오탐 1/256 은
            #   **부팅 때 이 자리를 한 번 미는 것**으로 닫는다 (로더 5 B).
            if len(reuse_sig) != 1:
                raise ValueError(
                    f"CPU 읽기 판은 지문이 1 B 여야 한다 (지금 {len(reuse_sig)} B)")
            if adpcm_reuse_signature_offset != copy_engine_bytes - 2:
                raise ValueError(
                    "지문은 슬롯 끝에서 두 번째여야 한다 "
                    f"(기대 {copy_engine_bytes - 2} · 지금 {adpcm_reuse_signature_offset}) "
                    "-- 마지막 바이트는 media_magic 자리다")

            # selector/VRAM 즉치값은 아래에서 항상 새 값으로 덮는다. 실행 중
            # 자기수정은 CPU $5B80 사본에서만 일어나므로, 이 불변 꼬리 지문이
            # 맞으면 active AC 본문 671 B를 다시 나를 필요가 없다.
            #
            # ★★ 2026-09-17: **AC 를 들여다보지 않는다.**
            #   지문은 671 B 이미지에 실려 이미 **CPU $5B80 사본**까지 와 있다
            #   (resident 가 state 1 에서 AC_ENGINE -> $5B80 을 통째로 나른다).
            #   비용의 대부분이 AC 포인터 세팅이었다:
            #
            #       AC 읽기 판   ac_ptr_const ~24 B + 바이트당 7 B   ->  +45 B (실측)
            #       CPU 읽기 판  LDA abs / CMP / BEQ                ->  ** +7 B **
            #
            #   뱅크1 여유가 10 B 뿐이라 이 차이가 되고 안 되고를 갈랐다.
            #
            # ⚠ 이 자리가 살아남는 근거 (2026-09-17 실측):
            #     엔진 본문   669 B -> $5B80~$5E1C
            #     헬퍼        448 B -> $5B80~$5D3F   (subtitle_vram_helper.json end_cpu)
            #     $5E1D       = offset 669.  둘 다 안 닿는다
            #     $5E1E       = offset 670 = media_magic($CD).  **바로 옆에서 같은
            #                   방식이 이미 쓰이고 있다** -- 이 자리가 남는다는 증거다
            cpu_flag = 0x5B80 + adpcm_reuse_signature_offset
            a.abs_(0xAD, cpu_flag)                      # LDA $5E1D
            a.emit(0xC9, reuse_sig[0])                  # CMP #magic
            a.branch(0xF0, "arm_engine_ready")          # BEQ -> 671 B 복사 건너뜀

        a.label("arm_engine_copy")
        full, tail = divmod(copy_engine_bytes, 256)
        a.emit(0x5A)  # PHY
        ac_ptr_const(a, 0, AC_ENGINE_TEMPLATE)
        ac_ptr_const(a, 1, AC_ENGINE)
        for page in range(full):
            a.emit(0xA0, 0x00)
            a.label(f"arm_copy_engine_p{page}")
            a.abs_(0xAD, 0x1A00); a.abs_(0x8D, 0x1A10)
            a.emit(0xC8); a.branch(0xD0, f"arm_copy_engine_p{page}")
        if tail:
            a.emit(0xA0, 0x00)
            a.label("arm_copy_engine_tail")
            a.abs_(0xAD, 0x1A00); a.abs_(0x8D, 0x1A10)
            a.emit(0xC8, 0xC0, tail); a.branch(0xD0, "arm_copy_engine_tail")
        a.emit(0x7A)  # PLY
        a.label("arm_engine_ready")

        # helper control block = (base lo, base hi, pattern hi, pattern lo).
        #
        # ★ 2026-09-02: 여기가 $6600 상수였다.  헬퍼는 이 값으로 **자기가 그린
        #   글리프를 지운다.**  음성마다 자리를 옮겨 놓고 지우는 곳만 $6600 에
        #   두면 다른 자리에 그린 글자가 화면에 그대로 남는다.
        #   (소스 주석: "pattern bank/first 는 Lua가 key별 base와 함께 control
        #    block에 쓴다" -- Lua 시절에는 이 일을 Lua 가 했다.)
        #
        #   base 는 0x100 정렬이므로 lo 는 늘 0 이고, pattern = base >> 5 이므로
        #   pattern hi = base >> 13 = (base hi) >> 5 다.  LSR 5 번이면 된다.
        ac_ptr_const(a, 1, AC_HELPER_CTL_BASE)
        if imm_offsets is not None:
            a.emit(0xA9, 0x00); a.abs_(0x8D, 0x1A10)                    # base lo
            a.abs_(0xBD, 0x2100 + ENTRY + 6); a.abs_(0x8D, 0x1A10)      # base hi
            a.abs_(0xBD, 0x2100 + ENTRY + 6)
            for _ in range(5):
                a.emit(0x4A)                                            # LSR A
            a.abs_(0x8D, 0x1A10)                                        # pattern hi
            a.abs_(0xBD, 0x2100 + ENTRY + 7); a.abs_(0x8D, 0x1A10)      # pattern lo
        else:
            for value in (0x00, 0x66, 0x03, 0x30):
                a.emit(0xA9, value); a.abs_(0x8D, 0x1A10)

        # source를 payload 첫 entry로 되돌려 첫 selector 9 B만 engine image에 쓴다.
        # 저장된 payload ptr에 +1.
        a.emit(0x18)
        a.abs_(0xBD, 0x2100 + ENTRY + 3); a.emit(0x69, 1); a.abs_(0x9D, 0x2100 + ENTRY + 3)
        a.abs_(0xBD, 0x2100 + ENTRY + 4); a.emit(0x69, 0); a.abs_(0x9D, 0x2100 + ENTRY + 4)
        a.abs_(0xBD, 0x2100 + ENTRY + 5); a.emit(0x69, 0); a.abs_(0x9D, 0x2100 + ENTRY + 5)
        ac_ptr_local(a, 0, ENTRY + 3)
        ac_ptr_const(a, 1, selector_ac)
        a.emit(0xA9, 9); a.abs_(0x9D, 0x2100 + TOTAL + 1)
        a.label("arm_copy_selector")
        a.abs_(0xAD, 0x1A00); a.abs_(0x8D, 0x1A10)
        a.abs_(0xDE, 0x2100 + TOTAL + 1); a.branch(0xD0, "arm_copy_selector")

        # First-part start is a deadline too. PROBE is 0 for the legacy
        # immediate first part, FF for a pending first part (idle renderer).
        a.label("arm_initial_schedule")
        if adpcm_initial_delay:
            ac_ptr_const(a, 0, AC_MINI + 7)
            a.abs_(0xAD, 0x1A00); a.abs_(0x9D, 0x2100 + PROBE)
            a.abs_(0xAD, 0x1A00); a.abs_(0x1D, 0x2100 + PROBE)
            a.branch(0xF0, "arm_first_ready")
            a.emit(0xA9, 0xFF)
            a.label("arm_first_ready")
            a.abs_(0x9D, 0x2100 + PROBE)
            ac_ptr_const(a, 1, AC_ENGINE + ready_cpu - 0x5B80)
            a.abs_(0xBD, 0x2100 + PROBE); a.abs_(0x8D, 0x1A10)

        # AC persistent state: elapsed=0, part=FF/0, count, next=mini[0/1].
        # FF+1 wraps to zero in the scheduler, including a one-part clip.
        ac_ptr_const(a, 1, AC_SCHED)
        for value in (0, 0):
            a.emit(0xA9, value); a.abs_(0x8D, 0x1A10)
        if adpcm_initial_delay:
            a.abs_(0xBD, 0x2100 + PROBE)
        else:
            a.emit(0xA9, 0)
        a.abs_(0x8D, 0x1A10)
        a.abs_(0xBD, 0x2100 + TOTAL); a.abs_(0x8D, 0x1A10)
        for i in range(3):
            if adpcm_initial_delay and i == 0:
                assert AC_MINI & 0xFF == 0
                a.abs_(0xBD, 0x2100 + PROBE)
                a.emit(0x29, 13, 0x49, 13)  # pending -> 0, immediate -> 13
            else:
                a.emit(0xA9, ((AC_MINI + 13) >> (8 * i)) & 0xFF)
            a.abs_(0x8D, 0x1A10)
        a.label("arm_initial_schedule_done")

        # ★ 음성마다 다른 VRAM 자리 (2026-09-02)
        #
        # 엔진은 글리프 블록 주소를 코드 안 즉치값 3 개로 들고 있다.  template
        # 복사는 D000 값을 되돌려 놓으므로, **복사 뒤·CPU 동기화 전**에 이
        # 음성 것으로 덮는다.  값은 디렉터리가 이미 계산해 실어 왔다
        # (ENTRY+6..8) -- 6280 은 시프트도 마스크도 하지 않는다.
        if imm_offsets is not None:
            for i, off_imm in enumerate(imm_offsets):
                ac_ptr_const(a, 1, AC_ENGINE + off_imm)
                a.abs_(0xBD, 0x2100 + ENTRY + 6 + i); a.abs_(0x8D, 0x1A10)

        # resident state1 경로는 copy_renderer보다 먼저 현재 CPU ENTRY를 한 번
        # 호출한다. 이전 매체가 CD-DA였으면 그 ENTRY를 실행하면 안 된다.
        # selector까지 완성된 active AC image를 CPU에 미리 동기화한다.
        if precopy_cpu:
            ac_ptr_const(a, 0, AC_ENGINE)
            a.emit(0xF3); a.word(0x1A00); a.word(0x5B80); a.word(copy_engine_bytes)

        # channel1을 건드리지 않았던 것처럼 원래 레지스터 문맥을 되돌린다.
        for i in range(8):
            a.abs_(0xBD, 0x2100 + CH1SAVE + i); a.abs_(0x8D, 0x1A12 + i)
        a.emit(0xA9, 1); a.abs_(0x8D, STATE)

        a.label("arm_miss")
        for _ in range(LOCALS): a.emit(0x68)
        a.emit(0x4C); a.word("arm_return")

        if cdda_template_ac is not None:
            if cdda_rom_entry is not None:
                # start_cdda 훅에서 온 요청은 펄스 재검사 없이 디렉터리 조회로 간다.
                # ROM 상주 빌드는 전 트랙 디렉터리를 반드시 사용한다.
                if cdda_dir_ac is None:
                    raise ValueError("ROM CD-DA는 전 트랙 디렉터리가 필요하다")
                a.label("rom_cdda_init")
                if cdda_done_latch_ac is not None:
                    # state=1은 start_cdda의 실제 요청 사건에서만 온다. 게임 RAM의
                    # 재생 레벨로 들어오는 자동 재무장은 state=0 cdda_check 경로라
                    # 여기를 지나지 않는다. 같은 트랙의 정상 재생도 여기서 열린다.
                    a.label("cdda_done_request_clear")
                    ac_ptr_const(a, 0, cdda_done_latch_ac)
                    a.abs_(0x9C, 0x1A00)
                a.emit(0x4C); a.word("cdda_lookup")
            # 0.4.6.25 실기 PASS detector 그대로: Track 17 raw $11과 한 프레임
            # start pulse 중 하나가 동시에 있을 때만 연다. 다른 track은 fail-closed.
            a.label("cdda_check")
            if cdda_dir_ac is None:
                # 트랙 하나 고정 (0.4.6.25 그대로)
                a.abs_(0xAD, 0x26F9); a.emit(0x29, 0x7F, 0xC9, cdda_track_raw)
                a.branch(0xF0, "cdda_track_ok")
                a.emit(0x4C); a.word("arm_return")
                a.label("cdda_track_ok")
                a.abs_(0xAD, 0x263C); a.abs_(0x0D, 0x2638)
                a.branch(0xD0, "cdda_start")
                a.emit(0x4C); a.word("arm_return")
            else:
                # ★ 전 트랙: 시작 펄스 게이트를 먼저 보고, 트랙 디렉터리를
                #   선형 검색한다.  키는 **$26F9 & $7F** 그대로다 -- 0.4.6.25
                #   실기 PASS detector 라 바꾸지 않는다.
                #
                #   ★ `CMP $1A00` 이 포트를 **읽으면서** 비교한다.  그래서
                #     현재 트랙을 담아 둘 임시 바이트가 필요 없다 (자유 RAM 을
                #     찾아 헤맬 일이 없다).  자동증가도 그대로 먹는다.
                a.abs_(0xAD, 0x263C); a.abs_(0x0D, 0x2638)
                a.branch(0xD0, "cdda_pulse_ok")
                a.emit(0x4C); a.word("arm_return")
                a.label("cdda_pulse_ok")
                # start_cdda를 직접 가로챈 ROM 판은 한 프레임 뒤 펄스가 사라질
                # 수 있다. cdda_state=1이면 같은 디렉터리 조회로 바로 들어간다.
                a.label("cdda_lookup")
                ac_ptr_const(a, 0, cdda_dir_ac)
                a.emit(0xA2, 0x00)                       # LDX #0
                a.label("cdda_dir_loop")
                a.abs_(0xAD, 0x26F9); a.emit(0x29, 0x7F)
                a.abs_(0xCD, 0x1A00)                     # CMP $1A00 (읽으며 비교)
                a.branch(0xF0, "cdda_start")             # 찾았다.  X = 인덱스
                a.emit(0xA0, cdda_dir_stride - 1)        # LDY #stride-1
                a.label("cdda_dir_skip")
                a.abs_(0xAD, 0x1A00); a.emit(0x88)       # LDA $1A00 / DEY
                a.branch(0xD0, "cdda_dir_skip")
                a.emit(0xE8)                             # INX
                a.emit(0xE0, cdda_dir_count)             # CPX #count
                a.branch(0xD0, "cdda_dir_loop")
                a.emit(0x4C); a.word("arm_return")       # 표에 없는 트랙

            a.label("cdda_start")
            if cdda_replay_latch is not None:
                # **이미 무장한 트랙을 또 물지 않는다.**
                #
                #   $20A2  CD_SUBQ 트랙 (BCD).  게임이 트랙을 걸 때 쓴다
                #   $5E1B  무장된 트랙 (BCD).  아래 cdda_start 본체가 디렉터리
                #          항목에서 읽어 심는다 (이 검사보다 **뒤에** 쓴다)
                #
                #   새 트랙 무장   $20A2=새것 · $5E1B=아직 이전 것  -> 다르다 -> 통과
                #   자가 재무장    $20A2=그것 · $5E1B=그것          -> 같다  -> 거부
                #
                # 이 짝은 스케줄러가 이미 같은 방식으로 비교한다 ($ED87/$EEE6 의
                # "트랙이 바뀌었나" 판정).  그래서 새 RAM 바이트도, cooldown 도,
                # 시간 계산도 필요 없다.
                #
                # ★ 앞선 세 판(rc4·rc5·rc6)은 `cooldown`+`last_raw` 로 만들었다가
                #   전부 실패했다.  `last_raw` 를 쓰는 곳이 `cache_arm` 하나인데
                #   CD-DA 무장이 거길 안 지나가서 rc4 는 한 번도 안 물었고,
                #   억지로 채운 rc5·rc6 은 `cache_save` 의 잠자던 억제를 깨워
                #   CD-DA 자막을 통째로 날렸다.  그 바이트들은 이제 안 쓴다.
                #
                # ★ A 는 여기서 죽어 있다 (바로 아래가 LDA $1A12 로 덮는다).
                #   X 는 디렉터리 인덱스라 살아 있어야 하는데 안 건드린다.
                subq_track, armed_track = cdda_replay_latch
                a.abs_(0xAD, subq_track)                 # LDA $20A2  지금 트랙 (BCD)
                a.abs_(0xCD, armed_track)                # CMP $5E1B  무장된 트랙 (BCD)
                a.branch(0xD0, "cdda_replay_ok")         # 다르다 -> 새 트랙이다.  통과
                a.emit(0x4C); a.word("arm_return")       # 같다 -> 이미 문 트랙.  거부
                a.label("cdda_replay_ok")
            # 게임의 AC channel1 문맥을 보존한다.
            for i in range(8):
                a.abs_(0xAD, 0x1A12 + i); a.emit(0x48)
            if cdda_done_latch_ac is not None:
                # 게임이 $5E1F까지 실제로 쓰므로 CPU RAM 표식은 쓸 수 없다
                # (rc10에서 오프닝 전 FF를 읽어 CD-DA가 전멸). 전용 AC 틈의
                # 정확한 한 바이트만 보고, 억제 경로에서도 CH1을 원상복구한다.
                ac_ptr_const(a, 1, cdda_done_latch_ac)
                a.abs_(0xAD, 0x1A10)
                a.emit(0xC9, cdda_done_latch_value)
                a.branch(0xD0, "cdda_playback_fresh")
                if cdda_done_latch_track is not None:
                    # ★ 2026-09-08: 서명만 보면 "이 재생 건" 이 아니라 "표식이
                    #   살아 있는 동안 오는 모든 트랙" 을 막는다.  자동증가로
                    #   다음 바이트가 표식을 찍은 트랙이니 지금 트랙과 비교해서
                    #   다르면 새 재생으로 보고 통과시킨다.  같은 트랙의 자연
                    #   소진 뒤 재무장(원래 잡으려던 것)은 그대로 막힌다.
                    #
                    # ★★ 키는 **아래 cdda_check 의 조회 키와 같아야 한다**
                    #   ($26F9 & $7F).  1 차 시도는 $20A2 를 봤는데, 트랙 경계
                    #   에서 $20A2 가 먼저 다음 트랙으로 튀고 $26F9 는 아직
                    #   옛 트랙이라 (실기 f87812: 21 vs 20) 관문만 열리고 조회는
                    #   **옛 트랙을 다시 무장**했다.  이중재생이 1 프레임 뒤로
                    #   옮겨갔을 뿐이다.  둘은 반드시 같은 것을 물어야 한다.
                    a.abs_(0xAD, cdda_done_latch_track)
                    a.emit(0x29, 0x7F)
                    a.abs_(0xCD, 0x1A10)
                    a.branch(0xD0, "cdda_playback_fresh")
                for i in reversed(range(8)):
                    a.emit(0x68); a.abs_(0x8D, 0x1A12 + i)
                a.label("cdda_done_suppress")
                a.emit(0x4C); a.word("arm_return")
                a.label("cdda_playback_fresh")

            # 성공판 671 B 엔진을 active AC slot으로 복사한다. resident가
            # state 1을 받아 CPU $5B80에 싣는다.
            if cdda_rom_entry is None:
                ac_ptr_const(a, 0, cdda_template_ac)
                ac_ptr_const(a, 1, AC_ENGINE)
                cfull, ctail = divmod(cdda_engine_bytes, 256)
                for page in range(cfull):
                    a.emit(0xA0, 0x00)
                    a.label(f"cdda_copy_engine_p{page}")
                    a.abs_(0xAD, 0x1A00); a.abs_(0x8D, 0x1A10)
                    a.emit(0xC8); a.branch(0xD0, f"cdda_copy_engine_p{page}")
                if ctail:
                    a.emit(0xA0, 0x00)
                    a.label("cdda_copy_engine_tail")
                    a.abs_(0xAD, 0x1A00); a.abs_(0x8D, 0x1A10)
                    a.emit(0xC8, 0xC0, ctail); a.branch(0xD0, "cdda_copy_engine_tail")
            else:
                # 캐시는 재구성 때 전부 덮이므로 초기화는 상태 세 바이트면 충분하다.
                a.emit(0xA9, 0xFF); a.abs_(0x8D, cdda_ready_cpu)
                a.abs_(0x9C, cdda_blank_cpu); a.abs_(0x9C, cdda_count_cpu)

            # 0.4.6.25 helper 계약: Track 17은 검증된 VRAM $7900.
            # ★ 전 트랙 모드에서는 상수가 아니라 디렉터리에서 흘려 넣는다
            #   (아래 cdda_dir_ac 블록).  헬퍼는 이 base 로 자기 글리프를 지우므로
            #   트랙마다 달라야 한다 -- 상수로 두면 다른 트랙에서 배경이 깨진다.
            if cdda_dir_ac is None:
                ac_ptr_const(a, 1, AC_HELPER_CTL_BASE)
                for value in (0x00, 0x79, 0x03, 0xC8):
                    a.emit(0xA9, value); a.abs_(0x8D, 0x1A10)

            # 0.4.6.25는 CD-DA engine이 부팅부터 CPU에 있어 pre-copy ENTRY도
            # 올바른 엔진이었다. 통합판은 매체가 바뀌므로 state1 전에 active
            # image를 CPU에도 복사해 그 성공 계약을 복원한다.
            if precopy_cpu and cdda_rom_entry is None:
                ac_ptr_const(a, 0, AC_ENGINE)
                a.emit(0xF3); a.word(0x1A00); a.word(0x5B80); a.word(cdda_engine_bytes)

            # ★ 2026-09-04: 스케줄러 연동.  **cdda_mini_ac 를 안 주면 아무것도
            #   안 뿜는다** -- 지금까지의 CD-DA 경로와 바이트까지 동일하다.
            #
            #   ADPCM 은 mini index 를 런타임에 복사하고 첫 selector 를 미리
            #   심는다 (음성마다 항목이 달라서다).  CD-DA 트랙 17 은 39 항목이
            #   빌드 때 확정돼 있으므로 둘 다 필요 없다:
            #     · mini index 는 번들에 정적으로 실려 있다 (AC $1FEB00)
            #     · 첫 구간은 미리 안 심는다.  첫 자막이 프레임 2189 라 그전에는
            #       화면이 비어 있어야 하고, 스케줄러가 때가 되면 심는다
            #   그래서 AC_SCHED 7 B 를 상수로 채우는 것이 전부다.
            #
            #       elapsed u16 = 0    part u8 = 0    count u8 = 구간 수
            #       next  u24   = mini[0]            ★ mini[1] 이 아니다
            if cdda_mini_ac is not None:
                ac_ptr_const(a, 1, AC_SCHED)
                for value in (0, 0, 0, cdda_mini_count):
                    a.emit(0xA9, value); a.abs_(0x8D, 0x1A10)
                for i in range(3):
                    a.emit(0xA9, (cdda_mini_ac >> (8 * i)) & 0xFF)
                    a.abs_(0x8D, 0x1A10)

            # ★ 전 트랙판: 찾은 디렉터리 항목에서 값을 흘려 넣는다 (2026-09-04).
            #
            #   cdda_check 가 X 에 인덱스를 남겼다.  엔진 복사(port 0/1)를 마친
            #   뒤라 port 0 을 다시 열어야 한다 -- 주소는 dir + X*stride 다.
            #   stride 를 16 으로 잡아 **시프트 넷**이면 계산이 끝난다.
            #
            #   ⚠ 순서가 중요하다.  vram 즉치는 **엔진 복사 뒤**에 심어야 한다.
            #     복사가 템플릿 값으로 되돌려 놓기 때문이다 (ADPCM 도 같은 이유로
            #     복사 뒤에 심는다 -- 이 파일 2026-09-02 주석 참고).
            if cdda_dir_ac is not None:
                if cdda_dir_stride != 16:
                    raise ValueError("cdda_dir_stride 는 16 만 지원한다 (시프트 계산)")
                # port 0 = 디렉터리 항목 시작
                a.emit(0x8A)                                  # TXA
                for _ in range(4):
                    a.emit(0x0A)                              # ASL A  (×16)
                a.emit(0x18, 0x69, cdda_dir_ac & 0xFF)        # CLC / ADC #lo
                a.abs_(0x8D, 0x1A02)
                a.emit(0xA9, (cdda_dir_ac >> 8) & 0xFF); a.abs_(0x8D, 0x1A03)
                a.emit(0xA9, (cdda_dir_ac >> 16) & 0xFF); a.abs_(0x8D, 0x1A04)
                a.emit(0xA9, 0x01); a.abs_(0x8D, 0x1A07)
                a.abs_(0x9C, 0x1A08)
                a.emit(0xA9, 0x11); a.abs_(0x8D, 0x1A09)

                a.abs_(0xAD, 0x1A00)                          # +0 raw -- 버린다
                # +1 BCD -> 렌더러 패딩.  스케줄러가 $20A2 와 비교할 값이다
                if cdda_rom_entry is None:
                    ac_ptr_const(a, 1, AC_ENGINE + cdda_track_byte_off)
                    a.abs_(0xAD, 0x1A00); a.abs_(0x8D, 0x1A10)
                else:
                    a.abs_(0xAD, 0x1A00); a.abs_(0x8D, cdda_track_cpu)
                # +2 count · +3..5 mini ptr -> AC_SCHED (elapsed/part 는 0)
                ac_ptr_const(a, 1, AC_SCHED)
                for _ in range(3):
                    a.emit(0xA9, 0x00); a.abs_(0x8D, 0x1A10)
                for _ in range(4):
                    a.abs_(0xAD, 0x1A00); a.abs_(0x8D, 0x1A10)
                # +6..8 vram 즉치 -> 렌더러 세 자리
                #
                # ★ CD-DA 렌더러의 오프셋을 써야 한다.  ADPCM 것(imm_offsets)을
                #   그대로 쓰면 CD-DA 렌더러 코드를 엉뚱한 자리에서 뭉갠다
                #   (2026-09-04: 그래서 자막이 아예 안 나왔다).
                if cdda_imm_offsets is None and cdda_rom_entry is None:
                    raise ValueError("cdda_dir_ac 에는 cdda_imm_offsets 가 필요하다")
                if cdda_rom_entry is None:
                    for off_imm in cdda_imm_offsets:
                        ac_ptr_const(a, 1, AC_ENGINE + off_imm)
                        a.abs_(0xAD, 0x1A00); a.abs_(0x8D, 0x1A10)
                else:
                    for cpu in cdda_imm_cpus:
                        a.abs_(0xAD, 0x1A00); a.abs_(0x8D, cpu)
                # +9..12 헬퍼 제어블록 (base lo · base hi · pattern hi · pattern lo)
                ac_ptr_const(a, 1, AC_HELPER_CTL_BASE)
                for _ in range(4):
                    a.abs_(0xAD, 0x1A00); a.abs_(0x8D, 0x1A10)
                # ★ +13/+14 이사 기록 (2026-09-05) -- 트랙 3 처럼 트랙 안에서
                #   자리가 한 번 바뀌는 경우다.  렌더러 패딩에 심어 스케줄러가
                #   읽게 한다 (트랙 BCD 를 +660 에 심는 것과 같은 방식).
                #
                #     +13 이사 구간 번호 (0 = 이사 없음)
                #     +14 새 base 의 hi.  lo/attr/pattern 은 스케줄러가 파생한다
                #
                #   ⚠ 렌더러 패딩은 코드(618 B) 뒤 · 매체 지문(+670) 앞이다.
                #     +660 은 BCD 가 쓰므로 +661/+662 를 쓴다.
                if cdda_move_byte_off:
                    ac_ptr_const(a, 1, AC_ENGINE + cdda_move_byte_off)
                    for _ in range(2):
                        a.abs_(0xAD, 0x1A00); a.abs_(0x8D, 0x1A10)

            for i in reversed(range(8)):
                a.emit(0x68); a.abs_(0x8D, 0x1A12 + i)
            if cdda_rom_entry is None:
                a.emit(0xA9, 1); a.abs_(0x8D, STATE)
            else:
                a.emit(0xA9, 2); a.abs_(0x8D, cdda_state_cpu)
            a.emit(0x4C); a.word("arm_return")

        # FEC4는 resident에서 프레임당 한 번 호출된다. active state 2일 때만
        # elapsed를 올리고 mini의 다음 start에 도달하면 CPU selector/ready를 갱신한다.
        a.label("scheduler")
        # channel1 문맥 뒤에 9 B stack locals를 만들고 AC persistent state를 읽는다.
        for i in range(8):
            a.abs_(0xAD, 0x1A12 + i); a.emit(0x48)
        for _ in range(S_LOCALS): a.emit(0x48)
        a.emit(0xBA)
        ac_ptr_const(a, 1, AC_SCHED)
        for i in range(7):
            a.abs_(0xAD, 0x1A10); a.abs_(0x9D, 0x2100 + S_ELAPSED + i)

        a.abs_(0xFE, 0x2100 + S_ELAPSED); a.branch(0xD0, "sched_no_carry")
        a.abs_(0xFE, 0x2100 + S_ELAPSED + 1)
        a.label("sched_no_carry")
        a.abs_(0xBD, 0x2100 + S_PART); a.emit(0x1A)
        a.abs_(0xDD, 0x2100 + S_COUNT)
        a.branch(0x90, "sched_has_next")
        a.emit(0x4C); a.word("sched_store")
        a.label("sched_has_next")

        # next entry의 start_frame(+7)를 읽어 elapsed와 unsigned 비교한다.
        ac_ptr_local(a, 1, S_NEXT, 7)
        a.abs_(0xAD, 0x1A10); a.abs_(0x9D, 0x2100 + S_START)
        a.abs_(0xAD, 0x1A10); a.abs_(0x9D, 0x2100 + S_START + 1)
        a.abs_(0xBD, 0x2100 + S_ELAPSED + 1); a.abs_(0xDD, 0x2100 + S_START + 1)
        a.branch(0x90, "sched_not_due_jump")
        a.branch(0xD0, "sched_due")
        a.abs_(0xBD, 0x2100 + S_ELAPSED); a.abs_(0xDD, 0x2100 + S_START)
        a.branch(0x90, "sched_not_due_jump")

        a.label("sched_due")
        # 다음 9 B selector를 CPU image에 직접 설치한다.
        ac_ptr_local(a, 1, S_NEXT)
        a.emit(0xF3); a.word(0x1A10); a.word(selector_cpu); a.word(9)

        # 이전 rebuild가 stage 버퍼를 글리프로 덮었으므로 31 B 루틴도 복원한다.
        ac_ptr_const(a, 1, AC_ENGINE_TEMPLATE + stage_offset)
        a.emit(0xF3); a.word(0x1A10); a.word(stage_cpu); a.word(stage_bytes)
        a.abs_(0x9C, ready_cpu)
        a.abs_(0xFE, 0x2100 + S_PART)

        # 그 다음 mini entry를 가리키도록 pointer += 13.
        a.emit(0x18)
        for i in range(3):
            a.abs_(0xBD, 0x2100 + S_NEXT + i)
            a.emit(0x69, 13 if i == 0 else 0)
            a.abs_(0x9D, 0x2100 + S_NEXT + i)
        a.emit(0x4C); a.word("sched_store")

        # BCC 대상이 멀어질 수 있어 짧은 trampoline을 둔다.
        a.label("sched_not_due_jump"); a.emit(0x4C); a.word("sched_store")
        a.label("sched_store")
        ac_ptr_const(a, 1, AC_SCHED)
        for i in range(7):
            a.abs_(0xBD, 0x2100 + S_ELAPSED + i); a.abs_(0x8D, 0x1A10)
        for _ in range(S_LOCALS): a.emit(0x68)
        a.label("sched_restore")
        for i in reversed(range(8)):
            a.emit(0x68); a.abs_(0x8D, 0x1A12 + i)
        a.label("arm_return")
        if complete_decision:
            # state 2의 종료 주체를 매체별로 분리한다.
            # CD-DA는 renderer가 문턱에서 state 3을 직접 쓰므로 유지한다.
            # ADPCM만 원래 계약대로 $180D bit $20이 내려가면 state 3으로 보낸다.
            a.abs_(0xAD, STATE); a.emit(0xC9, 0x02)
            a.branch(0xD0, "decision_value")
            if cdda_template_ac is not None:
                a.abs_(0xAD, 0x5B80 + cdda_signature_offset)
                a.emit(0xC9, cdda_signature); a.branch(0xF0, "decision_value")
            a.abs_(0xAD, 0x180D); a.emit(0x29, 0x20)
            if adpcm_force_release_after_frames is None:
                a.branch(0xD0, "decision_value")
            else:
                # 진단 전용: Beetle이 ADPCM busy를 늦게 내리는지 흑상자 A/B로
                # 확인한다. 첫 256프레임 안에서만 쓰는 시험이라 elapsed low만
                # 비교한다. 문턱 뒤에는 기존 ready 기반 2단 철거를 그대로 탄다.
                if not 1 <= adpcm_force_release_after_frames <= 0xFF:
                    raise ValueError("ADPCM force-release frame must be 1..255")
                a.branch(0xF0, "decision_audio_done")
                a.abs_(0xAD, 0x2100 + S_ELAPSED)
                a.emit(0xC9, adpcm_force_release_after_frames)
                a.branch(0x90, "decision_value")
                a.label("decision_audio_done")
            # ★ 2026-09-03: state 3 을 **한 프레임 늦춘다.**
            #
            # SAT 는 vblank 에 래치되므로 정리 프레임 안에서는 스프라이트를 못
            # 없앤다.  그런데 헬퍼의 복원은 표시 구간에서 돈다 (0.5.153 실측:
            # 비우기 라인 41 · 복원 라인 55~198 · 2451 회).  그래서 라인 55 아래를
            # 그리는 스프라이트가 **복원된 배경(4 플레인)** 을 글자 모양으로 그려
            # 화면 중간부터 알록달록한 띠가 뜬다.
            #
            # 고치는 길: 복원 프레임에 스프라이트가 아예 없게 만든다.
            # armer 는 엔진보다 먼저 돈다 (0.5.154 실측 3/3: FEC4@22 < ENTRY@27).
            # 그러니 여기서 ready 를 내리면 **그 프레임 엔진이 push 를 건너뛴다**
            # (0.4.6.71 의 blank 기계가 그대로 쓰인다: ready=0 · blank=0 -> RTS).
            #
            #     프레임 N    ready 를 내린다 · state 는 2 그대로 -> push 없음
            #     프레임 N+1  ready==0 이므로 state=3 -> 상주부가 wipe+restore
            #                 이때 SAT 에 우리 칸이 없다
            #
            # N+1 에 엔진이 rebuild 하며 다시 밀 걱정은 없다 -- 그 프레임에는
            # 상주부가 엔진 대신 **헬퍼**를 올린다 (0.5.154: ENTRY(H) 만 있고
            # ENTRY(E)/PUSH 가 없다).
            a.abs_(0xAD, ready_cpu)
            a.branch(0xF0, "decision_state3")     # 이미 0 = 두 번째 프레임이다
            a.abs_(0x9C, ready_cpu)               # STZ ready -- 이번엔 state 2 유지
            a.branch(0x80, "decision_value")
            a.label("decision_state3")
            a.emit(0xA9, 0x03); a.abs_(0x8D, STATE)
            a.branch(0x80, "decision_value")
            a.label("decision_value"); a.abs_(0xAD, STATE)
            a.label("decision_exit")
        else:
            # FEC4의 displaced LDA $7FDF 결과를 A에 돌려준다.
            a.abs_(0xAD, STATE)
        a.emit(0x48, 0xA9, 0)
        a.emit(0x4C); a.word(base.EXIT_BRIDGE)

        if cdda_rom_entry is not None:
            # CPU cache 패처가 기존 start_cdda의 STATE=1 기록 대신 이 루틴을
            # 호출한다. 다음 FEC4에서 cdda_state=1이 디렉터리 초기화를 연다.
            a.label("cdda_rom_request")
            a.emit(0xA9, 0x01); a.abs_(0x8D, cdda_state_cpu)
            a.emit(0x60)
    return emit


def main() -> None:
    master = MASTER.read_bytes()
    directory = DIR.read_bytes()
    payload = PAYLOAD.read_bytes()
    if len(master) % 9 or len(directory) % 6:
        raise SystemExit("native table stride 오류")
    info = json.loads(TABLE_INFO.read_text(encoding="utf-8"))
    eng = json.loads(ENGINE_INFO.read_text(encoding="utf-8"))
    dir_count = len(directory) // 6
    if dir_count != info["directory_entries"]:
        raise SystemExit("directory count manifest 불일치")
    selector_ac = AC_ENGINE + eng["offsets"]["selector"]

    base.BUILD_ID = BUILD_ID
    off = eng["offsets"]
    emitter = make_armer(dir_count, selector_ac, eng["engine_bytes"],
        0x5B80 + off["ready"], 0x5B80 + off["selector"],
        0x5B80 + off["stage"], off["stage"], eng["stage_routine_bytes"],
        adpcm_initial_delay=eng.get("initial_delay", False))
    first, labels = base.build_dispatcher(base.BANK1_FREE_LO, AC_MASTER, len(master)//9,
        extra_return=FEC4_RET, extra_builder=emitter)
    code, labels = base.build_dispatcher(base.BANK1_FREE_LO, AC_MASTER, len(master)//9,
        labels, extra_return=FEC4_RET, extra_builder=emitter)
    if len(first) != len(code): raise SystemExit("2-pass 불일치")
    room = base.BANK1_FREE_HI - base.BANK1_FREE_LO + 1
    if len(code) > room: raise SystemExit(f"bank1 초과: {len(code)}/{room}")

    src = ROOT / "build" / "patch" / "0.4.6.22-dictionary-key-vram"
    source = src / "Syscard3_galmuri_0.4.6.21-reviewed-dictionary.pce"
    dst = ROOT / "build" / "patch" / VERSION
    if dst.exists(): raise SystemExit(f"이미 존재: {dst}")
    dst.mkdir(parents=True)
    out = dst / f"Syscard3_galmuri_{VERSION}.pce"
    base.patch_image(source, out, code)
    img = bytearray(out.read_bytes())
    at = FEC4 - 0xE000
    if bytes(img[at:at+3]) != FEC4_ORIG:
        raise SystemExit(f"FEC4 원본 불일치: {bytes(img[at:at+3]).hex(' ')}")
    # 0.4.6.31과 동일하게 FEC7의 기존 CMP/state 루틴으로 계속 진행한다.
    img[at:at+3] = bytes((0x20, 0xD4, 0xFF))
    out.write_bytes(img)
    (CUT / "adpcm_native_arm_dispatcher.bin").write_bytes(code)

    note = f"""{VERSION} native ADPCM D000 3-fragment scheduler

BIOS: {out.name}
Lua: lua/SUB/0.5.64.lua (frozen 8F20AF38 업로드 + read-only 전환 로그)

전체 음성 LBA lookup: {len(master)//9} entries @ AC ${AC_MASTER:06X}
자막 route: {dir_count} entries @ AC ${AC_DIR:06X}
payload: {len(payload)} bytes
selector AC: ${selector_ac:06X}
engine template: ${AC_ENGINE_TEMPLATE:06X} ({eng['engine_bytes']} B)

이 판은 디렉터리에 든 **모든 음성**에서 native가 mini index와 첫 selector를 복사하고 state 1을 연다
(2026-09-02.  그 전에는 LBA ${TARGET_LBA:06X} 하나뿐이었다 -- 음성마다 다른 VRAM 자리를
나를 칸이 디렉터리에 없었기 때문이다.  지금은 항목 9 B 의 뒤 3 B 가 그 자리다).
safe template에서 active engine을 복원하고 helper base $6600을 다시 쓴 뒤 selector를 설치한다.
channel1 레지스터 문맥은 작업 전후 저장/복원하며, $FEC4는 기존 FEC7 루틴으로 복귀한다.
FEC4 frame scheduler가 mini start 90/180에서 CPU selector와 stage를 복원하고 ready=0으로 재build한다.
"""
    (dst / "TEST_IN_MESEN.txt").write_text(note, encoding="utf-8")
    print(f"{VERSION} code {len(code)}/{room} B · dir {dir_count} · selector ${selector_ac:06X}")
    print(out)


if __name__ == "__main__": main()
