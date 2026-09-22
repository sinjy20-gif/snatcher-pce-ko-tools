-- ★ HQ 0.4.0 -- $7FDF 에 쓰는 **그 순간**의 MPR3 을 찍는다 (2026-09-06)
--
-- 0.3.1 이 무엇을 보여줬고, 무엇을 못 보여줬나
-- -------------------------------------------
-- 보여준 것:
--     STATE 가 EA 로 읽힌 660 행  ->  MPR3 = $6A   (660/660)
--     STATE 가 정상인 3,440 행    ->  MPR3 = $69   (3,440/3,440)
--
-- 못 보여준 것:  **$6A 구간은 전부 정확히 1 프레임짜리였고 660 번 있었다.**
--     첫 등장이 프레임 494 로 트랙 3 한참 전이다 (cd_raw=15).
--     즉 게임이 상시로 잠깐씩 끼웠다 빼는 뱅크다.
--
--     0.3.1 은 **프레임 끝**에서 쟀다.  우리 코드가 도는 순간이 아니다.
--     그러니 "우리가 STATE 를 쓸 때 $6A 였다" 는 말할 수 없다.
--     0.3.1 로 "확정" 이라고 한 것은 과했다.
--
-- 이 판이 하는 일
-- --------------
-- `$7FDF` 에 대한 **쓰기/읽기 콜백**을 걸어, 그 순간의 MPR3 을 같이 남긴다.
-- 프레임 끝이 아니라 **접근하는 바로 그 사이클**이다.
--
--     쓰기가 한 번이라도 MPR3 != $69 에서 일어났다  ->  ★버그 확정
--         우리가 뱅크 $6A 에 STATE 를 쓰고 있다 = 반납 신호가 사라지고
--         게임 데이터도 오염된다
--     전부 $69 에서만 일어났다                     ->  STATE 자리는 무죄
--         다른 데를 판다
--
-- 읽기 전용.  화면에 아무것도 안 그린다.
--
-- 쓰는 법
--     Power Cycle -> 이 파일 하나만 -> 트랙 3 을 국장실까지 -> 막히면 20 초 더
--
-- 산출  dump/hq_0_4_0_state_write_mpr_<시각>.tsv

local VERSION = '0.4.0'
local MEM = emu.memType.pceMemory
local STATE_AT = 0x7FDF

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_state_write_mpr_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\tkind\tvalue\tmpr3\tmpr2\tmpr\tpc\n')

local frame = 0
local rows = 0
local writes = 0
local badWrites = 0
local reads = 0
local badReads = 0
local lastKey = nil

local function mprOf(s)
  local t = {}
  for i = 0, 7 do
    t[#t + 1] = string.format('%02X', s['memoryManager.mpr[' .. i .. ']'] or 0)
  end
  return t
end

local function record(kind, value)
  local s = emu.getState() or {}
  local t = mprOf(s)
  local m3, m2 = t[4], t[3]          -- Lua 는 1 기반.  t[4] = mpr[3]
  local pc = s['cpu.pc'] or 0

  if kind == 'write' then
    writes = writes + 1
    if m3 ~= '69' then badWrites = badWrites + 1 end
  else
    reads = reads + 1
    if m3 ~= '69' then badReads = badReads + 1 end
  end

  -- 같은 (종류·값·MPR3·PC) 가 반복되면 안 적는다.  파일이 폭발하지 않게.
  local k = kind .. (value or -1) .. m3 .. string.format('%04X', pc)
  if k == lastKey and m3 == '69' then return end
  lastKey = k

  out:write(string.format('%d\t%s\t%s\t%s\t%s\t%s\t%04X\n',
    frame, kind, value and string.format('%02X', value) or '--',
    m3, m2, table.concat(t, ' '), pc))
  out:flush()
  rows = rows + 1

  if m3 ~= '69' then
    emu.log(string.format('★★ %s $7FDF 인데 MPR3=$%s (값 %s · pc %04X · frame %d)',
      kind, m3, value and string.format('%02X', value) or '--', pc, frame))
  end
end

emu.addMemoryCallback(function(address, value)
  record('write', value)
end, emu.callbackType.write, STATE_AT, STATE_AT, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function(address, value)
  record('read', value)
end, emu.callbackType.read, STATE_AT, STATE_AT, emu.cpuType.pce, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 1800 == 0 then
    emu.log(string.format('frame %d · 쓰기 %d (★밖 %d) · 읽기 %d (★밖 %d)',
      frame, writes, badWrites, reads, badReads))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(string.format('# frames=%d rows=%d writes=%d badWrites=%d reads=%d badReads=%d\n',
    frame, rows, writes, badWrites, reads, badReads))
  out:close()
  emu.log(string.format('★ 최종: 쓰기 %d 중 MPR3!=69 가 %d · 읽기 %d 중 %d',
    writes, badWrites, reads, badReads))
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' -- $7FDF 접근 순간의 MPR3 · 읽기 전용')
emu.log('  MPR3 != $69 에서 쓰기가 한 번이라도 있으면 ★★ 로 로그에 뜬다')
emu.log('  -> ' .. OUT)
