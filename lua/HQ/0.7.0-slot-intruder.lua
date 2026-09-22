-- ★ HQ 0.7.0 -- 슬롯 $5B80-$5E1E 를 **게임이 건드리는 순간**을 잡는다 (2026-09-06)
--
-- 왜 이 판인가
-- ------------
-- 여기까지 추측으로 세 판(0.5.15/16/17)을 구웠고 전부 안 됐다.  소유자 지적:
--
--     "뭘로 굽는데 자꾸 추측만할거야?  측정을 해야지 어디서 복귀가 막히는지"
--
-- 맞다.  그래서 굽기 전에 잰다.
--
-- 무엇을 아는가
-- ------------
--   · 국장실은 **CD-DA 자동 진행으로 들어갈 때만** 깨진다.  걸어 들어가면 멀쩡
--   · 그 순간 STATE 는 02 (무장 중) -- 0.6.0 실측, 트랙 내내 유지
--   · 자막 한 줄을 빼도(0.5.17) 그대로 깨진다 -> 그 순간의 VRAM 쓰기는 무죄
--   · 슬롯 671 B 는 **게임의 스크립트 VM 데이터 스택**이다
--     (docs/handoff/SNATCHER_CPU_CACHE_ROOT_CAUSE_2026-09-01.md)
--
-- 그 문서의 `0.5.104` 는 읽기 콜백으로 이것을 증명했다:
--
--     9607f READ $5B83  pc=$70BF ★게임  val=$AD      <- 헬퍼 entry 기계어
--     9607f READ $5B84  pc=$70BF ★게임  val=$30
--            ...  $5BA7 까지 순차 (블록 복사)
--
-- 이 판이 하는 일
-- --------------
-- `$5B80-$5E1E` 전체에 읽기·쓰기 콜백을 걸고, **접근한 PC 가 슬롯 밖일 때만**
-- 남긴다.  슬롯 안에서의 접근은 우리 렌더러/헬퍼가 자기 코드를 도는 것이라
-- 관심 없다.
--
--   pc $5B80-$5E1E   우리 코드가 자기 안에서 -- 안 남긴다
--   pc $7F00-$7FFF   상주부 (save/restore) -- ★남긴다.  반납이 실제로 도는지
--   그 밖             ★게임이다.  이게 증거다
--
-- 판정
--   국장실 진입 무렵 게임 PC 가 슬롯을 **읽는다**   -> 671 B 기전 확정.
--       그 pc 와 주소가 "어디서 막히는지" 를 그대로 알려준다
--   게임이 안 건드린다                              -> 671 B 는 무죄.
--       VRAM 이나 다른 자원을 봐야 한다
--
-- 읽기 전용.  화면에 아무것도 안 그린다.
--
-- 쓰는 법
--   Power Cycle -> 이 파일 하나만 -> 트랙 3 을 **자동 진행으로** 국장실까지
--   깨지면 그대로 20 초 더 둔다
--
-- 산출  dump/hq_0_7_0_slot_intruder_<시각>.tsv

local VERSION = '0.7.0'
local MEM = emu.memType.pceMemory

local SLOT_LO, SLOT_HI = 0x5B80, 0x5E1E
local STATE_AT = 0x7FDF
local CD_RAW   = 0x26F9
local CD_BCD   = 0x20A2

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_slot_intruder_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\tkind\twho\taddr\tval\tstate\tcd_raw\tcd_bcd\tpc\n')

local function rb(at) return emu.read(at, MEM) or 0 end

local frame, rows = 0, 0
local seen = {}          -- "kind|pc" -> 횟수.  같은 자리는 앞의 것만 남긴다
local firstByPc = {}     -- pc -> 처음 만난 프레임 (요약용)
local KEEP_PER_PC = 12

local function who(pc)
  if pc >= SLOT_LO and pc <= SLOT_HI then return 'slot' end   -- 우리 코드 자신
  if pc >= 0x7F00 and pc <= 0x7FFF then return 'resident' end -- 상주부
  return 'GAME'
end

local function record(kind, address, value)
  local s = emu.getState() or {}
  local pc = s['cpu.pc'] or 0
  local w = who(pc)
  if w == 'slot' then return end            -- 우리 코드가 자기 안을 도는 것

  local key = kind .. '|' .. pc
  seen[key] = (seen[key] or 0) + 1
  if firstByPc[pc] == nil then firstByPc[pc] = frame end
  if seen[key] > KEEP_PER_PC then return end

  out:write(string.format('%d\t%s\t%s\t%04X\t%s\t%02X\t%02X\t%02X\t%04X\n',
    frame, kind, w, address,
    value and string.format('%02X', value) or '--',
    rb(STATE_AT), rb(CD_RAW), rb(CD_BCD), pc))
  out:flush()
  rows = rows + 1

  if w == 'GAME' and seen[key] == 1 then
    emu.log(string.format('★ 게임이 슬롯 %s: $%04X  pc=%04X  state=%02X  frame=%d',
      kind, address, pc, rb(STATE_AT), frame))
  end
end

emu.addMemoryCallback(function(address, value) record('read', address, value) end,
  emu.callbackType.read, SLOT_LO, SLOT_HI, emu.cpuType.pce, MEM)
emu.addMemoryCallback(function(address, value) record('write', address, value) end,
  emu.callbackType.write, SLOT_LO, SLOT_HI, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function(address, value)
  out:write(string.format('%d\tSTATE\t-\t%04X\t%02X\t%02X\t%02X\t%02X\t%04X\n',
    frame, address, value or 0, value or 0, rb(CD_RAW), rb(CD_BCD),
    (emu.getState() or {})['cpu.pc'] or 0))
  out:flush(); rows = rows + 1
end, emu.callbackType.write, STATE_AT, STATE_AT, emu.cpuType.pce, MEM)

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write('# pc 별 접근 횟수 (많은 순)\n')
  local list = {}
  for key, n in pairs(seen) do list[#list + 1] = { key, n } end
  table.sort(list, function(a, b) return a[2] > b[2] end)
  for i = 1, math.min(#list, 30) do
    local key, n = list[i][1], list[i][2]
    local pc = tonumber(key:match('|(%d+)') or '0')
    out:write(string.format('#   %-14s %6d  (처음 frame %s)\n',
      key, n, tostring(firstByPc[pc] or '?')))
  end
  out:write(string.format('# rows=%d frames=%d\n', rows, frame))
  out:close()
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' -- 슬롯 $5B80-$5E1E 침입자 추적 · 읽기 전용')
emu.log('  슬롯 안에서 도는 우리 코드는 안 남긴다.  게임/상주부만 남긴다')
emu.log('  ★ 로 뜨는 줄이 곧 증거다')
emu.log('  -> ' .. OUT)
