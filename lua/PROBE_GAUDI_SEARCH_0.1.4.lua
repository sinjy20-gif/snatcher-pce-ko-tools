-- PROBE_GAUDI_SEARCH 0.1.4
--
-- $C985에서 실제 비교되는 검색 인덱스 「ギブスン」을 런타임에
-- 한글 키패드 토큰 「깁슨」(83 45 83 6A FF)으로 바꿔 검색 성공 여부를 확인한다.
-- 디스크 이미지는 수정하지 않는다.
--
-- 사용:
--   1. 한글 키패드 시험판의 가우디 인명 검색 화면에서 이 스크립트를 실행한다.
--   2. 아래 자판으로 「깁슨」 두 글자를 입력하고 결정한다.
--   3. 검색 결과가 나온 뒤 스크립트를 Stop한다.
-- 출력: C:\snatcher\dump\probe_gaudi_search_v014.tsv

local OUT = "C:\\snatcher\\dump\\probe_gaudi_search_v014.tsv"
local MEM = emu.memType.pceMemory
local INPUT_LO, INPUT_HI = 0x363E, 0x365D
local LIMIT = 512

local ORIGINAL = {0x83, 0x4D, 0x83, 0x75, 0x83, 0x58, 0x83, 0x93, 0xFF}
local PATCHED  = {0x83, 0x45, 0x83, 0x6A, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tpc\ta\tx\ty\td4d5\tptr\tmpr\tinput\tc985\n")
file:flush()

local frame, rows = 0, 0
local patchAttempts, patchVerified = 0, 0
local lastMpr6 = -1

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

local function applyPatch(s)
  if mpr(s, 6) ~= 0x7E then return end
  if not beginsWith(0xC985, ORIGINAL) and not beginsWith(0xC985, PATCHED) then return end
  if beginsWith(0xC985, PATCHED) then return end

  patchAttempts = patchAttempts + 1
  row("patch_before", s)
  for i = 1, #PATCHED do emu.write(0xC985 + i - 1, PATCHED[i], MEM) end
  if beginsWith(0xC985, PATCHED) then
    patchVerified = patchVerified + 1
    row("patch_verified", state())
  else
    row("patch_failed", state())
  end
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
  applyPatch(s)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  file:write(string.format("-- rows %d attempts %d verified %d final_C985 %s\n",
    rows, patchAttempts, patchVerified, hexRange(0xC985, 24)))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE_GAUDI_SEARCH 0.1.4 -- 실제 검색 인덱스 런타임 깁슨 치환")
emu.log("한글 키패드에서 깁슨 입력 -> 결정 -> 결과 뒤 Stop")
emu.log("디스크 이미지는 수정하지 않음")
emu.log("output: " .. OUT)
