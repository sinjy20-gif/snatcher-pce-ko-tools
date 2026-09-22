-- PROBE_GAUDI_SEARCH 0.1.0
--
-- 가우디 인명 검색에서 입력 버퍼 $363E-$365D 를 누가 읽는지 잡는다.
-- 자판 렌더러와 최종 검색 비교기는 서로 다른 PC에서 읽으므로, PC별 최초 코드와
-- MPR을 기록하면 실제 비교 루틴/오버레이를 정적으로 되찾을 수 있다.
--
-- 사용:
--   1. 자판에서 깁슨(현재 시험판은 ウ, ニ)을 입력한 상태에서 이 스크립트를 연다.
--   2. 決定을 한 번 누르고 "해당 인물이 없습니다"가 나올 때까지 기다린다.
--   3. 스크립트를 Stop한다.
-- 출력: C:\snatcher\dump\probe_gaudi_search_v010.tsv

local OUT = "C:\\snatcher\\dump\\probe_gaudi_search_v010.tsv"
local mem = emu.memType.pceMemory
local BUF_LO, BUF_HI = 0x363E, 0x365D

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tpc\taddr\tvalue\tcount\tdetail\n")
file:flush()

local frame = 0
local rows = 0
local seen = {}
local counts = {}
local samples = {}

local function byte(a)
  return emu.read(a % 0x10000, mem) or 0
end

local function state()
  local ok, s = pcall(emu.getState)
  if ok and s then return s end
  return nil
end

local function pcOf(s)
  if not s then return 0 end
  return s["cpu.pc"] or s["pc"] or 0
end

local function mprText(s)
  if not s then return "-" end
  local out = {}
  for slot = 0, 7 do
    local v = s[string.format("memoryManager.mpr[%d]", slot)]
    if v == nil then v = s[string.format("mpr[%d]", slot)] end
    out[#out + 1] = string.format("%02X", v or 0)
  end
  return table.concat(out, " ")
end

local function hexRange(from, n)
  local t = {}
  for i = 0, n - 1 do
    t[#t + 1] = string.format("%02X", byte(from + i))
  end
  return table.concat(t, " ")
end

local function row(kind, pc, addr, value, count, detail)
  rows = rows + 1
  file:write(string.format("%s\t%d\t%04X\t%04X\t%02X\t%d\t%s\n",
    kind, frame, pc or 0, addr or 0, value or 0, count or 0, detail or ""))
  file:flush()
end

emu.addMemoryCallback(function(address, value)
  local s = state()
  local pc = pcOf(s)
  counts[pc] = (counts[pc] or 0) + 1
  if not seen[pc] then
    seen[pc] = true
    samples[pc] = {
      frame = frame,
      addr = address,
      value = value,
      mpr = mprText(s),
      code = hexRange((pc - 16) % 0x10000, 48),
      buf = hexRange(BUF_LO, BUF_HI - BUF_LO + 1),
    }
    row("first_read", pc, address, value, 1,
      "MPR " .. samples[pc].mpr .. " | PC-16 48B " .. samples[pc].code ..
      " | BUF " .. samples[pc].buf)
  end
end, emu.callbackType.read, BUF_LO, BUF_HI, emu.cpuType.pce, mem)

emu.addEventCallback(function()
  frame = frame + 1
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  for pc, count in pairs(counts) do
    local sample = samples[pc]
    row("census", pc, sample.addr, sample.value, count,
      "first_frame=" .. sample.frame .. " | MPR " .. sample.mpr)
  end
  file:write(string.format("-- total rows %d\n", rows))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE_GAUDI_SEARCH 0.1.0")
emu.log("깁슨을 입력한 뒤 決定을 한 번 누르고 결과가 나오면 Stop")
emu.log("output: " .. OUT)
