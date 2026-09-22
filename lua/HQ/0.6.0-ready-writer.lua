-- ★ HQ 0.6.0 -- `ready` 를 누가 계속 되살리나 (2026-09-06)
--
-- 여기까지 확정된 것
-- -----------------
-- 0.4.0  트랙 3 이 끝나도 `STATE=3` 이 **한 번도** 안 쓰인다.  STATE=02 로 영원히.
--        (정상 주기는 01->02->03->00.  ADPCM 에서 9 번 깨끗하게 돌았다)
-- 0.4.0  뱅크 가설은 죽었다 -- 읽기 28,224 회 전부 MPR3=$69.
-- 0.5.0  종료 판정의 **두 값은 이미 DIFF 다**:
--            subq($20A2)=04   렌더러BCD($5E14)=03   -> DIFF
--        즉 `cdda_finished` 로 가야 하는 조건이 이미 참인데 STATE 가 안 바뀐다.
--
-- 그래서 무엇을 의심하나
-- --------------------
-- `cdda_finished` 는 **2 단 지연**이다:
--
--     cdda_finished:
--         LDA ready
--         BEQ cdda_state3      ; 이미 0 = 두 번째 프레임 -> STATE=3
--         STZ ready            ; 첫 프레임: ready 만 내리고 나간다
--         BRA cdda_store
--
-- `ready` 가 매 프레임 다시 비0 이 되면 **영원히 첫 프레임**이다.
-- STZ -> (누군가 되살림) -> STZ -> ... 무한 반복.  STATE=3 은 안 온다.
--
-- 유력한 되살리는 자: **이사**.  `cdda_move` 가 `STATE=1` 을 쓰면 상주부가
-- 렌더러를 AC 에서 다시 복사한다.  그 복사가 `ready` 를 템플릿 값(구운 초기값
-- $FF)으로 되돌리면 정확히 이 그림이 된다.
--
-- 이 판이 하는 일
-- --------------
--   1  `ready`($5CC6) 에 대한 **쓰기 콜백** -- 누가(pc) 무슨 값을 쓰는지 전부
--   2  STATE($7FDF) 쓰기도 같이 (0.4.0/0.5.0 과 이어 읽게)
--   3  프레임마다 ready · part · count · subq · 렌더러BCD 를 변할 때만
--
-- 판정
--     막힌 뒤 ready 에 $FF/$FE 를 쓰는 pc 가 반복해서 보인다  -> ★그 pc 가 범인
--     ready 가 0 인 채 가만히 있는데도 STATE=3 이 없다        -> 스케줄러가 아예
--                                                               안 불린다.  다른 데를 판다
--
-- 읽기 전용.  화면에 아무것도 안 그린다.
--
-- 산출  dump/hq_0_6_0_ready_writer_<시각>.tsv

local VERSION = '0.6.0'
local MEM = emu.memType.pceMemory

local STATE_AT  = 0x7FDF
local READY_AT  = 0x5CC6      -- 렌더러 +326
local SLOT      = 0x5B80
local TRACK_BCD = SLOT + 660  -- $5E14
local MOVE_BYTE = SLOT + 661  -- $5E15
local CD_SUBQ   = 0x20A2
local SCHED_LO  = 0x2100      -- +3 part · +4 count (X 색인)

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_ready_writer_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\twhy\tval\tstate\tready\tsubq\tbcd\tmove\tsched\tpc\n')

local function rb(at) return emu.read(at, MEM) or 0 end

local function schedHex()
  local t = {}
  for i = 0, 11 do t[#t + 1] = string.format('%02X', rb(SCHED_LO + i)) end
  return table.concat(t)
end

local frame, prev, lastChange, stalled, rows = 0, nil, 0, false, 0
local readyWriters = {}       -- pc -> 횟수

local function emit(why, val)
  local s = emu.getState() or {}
  out:write(string.format('%d\t%s\t%s\t%02X\t%02X\t%02X\t%02X\t%02X\t%s\t%04X\n',
    frame, why, val and string.format('%02X', val) or '--',
    rb(STATE_AT), rb(READY_AT), rb(CD_SUBQ), rb(TRACK_BCD), rb(MOVE_BYTE),
    schedHex(), s['cpu.pc'] or 0))
  out:flush()
  rows = rows + 1
end

emu.addMemoryCallback(function(address, value)
  local s = emu.getState() or {}
  local pc = s['cpu.pc'] or 0
  readyWriters[pc] = (readyWriters[pc] or 0) + 1
  -- 같은 pc 가 같은 값을 반복해서 쓰면 앞의 40 번만 남긴다 (파일 폭발 방지)
  if readyWriters[pc] <= 40 then
    emit('ready<-' .. string.format('%02X', value or 0), value)
  end
end, emu.callbackType.write, READY_AT, READY_AT, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function(address, value)
  emit('STATE<-' .. string.format('%02X', value or 0), value)
end, emu.callbackType.write, STATE_AT, STATE_AT, emu.cpuType.pce, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  local k = string.format('%02X|%02X|%02X|%02X|%02X|%s',
    rb(STATE_AT), rb(READY_AT), rb(CD_SUBQ), rb(TRACK_BCD), rb(MOVE_BYTE), schedHex())
  if prev == nil then emit('start'); prev, lastChange = k, frame; return end
  if k ~= prev then emit('change'); prev, lastChange = k, frame; stalled = false; return end
  if not stalled and frame - lastChange > 300 then
    emit('STALL300'); stalled = true
    emu.log(string.format('★ STALL -- state=%02X ready=%02X subq=%02X bcd=%02X move=%02X',
      rb(STATE_AT), rb(READY_AT), rb(CD_SUBQ), rb(TRACK_BCD), rb(MOVE_BYTE)))
  end
  if frame % 900 == 0 then emit('beat') end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write('# ready 를 쓴 pc 별 횟수\n')
  local list = {}
  for pc, n in pairs(readyWriters) do list[#list + 1] = { pc, n } end
  table.sort(list, function(a, b) return a[2] > b[2] end)
  for i = 1, math.min(#list, 20) do
    out:write(string.format('#   pc %04X : %d\n', list[i][1], list[i][2]))
    emu.log(string.format('ready 쓴 pc %04X : %d 회', list[i][1], list[i][2]))
  end
  out:write(string.format('# rows=%d frames=%d\n', rows, frame))
  out:close()
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' -- ready($5CC6) 를 누가 되살리나 · 읽기 전용')
emu.log('  cdda_finished 는 ready==0 을 두 프레임 봐야 STATE=3 을 쓴다')
emu.log('  -> ' .. OUT)
