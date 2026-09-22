-- PROBE_GAUDI_SEARCH 0.1.1
-- 성공 비교 PC $BA00/$BA19/$BA59/$BA6D 에서 후보 포인터와 레지스터를 기록한다.
--
-- 원본 0.7.11에서 ギブスン을 전부 입력한 뒤 실행 -> 決定 -> 자료 표시 -> Stop.
-- 출력: C:\snatcher\dump\probe_gaudi_search_v011.tsv

local OUT = "C:\\snatcher\\dump\\probe_gaudi_search_v011.tsv"
local mem = emu.memType.pceMemory
local BUF_LO, BUF_HI = 0x363E, 0x365D
local LIMIT = 256

local file = assert(io.open(OUT, "w"))
file:write("frame\tpc\taddr\tvalue\ta\tx\ty\td4d5\tp9092\tmpr\tcandidate\n")
file:flush()

local frame, rows = 0, 0

local function byte(a) return emu.read(a % 0x10000, mem) or 0 end

local function state()
  local ok, s = pcall(emu.getState)
  if ok and s then return s end
  return nil
end

local function reg(s, name)
  if not s then return 0 end
  return s["cpu." .. name] or s[name] or 0
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
  for i = 0, n - 1 do t[#t + 1] = string.format("%02X", byte(from + i)) end
  return table.concat(t, " ")
end

emu.addMemoryCallback(function(address, value)
  if rows >= LIMIT then return end
  local s = state()
  local pc = reg(s, "pc")
  if pc < 0xB9E0 or pc > 0xBA90 then return end

  local d4 = byte(0x20D4)
  local d5 = byte(0x20D5)
  local p90 = byte(0x2090)
  local p91 = byte(0x2091)
  local p92 = byte(0x2092)
  local ptr = p90 | (p91 << 8)
  local candidate = "-"
  if ptr >= 0x2000 and ptr <= 0xFFE0 then
    candidate = hexRange(ptr, 24)
  end

  rows = rows + 1
  file:write(string.format(
    "%d\t%04X\t%04X\t%02X\t%02X\t%02X\t%02X\t%04X\t%02X%02X:%02X\t%s\t%s\n",
    frame, pc, address, value or 0, reg(s, "a"), reg(s, "x"), reg(s, "y"),
    d4 | (d5 << 8), p91, p90, p92, mprText(s), candidate))
  file:flush()
end, emu.callbackType.read, BUF_LO, BUF_HI, emu.cpuType.pce, mem)

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

emu.addEventCallback(function()
  file:write(string.format("-- rows %d\n", rows))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE_GAUDI_SEARCH 0.1.1 -- 성공 후보 포인터 측정")
emu.log("원본 0.7.11에서 ギブスン -> 決定 -> 자료 표시 뒤 Stop")
emu.log("output: " .. OUT)
