-- PROBE_GAUDI_SEARCH 0.1.5
--
-- 한글 자판에는 「깁슨」을 그대로 표시하되, 검색 비교가 시작되는 순간에만
-- 입력 버퍼를 원본 검색 키 「ギブスン」으로 확장한다.
-- 기존 검색 색인과 결과 포인터를 그대로 재사용할 수 있는지 검증하는 시험이다.
-- 디스크 이미지는 수정하지 않는다.
--
-- 사용:
--   1. 한글 키패드 시험판의 인명 검색 화면에서 이 스크립트를 실행한다.
--   2. 「깁슨」을 입력하고 결정한다.
--   3. 결과가 나온 뒤 Stop한다.
-- 출력: C:\snatcher\dump\probe_gaudi_search_v015.tsv

local OUT = "C:\\snatcher\\dump\\probe_gaudi_search_v015.tsv"
local MEM = emu.memType.pceMemory
local INPUT = 0x363E

local KO_GIBSON = {0x83, 0x45, 0x83, 0x6A, 0xFF}
local JP_GIBSON = {0x83, 0x4D, 0x83, 0x75, 0x83, 0x58, 0x83, 0x93, 0xFF, 0x40}
local ORIGINAL_C985 = {0x83, 0x4D, 0x83, 0x75, 0x83, 0x58, 0x83, 0x93, 0xFF}

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tpc\td4d5\tptr\tmpr\tinput\tc985\n")
file:flush()

local frame, rewrites, restores = 0, 0, 0

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

local function beginsWith(address, values)
  for i = 1, #values do
    if byte(address + i - 1) ~= values[i] then return false end
  end
  return true
end

local function row(kind, s)
  local d4d5 = byte(0x20D4) | (byte(0x20D5) << 8)
  local ptr = byte(0x2090) | (byte(0x2091) << 8)
  file:write(string.format("%s\t%d\t%04X\t%04X\t%04X:%02X\t%s\t%s\t%s\n",
    kind, frame, reg(s, "pc"), d4d5, ptr, byte(0x2092), mprText(s),
    hexRange(INPUT, 32), hexRange(0xC985, 16)))
  file:flush()
end

-- v0.1.4가 같은 에뮬레이터 세션의 bank $7E를 바꿔 놓았을 수 있으므로
-- 원본 후보를 되돌린다. 이 쓰기는 디스크에는 반영되지 않는다.
local function restoreCandidate(s)
  if mpr(s, 6) ~= 0x7E then return end
  if beginsWith(0xC985, ORIGINAL_C985) then return end
  if byte(0xC985) == 0x83 and byte(0xC986) == 0x45
      and byte(0xC987) == 0x83 and byte(0xC988) == 0x6A then
    for i = 1, #ORIGINAL_C985 do
      emu.write(0xC985 + i - 1, ORIGINAL_C985[i], MEM)
    end
    restores = restores + 1
    row("candidate_restored", state())
  end
end

emu.addMemoryCallback(function()
  local s = state()
  if beginsWith(INPUT, KO_GIBSON) then
    row("input_before", s)
    for i = 1, #JP_GIBSON do emu.write(INPUT + i - 1, JP_GIBSON[i], MEM) end
    for a = INPUT + 10, INPUT + 31, 2 do
      emu.write(a, 0x81, MEM)
      emu.write(a + 1, 0x40, MEM)
    end
    rewrites = rewrites + 1
    row("input_rewritten", state())
  end
end, emu.callbackType.exec, 0xBA59, 0xBA59, emu.cpuType.pce, MEM)

for _, pc in ipairs({0xBA00, 0xBA19, 0xBA59, 0xBA6D}) do
  emu.addMemoryCallback(function()
    row(string.format("compare_%04X", pc), state())
  end, emu.callbackType.exec, pc, pc, emu.cpuType.pce, MEM)
end

emu.addEventCallback(function()
  frame = frame + 1
  restoreCandidate(state())
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  file:write(string.format("-- rewrites %d restores %d final_input %s\n",
    rewrites, restores, hexRange(INPUT, 32)))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE_GAUDI_SEARCH 0.1.5 -- 깁슨 표시/원본 검색키 변환 시험")
emu.log("깁슨 입력 -> 결정 -> 결과 뒤 Stop")
emu.log("output: " .. OUT)
