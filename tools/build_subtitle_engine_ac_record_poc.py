#!/usr/bin/env python3
"""AC 팩의 임의 자막 레코드와 글리프를 직접 해석하는 6280 POC 엔진."""
from __future__ import annotations

import json
import struct
from pathlib import Path

import build_subtitle_engine as base
import subtitle_layout as layout

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / "build" / "cutscene_subs" / "subtitle_pack.bin"
OUT = ROOT / "build" / "cutscene_subs" / "engine_ac_record_poc.bin"
INFO = ROOT / "build" / "cutscene_subs" / "engine_ac_record_poc.json"

# VRAM 이 잡는 칸 수와 **같아야** 한다.  따로 적어 두면 언젠가 어긋나고,
# 어긋나는 순간 팩 빌더가 허용한 줄을 엔진이 잘라낸다 (tools/subtitle_split.py).
MAX_GLYPHS = layout.MAX_GLYPHS
RECORD_BYTES = 6 + MAX_GLYPHS * 3
LIST_BYTES = MAX_GLYPHS * 5
PALETTE = 15


def build(labels: dict[str, int] | None, glyph_base: int, *, lookup: bool = False,
          index_base: int = 0, index_count: int = 0,
          record_base: int = 0, timed: bool = False,
          first_suffix: bytes = b"\0\0\0", next_suffix: bytes = b"\0\0\0",
          overlay_palette: bool = False, next_key: bytes = b"\0\0\0\0\0\0",
          wide_lookup: bool = True, wide_timer: bool = False,
          vdc_rearm: bool = False,
          blank_frame: bool = False,
          idle_state: bool = False,
          expire_frames: bool = False,
          palette_each_push: bool = False,
          rom_resident: bool = False,
          origin: int = base.ENGINE_LO) -> tuple[bytes, dict[str, int]]:
    if palette_each_push and not (overlay_palette and rom_resident):
        raise ValueError("palette_each_push 는 ROM 상주 overlay palette 경로 전용이다")
    # rom_resident (2026-09-06 신설.  기본 False = 지금까지와 **바이트 동일**)
    # ------------------------------------------------------------------
    # CD-DA 전용 설계(인계서 §47~§49)를 위한 스위치.  코드를 뱅크1 ROM 에
    # 상주시키려면 **자기수정 즉치 3 개**가 걸린다 -- ROM 에는 못 쓴다:
    #
    #     +202  69 xx   ADC #hi        <- vram_base_hi_imm 이 그 xx
    #     +237  69 xx   ADC #pat_lo    <- pattern_base_lo_imm
    #     +242  A9 xx   LDA #attr      <- pattern_attr_imm
    #
    # True 면 셋을 **RAM 변수 읽기**로 바꾼다 (각 +1 B · +3 cyc).  라벨은
    # 즉치 자리가 아니라 그 변수 자리를 가리키게 되고, 스케줄러는 지금처럼
    # 그 주소에 값을 박으면 된다 -- 박는 쪽 코드는 한 줄도 안 바뀐다.
    #
    #     ADC #imm  2 B · 2 cyc  ->  ADC abs  3 B · 5 cyc
    #     LDA #imm  2 B · 2 cyc  ->  LDA abs  3 B · 5 cyc
    #
    # 비용은 글리프당 +9 cyc · 재구성(19 글리프) 1 회당 +171 cyc = 0.38 스캔라인이고,
    # 재구성은 프레임마다가 아니라 **구간마다** 돈다.  그 대신 arm 마다
    # 15,203 cyc(33.4 줄, 그중 8.9 줄이 원자적 차단)가 사라진다 -- §48 참고.
    # idle_state (2026-09-04 신설.  기본 False = 지금까지와 바이트 동일)
    # ------------------------------------------------------------------
    # `ready` 한 바이트가 두 뜻을 겸하고 있었다:
    #
    #     ready == 0    그려라
    #     ready != 0    그릴 건 없다, push 만 해라
    #
    # 그런데 **아직 한 번도 안 그린** 상태가 그 어느 쪽도 아니다.  ADPCM 은
    # 기존에는 무장하면서 첫 조각을 바로 심었지만, 시작 지연을 지원하는
    # ADPCM 판도 첫 조각 전에는 이 idle 상태를 쓴다. CD-DA 스케줄러는
    # 첫 구간이 프레임 2189 라 그때까지 아무것도 안 그린다.  그동안 entry 가
    # `ready != 0` 을 "push 만 해라" 로 읽어 **빈 목록을 민다.**
    #
    # 실기 증상 (2026-09-04 사진):
    #   · 자막 자리가 아닌 곳에 스프라이트가 뜬다.  크기·자리가 판마다 다르다
    #   · 구워진 count 는 0 인데, 게임의 $6463 이 do-while 이라 **0 이 256 으로
    #     돈다.**  목록 끝을 한참 넘어가 엔진 코드와 그 뒤 RAM 을 스프라이트
    #     항목으로 읽는다 -- 위 주석이 "count=0 은 쓰지 말라" 고 경고한 바로 그것이
    #     의도치 않게 벌어지고 있었다
    #
    # 그래서 세 번째 상태를 만든다.  `$FF` 는 bit7 이 서 있어 `BMI` 하나로 갈린다:
    #
    #     ready == $FF  아직 아무것도 안 그렸다 -> **RTS.  push 도 안 한다**
    #     ready == 0    그려라
    #     ready == 1    그릴 건 없다, push 만
    #
    # 스케줄러가 첫 구간에서 `STZ ready` 를 하면 $FF -> 0 -> (그림) -> 1 로 가고
    # 다시 $FF 로 돌아갈 경로가 없다.  구워진 값은 호출자가 $FF 로 넣는다.
    # 일반 엔진은 기존처럼 $5B80 에 조립한다.  CD-DA ROM 상주판만 코드 origin을
    # 뱅크1의 빈 구간으로 바꾼다.  가변 데이터의 재배치는 호출자가 두 번째 pass의
    # known labels로 주입한다.  이 함수 자체는 기존 경로의 바이트를 바꾸지 않는다.
    a = base.Asm(origin, labels)
    a.emit(*base.MAGIC)
    a.label("entry")
    a.abs_(0xAD, "ready")                   # LDA ready
    if idle_state:
        a.branch(0x30, "idle_rts")          # BMI  ($FF = 아직 그린 적 없다)
    if overlay_palette:
        # 최초 진입에만 stage에 겹쳐 둔 팔레트 초기화 루틴을 실행한다.
        # 자체 전환은 entry가 아니라 rebuild로 직접 가므로 두 번 부르지 않는다.
        a.branch(0xD0, "timed_active")
        if blank_frame:
            # ★ 2026-09-03: 조각 경계에서 **한 프레임을 쉰다.**
            #
            # 글리프와 스프라이트는 반영 시점이 다르다.  글리프는 VDC 에 직접
            # 쓰므로 그 프레임에 바로 보이는데, 스프라이트는 `JSR $6463` 이
            # 목록에 넣을 뿐이라 SATB 반영이 **다음 프레임**이다.  그대로 두면
            # 경계 프레임 하나에 새 글자가 옛 칸수·옛 x 자리에 찍힌다 --
            # 소유자 사진의 "길리언시드다만이" + "임명된" 이 그것이다.
            # (0.5.147 실측 ★LEAD 14 건 · SAME 0 건)
            #
            # 그래서 스케줄러가 ready 를 내린 그 프레임에는 아무것도 안 한다.
            # push 를 건너뛰면 그 프레임의 스프라이트 목록에 우리 칸이 안 실려
            # 다음 프레임에 줄이 비고, 그 다음 프레임에 새 줄이 온전히 뜬다.
            # 깨진 한 프레임이 **빈 한 프레임**(16 ms)이 된다.
            #
            # ★ count=0 으로 push 하는 길은 쓰지 않는다.  게임의 $6463 이
            #   do-while 이면 0 이 256 으로 돈다.  그리고 $6000-$7FFF 는 장면마다
            #   갈리는 스크립트 VM 이라 원본 Track02 로는 확인이 안 된다.
            a.abs_(0xAD, "blank")               # LDA blank
            a.branch(0xD0, "do_rebuild")        # BNE  (쉬는 프레임을 이미 지났다)
            a.abs_(0xEE, "blank")               # INC blank
            a.emit(0x60)                        # RTS  -- 이번 프레임은 그냥 나간다
            a.label("do_rebuild")
            a.abs_(0x9C, "blank")               # STZ blank
        # RAM 엔진은 stage 앞 31 B에 넣어 둔 팔레트 초기화 루틴을 부른다.
        # ROM 상주판은 stage가 순수 캐시이므로, 같은 루틴을 ROM 코드 꼬리에 둔다.
        # 이렇게 하면 CD-DA 무장 때 295 B 템플릿을 RAM으로 복사할 필요가 없다.
        # ★ 2026-09-13: ROM 판의 palette_init은 팔레트만 쓰는 루틴이 아니다.
        # 글리프 작업 버퍼 stage의 상위 2 plane도 지운다.  이를 매-push 판에서
        # 생략하면 **트랙의 첫 자막**은 더러운 상위 plane을 VRAM에 먼저 보낸 뒤
        # push에서야 버퍼를 지운다. 트랙 4 첫 줄 「위험할 뻔했군.」의 깨진 획이
        # 그 결과였다. 첫 표시 프레임의 VCE 쓰기가 두 번이어도, 글리프 전송 전
        # 버퍼 초기화가 더 중요하므로 rebuild 앞에서는 항상 실행한다.
        a.abs_(0x20, "palette_init" if rom_resident else "stage")
        a.emit(0x4C); a.word("rebuild")
        if idle_state:
            # 위 JMP 로 넘어오지 않는 자리다.  BMI 가 여기로만 온다.
            a.label("idle_rts")
            a.emit(0x60)                    # RTS -- push 도 안 한다
        a.label("timed_active")
    else:
        if idle_state:
            raise ValueError("idle_state 는 overlay_palette 경로에서만 쓴다")
        a.branch(0xF0, "rebuild")            # BEQ rebuild
    if timed:
        if wide_timer:
            # 호출이 프레임과 정확히 1:1이라는 보장은 없다. 16-bit 누적값이
            # 다음 시작점에 도달하거나 넘어선 순간 전환한다. start_hi=$FF는
            # Lua가 넣는 마지막 조각 표식이므로 계속 현재 조각을 표시한다.
            a.abs_(0xEE, "elapsed")              # INC elapsed.lo
            a.branch(0xD0, "elapsed_ready")
            a.abs_(0xEE, a.known.get("elapsed", 0) + 1)
            a.label("elapsed_ready")
            a.abs_(0xAD, a.known.get("next_selector", 0) + 8)
            # 실제 음성 시작점은 0x8000 frame 미만이다. 음수($FF)인 비활성 표식은
            # BMI 한 번으로 걸러 CMP #$FF / BEQ보다 2 B 줄인다.
            a.branch(0x30, "timed_push")
            a.abs_(0xAD, a.known.get("elapsed", 0) + 1)
            a.abs_(0xCD, a.known.get("next_selector", 0) + 8)
            a.branch(0x90, "timed_push")          # elapsed.hi < start.hi
            a.branch(0xD0, "timed_advance")       # elapsed.hi > start.hi
            a.abs_(0xAD, "elapsed")
            a.abs_(0xCD, a.known.get("next_selector", 0) + 7)
            a.branch(0x90, "timed_push")          # elapsed.lo < start.lo
            a.label("timed_advance")
        else:
            # 구형 POC: 정확히 같은 low byte에서만 전환한다.
            a.abs_(0xEE, "elapsed")
            a.abs_(0xAD, "elapsed")
            a.abs_(0xCD, a.known.get("next_selector", 0) + 7)
            a.branch(0xD0, "timed_push")
        # 다음 9 B 선택자를 현재 선택자로 옮기고 즉시 다시 검색한다.
        a.emit(0x73); a.word("next_selector"); a.word("selector"); a.word(9)
        a.emit(0x4C); a.word("rebuild")
        a.label("timed_push")
    if expire_frames:
        if timed:
            raise ValueError("expire_frames 와 timed 는 함께 쓸 수 없다")
        # CD-DA 스케줄러판은 시작 시각만 관리하므로, 예전에는 다음 레코드가
        # 올 때까지 현재 줄을 계속 push했다. 레코드 캐시의 frames(+4,+5)는
        # timed=False에서 다른 코드가 쓰지 않는다. 이를 16-bit 남은 수명으로
        # 직접 줄여 0이 된 프레임에 READY_IDLE로 돌아가면, 중간 공백 동안은
        # push하지 않고 다음 due의 STZ ready에서 정상적으로 다시 살아난다.
        #
        # rebuild가 끝난 프레임에는 이미 한 번 표시했으므로, ready==1로 들어온
        # 다음 프레임부터 감소시켜 frames=N을 정확히 N번 표시한다.
        record_at = a.known.get("record", 0)
        a.abs_(0xAD, record_at + 4)            # LDA frames.lo
        a.emit(0x38, 0xE9, 0x01)               # SEC / SBC #1
        a.abs_(0x8D, record_at + 4)            # STA frames.lo
        a.abs_(0xAD, record_at + 5)            # LDA frames.hi
        a.emit(0xE9, 0x00)                     # SBC #0 (borrow 포함)
        a.abs_(0x8D, record_at + 5)            # STA frames.hi
        a.abs_(0x0D, record_at + 4)            # ORA frames.lo
        a.branch(0xD0, "lifetime_push")       # 아직 남았다
        # SATB는 push보다 한 프레임 늦게 반영된다. 수명이 0이 된 프레임에
        # 바로 반환하면 직전 자막 스프라이트가 화면에 한 프레임 더 남아 있는
        # 동안 게임이 팔레트 15를 노란색으로 되돌릴 수 있다(「누구지?」).
        # 마지막 잔류 프레임도 흰색/검정으로 고정한 뒤 idle로 내린다.
        if palette_each_push:
            a.abs_(0x20, "palette_init")
        a.emit(0xA9, 0xFF); a.abs_(0x8D, "ready")
        a.emit(0x60)                           # RTS -- 이번 프레임부터 숨김
        a.label("lifetime_push")
    a.emit(0x4C); a.word("push")             # JMP push (긴 분기 회피)

    a.label("rebuild")
    if lookup:
        if timed and not overlay_palette:
            # Lua가 한 번 쓴 key 6 B를 다음 조각 선택자에도 보존한다.
            a.emit(0x73); a.word("selector"); a.word("next_selector"); a.word(6)
        # selector는 ADPCM 색인 항목의 앞 9 B(지문+flags+start_frame)다.
        # 엔진이 AC 색인을 선형 검색해 rec_off를 직접 얻는다.
        base.set_ac(a, index_base)
        if not 0 < index_count <= 0xFFFF:
            raise ValueError(f"ADPCM index count out of range: {index_count}")
        # 예전 X 카운터는 255개까지만 검색했다. 전체 음성 자막은 1,912조각이므로
        # 렌더러가 원래부터 작업용으로 쓰는 $15/$16을 조회 중에도 빌린다.
        # $18/$19는 게임 소유 여부를 측정하지 않은 주소라 사용하면 안 된다.
        if wide_lookup:
            a.emit(0xA9, index_count & 0xFF, 0x85, 0x15,
                   0xA9, index_count >> 8, 0x85, 0x16)
        else:
            if index_count > 0xFF:
                raise ValueError("narrow lookup count exceeds 255")
            a.emit(0xA2, index_count)
        a.label("index_loop")
        # record 버퍼를 13 B 색인 비교 버퍼로 재사용한다.
        a.emit(0xF3); a.word(base.AC_PORT); a.word("record"); a.word(13)
        a.emit(0xA0, 0x08)                       # 8..0 역순 비교
        a.label("index_compare")
        a.emit(0xB9); a.word("record")            # LDA index,Y
        a.emit(0xD9); a.word("selector")          # CMP selector,Y
        a.branch(0xD0, "index_next")
        a.emit(0x88); a.branch(0x10, "index_compare")  # DEY / BPL

        # rec_off u32의 하위 24 bit + record_base -> AC 포트 주소.
        # 검색 때 이미 자동증가를 설정했으므로 다시 설정하지 않는다.
        a.emit(0x18)
        for delta, port in ((0, 0x1A02), (1, 0x1A03), (2, 0x1A04)):
            a.abs_(0xAD, a.known.get("record", 0) + 9 + delta)
            a.emit(0x69, (record_base >> (delta * 8)) & 0xFF)
            a.abs_(0x8D, port)
        a.emit(0x4C); a.word("transfer_record")

        a.label("index_next")
        if wide_lookup:
            a.emit(0xA5, 0x15); a.branch(0xD0, "index_count_low")
            a.emit(0xC6, 0x16)
            a.label("index_count_low")
            a.emit(0xC6, 0x15, 0xA5, 0x15, 0x05, 0x16)
            a.branch(0xD0, "index_loop")
        else:
            a.emit(0xCA); a.branch(0xD0, "index_loop")
        a.abs_(0x9C, base.ENGINE_LO)               # 매직 해제: 재검색 폭주 방지
        a.emit(0x60)

    if not lookup:
        a.label("load_record")
        # Lua가 써 준 24-bit AC 레코드 주소를 포트 0에 건다.
        for delta, port in ((0, 0x1A02), (1, 0x1A03), (2, 0x1A04)):
            a.abs_(0xAD, a.known.get("record_ptr", 0) + delta)
            a.abs_(0x8D, port)
        a.emit(0xA9, 0x01); a.abs_(0x8D, 0x1A07)
        a.abs_(0x9C, 0x1A08)
        a.emit(0xA9, 0x11); a.abs_(0x8D, 0x1A09)
    a.label("transfer_record")
    a.emit(0xF3); a.word(base.AC_PORT); a.word("record"); a.word(RECORD_BYTES)

    # count=min(record.cells,19), half=record.width/2
    a.abs_(0xAD, "record")
    a.emit(0xC9, MAX_GLYPHS + 1)             # CMP #20
    a.branch(0x90, "count_ok")               # BCC
    a.emit(0xA9, MAX_GLYPHS)
    a.label("count_ok")
    a.abs_(0x8D, "count")
    a.emit(0x85, 0x15)                       # remaining
    a.abs_(0xAD, a.known.get("record", 0) + 1)
    a.emit(0x4A, 0x85, 0x17)                 # LSR A / STA half

    # $10/$11 = record cells, $16 = glyph index, X = list byte index
    cell = a.known.get("record", 0) + 6
    a.emit(0xA9, cell & 0xFF, 0x85, 0x10,
           0xA9, (cell >> 8) & 0xFF, 0x85, 0x11,
           0x64, 0x16, 0xA2, 0x00)
    if vdc_rearm:
        # 재무장판은 전송 직전에 매번 다시 고르므로 루프 밖 한 번짜리 셋업이
        # 필요 없다.  이 8 B 를 빼서 아래 in-loop 추가분을 상쇄한다.
        assert layout.PAT_VRAM & 0xFF == 0, "vdc_rearm needs 256-word aligned PAT_VRAM"
    else:
        base.set_vram_write(a, layout.PAT_VRAM)

    a.label("glyph_loop")
    # cell.glyph_id -> 24-bit 임시값 $12-$14, 그 뒤 x64
    a.emit(0xA0, 0x00, 0xB1, 0x10, 0x85, 0x12,
           0xC8, 0xB1, 0x10, 0x85, 0x13, 0x64, 0x14)
    for _ in range(6):
        a.emit(0x06, 0x12, 0x26, 0x13, 0x26, 0x14)  # ASL/ROL/ROL

    # glyph_base + glyph_id*64 -> AC 포트 주소
    a.emit(0x18, 0xA5, 0x12, 0x69, glyph_base & 0xFF); a.abs_(0x8D, 0x1A02)
    a.emit(0xA5, 0x13, 0x69, (glyph_base >> 8) & 0xFF); a.abs_(0x8D, 0x1A03)
    a.emit(0xA5, 0x14, 0x69, (glyph_base >> 16) & 0xFF); a.abs_(0x8D, 0x1A04)
    a.emit(0xF3); a.word(base.AC_PORT); a.word("stage"); a.word(base.GLYPH_BYTES)
    if vdc_rearm:
        # ★ VDC 의 레지스터 선택 래치는 하나뿐이고 되읽을 수 없다.  루프 밖에서
        # 한 번 고르고 19 글리프를 흘려보내면, 그 사이 래스터 분할 IRQ 가 VDC 를
        # 한 번만 건드려도 남은 글리프가 전부 엉뚱한 레지스터로 들어간다.
        # BYR 이면 세로 스크롤이 튀어 타일맵 위쪽이 화면으로 끌려나온다
        # (국장실에서 "위 그림이 중간중간 짧게 보이는" 증상).
        #
        # 그래서 전송 직전에 다시 고른다.  TIA 는 어차피 중단 불가라 PHP/SEI~PLP
        # 로 늘어나는 IRQ 지연은 아래 ST/LDA/STA 몇 개뿐이다.  SEI/CLI 가 아니라
        # PHP/PLP 인 것은 엔진이 IRQ 문맥에서 불릴 가능성을 배제하지 못했기 때문이다.
        #
        # 주소는 새 ZP 를 쓰지 않고 기존 글리프 인덱스 $16 에서 만든다.
        #     lo = ($16 & 3) << 6        hi = (PAT_VRAM >> 8) + ($16 >> 2)
        # PAT_VRAM 이 256워드 정렬이라 성립한다 (위 assert).
        a.emit(0x08, 0x78)                              # PHP / SEI
        a.emit(0x03, base.VDC_MAWR)                     # ST0 #MAWR
        a.emit(0xA5, 0x16, 0x29, 0x03)                  # LDA $16 / AND #$03
        a.emit(0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A)      # x64
        a.abs_(0x8D, 0x0002)                            # STA $0002 -> MAWR lo
        a.emit(0xA5, 0x16, 0x4A, 0x4A)                  # LDA $16 / LSR / LSR
        if rom_resident:
            a.emit(0x18)                                # CLC
            a.abs_(0x6D, "imm_vram_hi")                 # ADC $imm_vram_hi
        else:
            a.emit(0x18, 0x69)                          # CLC / ADC #hi
            a.label("vram_base_hi_imm")
            a.emit(layout.PAT_VRAM >> 8)
        a.abs_(0x8D, 0x0003)                            # STA $0003 -> MAWR hi
        a.emit(0x03, base.VDC_VWR)                      # ST0 #VWR
    a.emit(0xE3); a.word("stage"); a.word(base.VDC_VWR); a.word(base.SPRITE_WORDS * 2)
    if vdc_rearm:
        a.emit(0x28)                                    # PLP

    # 게임 $6463 형식의 5-byte 표시 레코드를 엔진 안에 만든다.
    list_at = a.known.get("list", 0)
    a.emit(0x9E); a.word(list_at + 0)         # STZ list+0,X
    a.emit(0x9E); a.word(list_at + 1)
    # 블록 전송 뒤 Y 보존을 전제하지 않고 cell.x 오프셋을 다시 명시한다.
    a.emit(0xA0, 0x02, 0xB1, 0x10, 0x38, 0xE5, 0x17)  # cell.x - width/2
    a.emit(0x9D); a.word(list_at + 2)
    pat_lo = (((layout.PAT_VRAM >> 6) << 1) & 0xFF)
    pat_hi = (((layout.PAT_VRAM >> 6) << 1) >> 8)
    attr = 0x80 | ((pat_hi & 7) << 4) | PALETTE
    if rom_resident:
        a.emit(0xA5, 0x16, 0x0A, 0x18)                  # LDA $16 / ASL / CLC
        a.abs_(0x6D, "imm_pat_lo")                      # ADC $imm_pat_lo
        a.emit(0x9D); a.word(list_at + 3)
        a.abs_(0xAD, "imm_attr")                        # LDA $imm_attr
        a.emit(0x9D); a.word(list_at + 4)
    else:
        a.emit(0xA5, 0x16, 0x0A, 0x18, 0x69)
        a.label("pattern_base_lo_imm")
        a.emit(pat_lo)
        a.emit(0x9D); a.word(list_at + 3)
        a.emit(0xA9)
        a.label("pattern_attr_imm")
        a.emit(attr, 0x9D); a.word(list_at + 4)

    # 다음 cell(+3), 다음 list(+5), 다음 glyph
    a.emit(0x18, 0xA5, 0x10, 0x69, 0x03, 0x85, 0x10)
    a.branch(0x90, "cell_no_carry")
    a.emit(0xE6, 0x11)
    a.label("cell_no_carry")
    a.emit(0xE8, 0xE8, 0xE8, 0xE8, 0xE8, 0xE6, 0x16, 0xC6, 0x15)
    a.branch(0xF0, "glyph_done")
    a.emit(0x4C); a.word("glyph_loop")
    a.label("glyph_done")

    # 스프라이트 팔레트 15: 색1 흰색, 색2 검정.
    # safe timed 판은 이 31 B 루틴을 stage 버퍼에 겹쳐 두고 최초에만 실행한다.
    if not overlay_palette:
        vce = 0x100 + PALETTE * 16 + 1
        for value, port in ((vce & 0xFF, base.VCE_ADDR_LO), (vce >> 8, base.VCE_ADDR_HI),
                            (0xFF, base.VCE_DATA_LO), (0x01, base.VCE_DATA_HI),
                            (0x00, base.VCE_DATA_LO), (0x00, base.VCE_DATA_HI)):
            a.emit(0xA9, value); a.abs_(0x8D, port)
    a.emit(0xA9, 0x01); a.abs_(0x8D, "ready")

    a.label("push")
    # 트랙 5처럼 게임이 스프라이트 팔레트 15를 노란색으로 계속 갱신하는
    # 장면에서도 자막 본체(색1)는 흰색, 외곽(색2)은 검정으로 유지한다.
    # ROM 상주 CD-DA에만 켜므로 ADPCM 렌더러의 바이트/동작은 바뀌지 않는다.
    if palette_each_push:
        a.abs_(0x20, "palette_init")
    # y=record.y+64, x=128+32. $17은 훅의 원래 슬롯 예산으로 복구한다.
    a.emit(0x18); a.abs_(0xAD, a.known.get("record", 0) + 3)
    a.emit(0x69, 64, 0x85, 0x08, 0xA9, 0x00, 0x69, 0x00, 0x85, 0x09)
    a.emit(0xA9, 160, 0x85, 0x0A, 0x64, 0x0B,
           0x64, 0x0C, 0x64, 0x0D, 0x64, 0x0E, 0x64, 0x0F)
    a.emit(0xA9, (a.known.get("list", 0)) & 0xFF, 0x85, 0x10,
           0xA9, (a.known.get("list", 0) >> 8) & 0xFF, 0x85, 0x11)
    a.abs_(0xAD, "count"); a.emit(0x85, 0x16, 0xA9, 0x3F, 0x85, 0x17)
    a.abs_(0x20, base.PUSH_LOOP)
    a.emit(0x60)

    if overlay_palette and rom_resident:
        # ROM 상주 CD-DA 판의 최초 팔레트 초기화.  기존 RAM 엔진은 stage에
        # 겹쳐 놓아야 했지만, 이 코드는 ROM에 있으므로 stage를 전부 캐시로 쓸 수
        # 있다.  JSR로만 진입하며 push의 RTS 뒤라 흘러들지 않는다.
        a.label("palette_init")
        # 글리프 원본은 2 plane = 64 B지만 VDC에는 4 plane = 128 B를 보낸다.
        # RAM 엔진은 템플릿 복사로 뒤 64 B가 이미 0이었다. ROM 판은 데이터
        # 템플릿을 복사하지 않으므로 명시적으로 지우지 않으면 게임 스택의 값이
        # 상위 plane이 되어 분홍 바탕/깨진 획으로 보인다 (0.5.11-rom-dev 실기).
        a.emit(0xA2, base.GLYPH_BYTES - 1)               # LDX #63
        a.label("clear_upper_planes")
        a.emit(0x9E); a.word(a.known.get("stage", 0) + base.GLYPH_BYTES)
        a.emit(0xCA); a.branch(0x10, "clear_upper_planes")
        vce = 0x100 + PALETTE * 16 + 1
        for value, port in ((vce & 0xFF, base.VCE_ADDR_LO), (vce >> 8, base.VCE_ADDR_HI),
                            (0xFF, base.VCE_DATA_LO), (0x01, base.VCE_DATA_HI),
                            (0x00, base.VCE_DATA_LO), (0x00, base.VCE_DATA_HI)):
            a.emit(0xA9, value); a.abs_(0x8D, port)
        a.emit(0x60)

    a.label("ready"); a.emit(0)
    if not lookup:
        a.label("record_ptr"); a.emit(0, 0, 0)
    a.label("count"); a.emit(0)
    if rom_resident:
        # ROM 상주판에서 자기수정 즉치 3 개가 나와 앉는 자리.  구워진 값은
        # 무장 초기화가 그대로 쓰면 되는 기본값이다 (스케줄러가 구간마다 덮는다).
        a.label("imm_vram_hi"); a.emit(layout.PAT_VRAM >> 8)
        a.label("imm_pat_lo"); a.emit(pat_lo)
        a.label("imm_attr"); a.emit(attr)
        # ★ 트랙 BCD.  지금은 렌더러 이미지의 **패딩**(+660)에 얹혀 있는데,
        #   ROM 상주판에는 패딩이 없다 (코드는 ROM · 데이터만 RAM).
        #   그래서 데이터 블록 안으로 들여온다.  스케줄러는 절대 주소를 인자로
        #   받으므로(`track_byte_cpu`) 그쪽 코드는 한 줄도 안 바뀐다.
        a.label("track_bcd"); a.emit(0)
    if lookup:
        a.label("selector")                    # list 앞 9 B를 토큰으로 재사용
    a.label("list")
    if timed:
        if len(first_suffix) != 3 or len(next_suffix) != 3 or len(next_key) != 6:
            raise ValueError("timed selector suffix must be 3 bytes")
        initial = bytearray(LIST_BYTES)
        initial[6:9] = first_suffix
        if overlay_palette:
            initial[80:86] = next_key
        initial[80 + 6:80 + 9] = next_suffix
        a.emit(*initial[:80])
        a.label("next_selector"); a.emit(*initial[80:89])
        a.label("elapsed"); a.emit(0)
        if wide_timer:
            a.emit(0)
            a.emit(*initial[91:])
        else:
            a.emit(*initial[90:])
    else:
        a.emit(*([0] * LIST_BYTES))
    if lookup:
        a.label("index")                       # record 앞 13 B를 비교에 재사용
    a.label("record"); a.emit(*([0] * RECORD_BYTES))
    a.label("stage")
    stage = bytearray(base.SPRITE_WORDS * 2)
    if overlay_palette and not rom_resident:
        vce = 0x100 + PALETTE * 16 + 1
        init = bytearray()
        for value, port in ((vce & 0xFF, base.VCE_ADDR_LO), (vce >> 8, base.VCE_ADDR_HI),
                            (0xFF, base.VCE_DATA_LO), (0x01, base.VCE_DATA_HI),
                            (0x00, base.VCE_DATA_LO), (0x00, base.VCE_DATA_HI)):
            init += bytes((0xA9, value, 0x8D, port & 0xFF, port >> 8))
        init += b"\x60"                       # RTS
        stage[:len(init)] = init
    a.emit(*stage)
    if blank_frame:
        # ★ 맨 끝에 둔다 -- 앞의 오프셋을 하나도 안 민다.
        #   armer 가 arm 할 때마다 AC 템플릿에서 engine_bytes 만큼 복사하므로
        #   음성이 바뀔 때 0 으로 초기화된다.
        a.label("blank"); a.emit(0)
    return a.finish(), a.labels


def main() -> None:
    blob = PACK.read_bytes()
    if blob[:4] != b"SNSB" or struct.unpack_from("<H", blob, 4)[0] != 6:
        raise SystemExit("subtitle pack must be SNSB v6")
    glyph_off, = struct.unpack_from("<I", blob, 10)
    glyph_base = layout.AC_PACK + glyph_off
    first, labels = build(None, glyph_base)
    engine, labels = build(labels, glyph_base)
    if len(first) != len(engine) or len(engine) > base.ENGINE_BYTES:
        raise SystemExit(f"engine size invalid: {len(engine)} / {base.ENGINE_BYTES}")
    OUT.write_bytes(engine)
    offsets = {name: address - base.ENGINE_LO for name, address in labels.items()}
    INFO.write_text(json.dumps({"engine_bytes": len(engine),
        "free": base.ENGINE_BYTES - len(engine), "glyph_base": f"{glyph_base:06X}",
        "max_glyphs": MAX_GLYPHS, "record_bytes": RECORD_BYTES,
        "offsets": offsets}, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"AC record POC engine {len(engine)} B / {base.ENGINE_BYTES} B")
    print(f"generic record <= {MAX_GLYPHS} glyphs · glyph base AC ${glyph_base:06X}")
    print(OUT)


if __name__ == "__main__":
    main()
