-- ★ HQ 0.1.0 -- 국장실 "UI 복귀 실패" 포착 (2026-09-06)
--
-- 증상 (소유자, 0.5.14 실기):
--     "이 화면에서 CD-DA 출력후 그대로 진행이 안된다"
--     "프리징이라고 하면 뭐하네 / 노래는 나오니까 / UI복귀 실패인거지"
--
-- 즉 시스템은 살아 있는데 게임 스크립트만 다음으로 안 넘어간다.
--
-- 무엇을 의심하나
-- ---------------
-- 엔진 슬롯 $5B80 (704 B) 은 **게임 것**이다.  우리 상주부가 잠깐 빌려 쓰고
-- STATE($7FDF)=3 을 받으면 원래 내용을 복원해 돌려준다:
--
--     STATE 0  아무것도 안 함
--           1  헬퍼 복사 + ENTRY(save) + 렌더러 복사 -> STATE=2
--           2  슬롯 내용을 돌린다 (우리 렌더러)
--           3  헬퍼 복사 + command=restore + ENTRY -> STATE=0   ← 반납
--
-- 3 이 안 오면 게임은 그 자리에서 돌려야 할 **자기 코드**를 영영 못 돌린다.
-- 소리(CD-DA/ADPCM)는 하드웨어가 계속 내므로 "노래는 나온다" 와 맞는다.
--
-- 그래서 이 프로브는 딱 이것만 본다: **STATE 가 언제 무엇으로 바뀌는가,
-- 그리고 슬롯 $5B80 에 지금 누구 코드가 들어 있는가.**
--
-- 읽기 전용이다.  화면에 아무것도 안 그린다 (덮으면 판정을 막는다).
--
-- 쓰는 법
--     Power Cycle -> 이 파일 하나만 로드 -> 트랙 3 장면을 국장실까지 진행
--     막히면 그대로 두고 20 초쯤 더 둔다 (STALL 표식이 찍히게)
--
-- 산출  dump/hq_0_1_0_ui_return_<시각>.tsv
--
-- ⚠ 판을 고치면 **버전과 산출 경로를 같이 올릴 것.**  로그만 있고 그 로그를
--   만든 코드가 없으면 못 읽는다.

local VERSION = '0.1.0'
local MEM = emu.memType.pceMemory

local STATE_AT   = 0x7FDF      -- 상주부/스케줄러가 공유하는 상태 바이트
local SLOT       = 0x5B80      -- 엔진 슬롯 (게임 것.  빌려 쓴다)
local CD_RAW     = 0x26F9      -- & $7F = 현재 트랙 raw.  무장 게이트가 쓰는 값
local CD_BCD     = 0x20A2      -- CD_SUBQ 현재 트랙 BCD.  정지/전환을 잡는다
local ADPCM_ST   = 0x180D      -- bit $20 = ADPCM 재생 중
local FRAME_CLK  = 0x201B      -- VBlank 마다 오르는 게임 카운터
local SKIP_INPUT = 0x222D      -- 게임의 스킵 판정 바이트 (& $0C)
local SCHED_LO   = 0x2100      -- 스케줄러 지역변수 블록 (X 로 색인)

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_ui_return_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\tclk\twhy\tstate\tslot0\tslot1\tslot2\tslot3\t'
       .. 'cd_raw\tcd_bcd\tadpcm\tskip\tsched\tpc\n')

local function rb(at) return emu.read(at, MEM) or 0 end

local function schedHex()
  -- $2100..$210F 16 B.  어느 X 를 쓰는지 몰라도 통째로 보면 흐름이 보인다.
  local t = {}
  for i = 0, 15 do t[#t + 1] = string.format('%02X', rb(SCHED_LO + i)) end
  return table.concat(t)
end

local frame = 0
local prev = nil
local lastChangeFrame = 0
local stalled = false
local rows = 0

local function snap()
  local s = emu.getState() or {}
  return {
    state = rb(STATE_AT),
    s0 = rb(SLOT), s1 = rb(SLOT + 1), s2 = rb(SLOT + 2), s3 = rb(SLOT + 3),
    raw = rb(CD_RAW), bcd = rb(CD_BCD),
    adpcm = rb(ADPCM_ST), skip = rb(SKIP_INPUT),
    clk = rb(FRAME_CLK),
    sched = schedHex(),
    pc = s['cpu.pc'] or s['cpu.programCounter'] or 0,
  }
end

local function key(v)
  -- clk 와 pc 는 매 프레임 바뀌므로 "변했다" 판정에서 뺀다.
  return string.format('%02X %02X%02X%02X%02X %02X %02X %02X %02X %s',
    v.state, v.s0, v.s1, v.s2, v.s3, v.raw, v.bcd, v.adpcm, v.skip, v.sched)
end

local function emit(v, why)
  out:write(string.format(
    '%d\t%d\t%s\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%s\t%04X\n',
    frame, v.clk, why, v.state, v.s0, v.s1, v.s2, v.s3,
    v.raw, v.bcd, v.adpcm, v.skip, v.sched, v.pc))
  out:flush()
  rows = rows + 1
end

emu.addEventCallback(function()
  frame = frame + 1
  local v = snap()
  local k = key(v)

  if prev == nil then
    emit(v, 'start')
    prev, lastChangeFrame = k, frame
    return
  end

  if k ~= prev then
    emit(v, 'change')
    prev, lastChangeFrame = k, frame
    stalled = false
    return
  end

  -- 아무것도 안 변한 채 오래 머문다 = 막힌 자리.  한 번만 크게 찍는다.
  if not stalled and frame - lastChangeFrame > 300 then
    emit(v, 'STALL300')
    stalled = true
    emu.log(string.format(
      '★ STALL -- 300 프레임 동안 변화 없음.  state=%02X slot=%02X%02X%02X%02X'
      .. ' cd_raw=%02X cd_bcd=%02X', v.state, v.s0, v.s1, v.s2, v.s3, v.raw, v.bcd))
  end

  -- 심박.  막힌 뒤에도 clk/pc 는 도는지(=시스템은 살아있는지) 남긴다.
  if frame % 300 == 0 then emit(v, 'beat') end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(string.format('# rows=%d frames=%d\n', rows, frame))
  out:close()
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' -- 국장실 UI 복귀 실패 포착 · 읽기 전용')
emu.log('  STATE $7FDF · 슬롯 $5B80 · CD $26F9/$20A2 · ADPCM $180D · 스케줄러 $2100')
emu.log('  변화가 있을 때만 기록한다.  300 프레임 정지하면 STALL300')
emu.log('  -> ' .. OUT)
