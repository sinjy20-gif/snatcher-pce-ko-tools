-- ★ HQ 0.5.0 -- 종료 판정이 왜 안 걸리나 (2026-09-06)
--
-- 0.4.0 이 확정한 것
-- -----------------
-- STATE 쓰기 38 회를 시간순으로 보면 정상 주기가 뚜렷하다:
--
--     01(pc FCA9) -> 02(pc 7F75) -> 03(pc FC38) -> 00(pc 7F7A)
--     프레임 4793~6786 사이에 9 번 깨끗하게 반복 (ADPCM)
--
-- 그런데 트랙 3 에서 끊긴다:
--
--     7980  01(pc FCA9) -> 02        무장.  03 이 안 온다
--     9035  01(pc F021) -> 02        ★이사가 재무장 (F021 = 스케줄러 끝부분)
--           이후 쓰기 없음.  STATE = 02 로 영원히
--
-- 그리고 뱅크 가설은 죽었다 -- 쓰기 38 중 MPR3!=69 는 부팅 때 1 번뿐,
-- 읽기 28,224 회는 전부 $69 였다.
--
-- 이 판이 보는 것
-- --------------
-- 스케줄러의 종료 판정은 이렇다:
--
--     LDA $20A2          ; CD_SUBQ 현재 트랙 BCD
--     CMP 렌더러+660     ; cdda_start 가 심어 둔 "이 트랙" BCD
--     BEQ cdda_playing
--     JMP cdda_finished  ; -> STATE=3
--
-- 두 값이 **영원히 같으면** 종료가 안 걸린다.  이사가 STATE=1 을 쓰면 상주부가
-- 렌더러를 AC 에서 다시 복사하는데, 그때 심어둔 BCD 가 어떻게 되는지가 관건이다.
--
--     렌더러 CPU 슬롯 = $5B80
--     +660 = $5E14   트랙 BCD (종료 판정의 오른쪽 값)
--     +661 = $5E15   이사 번호 (한 번 쓰면 0 으로 지우는 일회용 표식)
--
-- 판정
--     $20A2 가 03 -> 04 로 바뀐 뒤에도 $5E14 가 03 이면  -> 판정이 걸려야 하는데 안 걸린 것
--     $5E14 가 0 이나 엉뚱한 값이 되어 있으면           -> ★재복사가 BCD 를 날린 것
--     $20A2 가 계속 03 이면                              -> CD 가 안 끝난 것.  판정 자체는 정상
--
-- 읽기 전용.  화면에 아무것도 안 그린다.
--
-- 산출  dump/hq_0_5_0_finish_gate_<시각>.tsv

local VERSION = '0.5.0'
local MEM = emu.memType.pceMemory

local STATE_AT  = 0x7FDF
local SLOT      = 0x5B80
local TRACK_BCD = SLOT + 660      -- $5E14  종료 판정의 오른쪽 값
local MOVE_BYTE = SLOT + 661      -- $5E15  이사 번호
local CD_SUBQ   = 0x20A2          -- 종료 판정의 왼쪽 값
local CD_RAW    = 0x26F9

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_finish_gate_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\twhy\tstate\tsubq\tbcd\tmove\tcd_raw\tmatch\tpc\n')

local function rb(at) return emu.read(at, MEM) or 0 end

local frame, prev, lastChange, stalled, rows = 0, nil, 0, false, 0

local function snap()
  local s = emu.getState() or {}
  local subq, bcd = rb(CD_SUBQ), rb(TRACK_BCD)
  return {
    state = rb(STATE_AT), subq = subq, bcd = bcd,
    move = rb(MOVE_BYTE), raw = rb(CD_RAW),
    match = (subq == bcd) and 'SAME' or 'DIFF',
    pc = s['cpu.pc'] or 0,
  }
end

local function emit(v, why)
  out:write(string.format('%d\t%s\t%02X\t%02X\t%02X\t%02X\t%02X\t%s\t%04X\n',
    frame, why, v.state, v.subq, v.bcd, v.move, v.raw, v.match, v.pc))
  out:flush()
  rows = rows + 1
end

-- STATE 쓰기는 따로 크게 남긴다 (0.4.0 과 이어서 읽을 수 있게)
emu.addMemoryCallback(function(address, value)
  local v = snap()
  v.state = value or v.state
  emit(v, 'STATE=' .. string.format('%02X', value or 0))
end, emu.callbackType.write, STATE_AT, STATE_AT, emu.cpuType.pce, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  local v = snap()
  local k = string.format('%02X|%02X|%02X|%02X|%02X', v.state, v.subq, v.bcd, v.move, v.raw)
  if prev == nil then emit(v, 'start'); prev, lastChange = k, frame; return end
  if k ~= prev then emit(v, 'change'); prev, lastChange = k, frame; stalled = false; return end
  if not stalled and frame - lastChange > 300 then
    emit(v, 'STALL300'); stalled = true
    emu.log(string.format(
      '★ STALL -- state=%02X  subq=%02X  렌더러BCD=%02X  (%s)  이사바이트=%02X',
      v.state, v.subq, v.bcd, v.match, v.move))
  end
  if frame % 600 == 0 then emit(v, 'beat') end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(string.format('# rows=%d frames=%d\n', rows, frame))
  out:close()
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' -- 종료 판정 두 값을 나란히 본다 · 읽기 전용')
emu.log('  왼쪽 $20A2 (CD 현재 트랙 BCD) · 오른쪽 $5E14 (렌더러가 든 트랙 BCD)')
emu.log('  둘이 DIFF 가 되는 순간 STATE=3 이 나와야 한다')
emu.log('  -> ' .. OUT)
