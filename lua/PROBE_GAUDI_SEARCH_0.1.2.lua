-- PROBE_GAUDI_SEARCH 0.1.2
--
-- v0.1.1에서 성공 검색 후보가 RAM $C985의 「ギブスン」임을 확인했다.
-- 이 판은 그 검색 문자열 표($C900-$CAFF)가 언제 어떤 코드에서 적재되는지와,
-- 후보 포인터 $2090-$2092를 누가 쓰는지를 기록한다.
--
-- 사용:
--   1. 원본 0.7.11에서 가우디 인물 파일의 '인명 검색'을 열기 전 화면으로 간다.
--   2. 이 스크립트를 실행한다.
--   3. 인명 검색 화면 진입 -> ギブスン 전체 입력 -> 決定 -> 검색 성공까지 진행한다.
--   4. 스크립트를 Stop한다.
--
-- 출력: C:\snatcher\dump\probe_gaudi_search_v012.tsv

local OUT = "C:\\snatcher\\dump\\probe_gaudi_search_v012.tsv"
local mem = emu.memType.pceMemory
local TABLE_LO, TABLE_HI = 0xC900, 0xCAFF
local PTR_LO, PTR_HI = 0x2090, 0x2092
local INPUT_LO, INPUT_HI = 0x363E, 0x365D
local LIMIT = 4096

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tpc\taddr\tvalue\ta\tx\ty\tmpr\tdetail\n")
file:flush()

local frame, rows = 0, 0
local tableWrites, pointerWrites = 0, 0
local firstTablePc = {}

local function byte(a)
  return emu.read(a % 0x10000, mem) or 0
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
  local out = {}
  for i = 0, n - 1 do
    out[#out + 1] = string.format("%02X", byte(from + i))
  end
  return table.concat(out, " ")
end

local function row(kind, address, value, s, detail)
  if rows >= LIMIT then return end
  rows = rows + 1
  file:write(string.format(
    "%s\t%d\t%04X\t%04X\t%02X\t%02X\t%02X\t%02X\t%s\t%s\n",
    kind, frame, reg(s, "pc"), address or 0, value or 0,
    reg(s, "a"), reg(s, "x"), reg(s, "y"), mprText(s), detail or ""))
  file:flush()
end

-- 실제 후보 표를 채우는 코드. 같은 복사 루프는 첫 쓰기에서 코드 주변도 남긴다.
emu.addMemoryCallback(function(address, value)
  local s = state()
  local pc = reg(s, "pc")
  tableWrites = tableWrites + 1
  local first = not firstTablePc[pc]
  firstTablePc[pc] = true
  local detail = string.format("C985=%s", hexRange(0xC985, 9))
  if first then
    detail = detail .. " | PC-16=" .. hexRange((pc - 16) % 0x10000, 48)
  end
  row("table_write", address, value, s, detail)
end, emu.callbackType.write, TABLE_LO, TABLE_HI, emu.cpuType.pce, mem)

-- 비교 루틴이 쓰는 현재 후보 포인터.
emu.addMemoryCallback(function(address, value)
  local s = state()
  pointerWrites = pointerWrites + 1
  row("pointer_write", address, value, s,
    string.format("PTR=%02X%02X:%02X | CAND=%s",
      byte(0x2091), byte(0x2090), byte(0x2092),
      hexRange((byte(0x2090) | (byte(0x2091) << 8)), 16)))
end, emu.callbackType.write, PTR_LO, PTR_HI, emu.cpuType.pce, mem)

-- 성공 비교 순간의 최종 스냅샷도 함께 남긴다.
for _, pc in ipairs({0xBA00, 0xBA19, 0xBA59, 0xBA6D}) do
  emu.addMemoryCallback(function(address, value)
    local s = state()
    row("compare", address, value, s,
      "INPUT=" .. hexRange(INPUT_LO, INPUT_HI - INPUT_LO + 1) ..
      " | C985=" .. hexRange(0xC985, 24))
  end, emu.callbackType.exec, pc, pc, emu.cpuType.pce, mem)
end

emu.addEventCallback(function()
  frame = frame + 1
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  file:write(string.format(
    "-- rows %d table_writes %d pointer_writes %d final_C985 %s\n",
    rows, tableWrites, pointerWrites, hexRange(0xC985, 24)))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE_GAUDI_SEARCH 0.1.2 -- 검색표 적재/포인터 writer 측정")
emu.log("인명 검색을 열기 전 실행 -> ギブスン 전체 검색 성공 -> Stop")
emu.log("output: " .. OUT)

