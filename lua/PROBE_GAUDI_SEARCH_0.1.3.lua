-- PROBE_GAUDI_SEARCH 0.1.3
--
-- v0.1.2의 공용 zero-page 포인터 writer 폭주를 제거한 정밀판.
-- MPR6가 $7E로 바뀌어 검색표가 $C000 창에 보이는 순간과,
-- 실제 비교 PC $BA00/$BA19/$BA59/$BA6D만 기록한다.
--
-- 사용: 원본 0.7.11 인명 검색 화면에서 ギブスン 전체 입력 상태로 실행
--       -> 決定 -> 검색 성공 -> Stop.
-- 출력: C:\snatcher\dump\probe_gaudi_search_v013.tsv

local OUT = "C:\\snatcher\\dump\\probe_gaudi_search_v013.tsv"
local MEM = emu.memType.pceMemory
local INPUT_LO, INPUT_HI = 0x363E, 0x365D
local LIMIT = 512

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tpc\ta\tx\ty\td4d5\tptr\tmpr\tinput\tc985\n")
file:flush()

local frame, rows = 0, 0
local lastMpr6 = -1
local visibleLogged = false

local function byte(a)
  return emu.read(a % 0x10000, MEM) or 0
end

local function state()
  local ok, s = pcall(emu.getState)
  if ok and s then return s end
  return nil
end

local function reg(s, name)
  if not s then return 0 end
  return s["cpu." .. name] or s[name] or 0
end

local function mpr(s, slot)
  if not s then return 0 end
  local v = s[string.format("memoryManager.mpr[%d]", slot)]
  if v == nil then v = s[string.format("mpr[%d]", slot)] end
  return v or 0
end

local function mprText(s)
  local out = {}
  for slot = 0, 7 do out[#out + 1] = string.format("%02X", mpr(s, slot)) end
  return table.concat(out, " ")
end

local function hexRange(from, n)
  local out = {}
  for i = 0, n - 1 do out[#out + 1] = string.format("%02X", byte(from + i)) end
  return table.concat(out, " ")
end

local function row(kind, s)
  if rows >= LIMIT then return end
  rows = rows + 1
  local d4d5 = byte(0x20D4) | (byte(0x20D5) << 8)
  local ptr = byte(0x2090) | (byte(0x2091) << 8)
  file:write(string.format(
    "%s\t%d\t%04X\t%02X\t%02X\t%02X\t%04X\t%04X:%02X\t%s\t%s\t%s\n",
    kind, frame, reg(s, "pc"), reg(s, "a"), reg(s, "x"), reg(s, "y"),
    d4d5, ptr, byte(0x2092), mprText(s),
    hexRange(INPUT_LO, INPUT_HI - INPUT_LO + 1), hexRange(0xC985, 24)))
  file:flush()
end

for _, pc in ipairs({0xBA00, 0xBA19, 0xBA59, 0xBA6D}) do
  emu.addMemoryCallback(function()
    row(string.format("compare_%04X", pc), state())
  end, emu.callbackType.exec, pc, pc, emu.cpuType.pce, MEM)
end

emu.addEventCallback(function()
  frame = frame + 1
  local s = state()
  local now = mpr(s, 6)
  if now ~= lastMpr6 then
    lastMpr6 = now
    row(string.format("mpr6_%02X", now), s)
  end
  if now == 0x7E and not visibleLogged
      and byte(0xC985) == 0x83 and byte(0xC986) == 0x4D
      and byte(0xC987) == 0x83 and byte(0xC988) == 0x75 then
    visibleLogged = true
    row("gibson_table_visible", s)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  file:write(string.format("-- rows %d visible %s\n", rows, tostring(visibleLogged)))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE_GAUDI_SEARCH 0.1.3 -- MPR6/검색 비교 정밀판")
emu.log("ギブスン 전체 입력 상태 -> 실행 -> 決定 -> 성공 뒤 Stop")
emu.log("output: " .. OUT)

